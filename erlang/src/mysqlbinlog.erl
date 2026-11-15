%%%-------------------------------------------------------------------
%%% Phase 1 offline MySQL binlog parser (Erlang/OTP, no third-party deps).
%%%
%%% CONTRACT: the public API (parse_buffer/1, parse_header/1, crc32/1) and
%%% the canonical JSONL emitted here are a cross-language contract: the other
%%% nine implementations, fixtures/expected.jsonl and the CLI all rely on
%%% them. Do not change either without a cross-language update. Internals are
%%% layered, in order, as ByteReader / CRC32 / Serializer / SchemaRegistry /
%%% RowDecoder / EventParser (see docs/design.md section 4 and c/src/
%%% mysqlbinlog.c, the reference implementation).
%%%-------------------------------------------------------------------
-module(mysqlbinlog).

-export([parse_buffer/1, parse_header/1, crc32/1]).

%% -------------------------------------------------------------------
%% Named protocol constants (docs/design.md sections 2-3).
%% -------------------------------------------------------------------
-define(HEADER_SIZE, 19).
-define(CRC_SIZE, 4).
-define(MAGIC_SIZE, 4).
-define(MAGIC, <<16#FE, $b, $i, $n>>).

-define(MAX_COLS, 64).
-define(MAX_TABLES, 64).
-define(MAX_EVENT_SIZE, (256 * 1024 * 1024)).  % corrupt-size defence
-define(LINE_CAP, 16384).                     % max single JSONL line
-define(MAX_BITMAP_BYTES, 8).                 % ceil(MAX_COLS / 8)

%% Column type ids used by the controlled subset.
-define(TYPE_LONG, 3).
-define(TYPE_LONGLONG, 8).
-define(TYPE_VARCHAR, 15).

%% Event type ids.
-define(EV_QUERY, 2).
-define(EV_ROTATE, 4).
-define(EV_FORMAT_DESC, 15).
-define(EV_XID, 16).
-define(EV_TABLE_MAP, 19).
-define(EV_ROWS_QUERY, 29).
-define(EV_WRITE_ROWS_V2, 30).
-define(EV_UPDATE_ROWS_V2, 31).
-define(EV_DELETE_ROWS_V2, 32).
-define(EV_GTID, 33).

%% Bounded scratch-buffer caps, mirroring the fixed char[] buffers in C.
-define(DB_CAP, 128).
-define(TABLE_CAP, 128).
-define(VERSION_CAP, 64).
-define(FDE_VERSION_LEN, 50).
-define(QUERY_CAP, 2048).
-define(ROWS_QUERY_CAP, 2048).
-define(ROTATE_FILE_CAP, 512).
-define(VARCHAR_CAP, 512).

%% -------------------------------------------------------------------
%% Internal state records.
%% -------------------------------------------------------------------
-record(reader, {data, len, pos = 0, error = false}).
-record(jsonb, {chunks = [], len = 0, overflow = false}).
-record(table_schema, {
    table_id = 0,
    db = <<>>,
    table = <<>>,
    column_count = 0,
    column_types = [],
    varchar_len_bytes = [],   % per column: 1 | 2, or 0 for non-VARCHAR
    nullable_count = 0
}).
-record(event_header, {
    timestamp = 0,
    event_type = 0,
    server_id = 0,
    event_size = 0,
    next_position = 0,
    flags = 0
}).

%% ===================================================================
%% === [1] ByteReader ===
%% ===================================================================
%% Bounds-checked little-endian primitives. Every read threads the reader
%% state and returns {Value, Reader1}; an out-of-bounds read latches
%% error = true and yields a zero / empty value (as in the C model), so
%% malformed bytes never produce a badmatch or a function_clause.
%% `rem` is a reserved word in Erlang, so that primitive is named r_rem/1.

new_reader(Data) when is_binary(Data) ->
    #reader{data = Data, len = byte_size(Data), pos = 0, error = false}.

latch(R) -> R#reader{error = true}.

r_pos(#reader{pos = Pos}) -> Pos.
r_len(#reader{len = Len}) -> Len.
r_error(#reader{error = Err}) -> Err.

%% r_rem/1 == C's rem(): bytes still unread.
r_rem(#reader{len = Len, pos = Pos}) when Pos =< Len -> Len - Pos;
r_rem(_) -> 0.

%% Overflow-safe "pos + N =< len" test; once error is latched every read
%% fails immediately, which gives the C reader's latch semantics.
can(#reader{len = Len, pos = Pos, error = false}, N)
  when is_integer(N), N >= 0 ->
    N =< Len andalso Pos =< Len - N;
can(_, _) -> false.

le(R, N) ->
    case can(R, N) of
        false ->
            {0, latch(R)};
        true ->
            #reader{data = Data, pos = Pos} = R,
            V = case N of
                    0 -> 0;
                    _ -> binary:decode_unsigned(binary:part(Data, Pos, N), little)
                end,
            {V, R#reader{pos = Pos + N}}
    end.

raw(R, N) ->
    case can(R, N) of
        false ->
            {<<>>, latch(R)};
        true ->
            #reader{data = Data, pos = Pos} = R,
            {binary:part(Data, Pos, N), R#reader{pos = Pos + N}}
    end.

%% Read exactly N bytes, keep at most Cap-1 of them and stop at the first
%% NUL (C-string semantics). The reader still advances by N, preserving
%% alignment even when the value is truncated to fit the cap.
strn(R, N, Cap) ->
    {Bytes, R1} = raw(R, N),
    Keep = min(byte_size(Bytes), max(0, Cap - 1)),
    {cstr(binary:part(Bytes, 0, Keep)), R1}.

cstr(Bin) ->
    case binary:split(Bin, <<0>>) of
        [Head | _] -> Head
    end.

skip(R, N) ->
    case can(R, N) of
        false ->
            R1 = latch(R),
            R1#reader{pos = r_len(R)};
        true ->
            R#reader{pos = r_pos(R) + N}
    end.

%% MySQL length-encoded integer. 0xFB (NULL) and 0xFF (reserved) are not
%% valid lengths and latch the reader error.
lenenc(R0) ->
    {B, R1} = le(R0, 1),
    case r_error(R1) of
        true -> {0, R1};
        false ->
            case B of
                X when X < 16#FB -> {X, R1};
                16#FC -> le(R1, 2);
                16#FD -> le(R1, 3);
                16#FE -> le(R1, 8);
                _     -> {0, latch(R1)}
            end
    end.

%% hex(n): n bytes -> lowercase hex binary (design.md section 2.4).
hex_bytes(Bin) ->
    list_to_binary([<<(hx(B bsr 4)), (hx(B band 15))>>
                    || B <- binary:bin_to_list(Bin)]).

hx(N) when N < 10 -> $0 + N;
hx(N) -> $a + N - 10.

%% ===================================================================
%% === [2] CRC-32 ===
%% ===================================================================
%% Standard CRC-32 (IEEE 802.3 / zlib): polynomial 0xEDB88320, initial and
%% final xor 0xFFFFFFFF. Standard vector: crc32("123456789") = 0xCBF43926.

-spec crc32(binary()) -> non_neg_integer().
crc32(Bin) ->
    (crc32_run(Bin, 16#FFFFFFFF)) bxor 16#FFFFFFFF.

crc32_run(<<>>, C) -> C;
crc32_run(<<B, Rest/binary>>, C0) ->
    crc32_run(Rest, crc32_byte(C0 bxor B, 8)).

crc32_byte(C, 0) -> C;
crc32_byte(C, K) ->
    Mask = case C band 1 of 1 -> 16#EDB88320; _ -> 0 end,
    crc32_byte((C bsr 1) bxor Mask, K - 1).

%% ===================================================================
%% === [3] Serializer ===
%% ===================================================================
%% Bounded canonical JSONL builder: fixed key order, no spaces, minimal
%% string escaping. #jsonb{} accumulates reversed iodata chunks, tracks the
%% byte length and latches overflow when a single line exceeds LINE_CAP.

jb_new() -> #jsonb{}.

jb_append(B = #jsonb{overflow = true}, _Io) -> B;
jb_append(B = #jsonb{chunks = Chunks, len = Len}, Io) ->
    Sz = iolist_size(Io),
    case Len + Sz > ?LINE_CAP of
        true  -> B#jsonb{overflow = true};
        false -> B#jsonb{chunks = [Io | Chunks], len = Len + Sz}
    end.

jb_putc(B, C) -> jb_append(B, <<C>>).
jb_puts(B, S) -> jb_append(B, S).
jb_num(B, V)  -> jb_append(B, integer_to_binary(V)).

%% Minimal JSON string escaping: " \ \n \r \t and \u00xx for < 0x20.
jb_json_str(B0, Bin) ->
    B1 = jb_putc(B0, $"),
    B2 = jb_escape(B1, Bin),
    jb_putc(B2, $").

jb_escape(B, <<>>) -> B;
jb_escape(B, <<C, Rest/binary>>) ->
    jb_escape(jb_puts(B, esc_chunk(C)), Rest).

esc_chunk(16#22) -> <<"\\\"">>;
esc_chunk(16#5C) -> <<"\\\\">>;
esc_chunk(16#0A) -> <<"\\n">>;
esc_chunk(16#0D) -> <<"\\r">>;
esc_chunk(16#09) -> <<"\\t">>;
esc_chunk(C) when C < 16#20 ->
    list_to_binary(io_lib:format("\\u~4.16.0b", [C]));
esc_chunk(C) -> <<C>>.

%% Ordered output ops keep the event handlers readable: {s, iodata},
%% {n, integer} and {j, binary-to-be-JSON-escaped}.
jb_emit(B, Ops) -> lists:foldl(fun jb_op/2, B, Ops).

jb_op({s, S}, B) -> jb_puts(B, S);
jb_op({n, V}, B) -> jb_num(B, V);
jb_op({j, S}, B) -> jb_json_str(B, S).

jb_finish(#jsonb{overflow = true}) -> {error, invalid};
jb_finish(#jsonb{chunks = Chunks}) -> {ok, lists:reverse(Chunks)}.

join([]) -> [];
join([X]) -> [X];
join([X | Xs]) -> [X, <<",">> | join(Xs)].

%% ===================================================================
%% === [4] SchemaRegistry ===
%% ===================================================================
%% table_id -> #table_schema{} for the lifetime of one buffer. put/2
%% replaces an existing id, get/2 returns the atom `none` when absent, and
%% the number of entries is bounded to MAX_TABLES.

reg_new() -> #{}.

reg_put(Reg, #table_schema{table_id = Tid} = S) ->
    case maps:is_key(Tid, Reg) of
        true  -> Reg#{Tid => S};
        false ->
            case map_size(Reg) < ?MAX_TABLES of
                true  -> Reg#{Tid => S};
                false -> Reg
            end
    end.

reg_get(Reg, Tid) ->
    case maps:find(Tid, Reg) of
        {ok, S} -> S;
        error   -> none
    end.

%% ===================================================================
%% === [5] RowDecoder ===
%% ===================================================================
%% decode_value/5 decodes one column, decode_rows/4 walks the row sequence,
%% both against a #table_schema{}. VARCHAR lengths and bitmap sizes are
%% bounded; all failures are explicit error tuples.

%% Safe nth (0-based) so a malformed schema yields an error, not a crash.
col_at(I, List) when is_integer(I), I >= 0, I < length(List) ->
    {ok, lists:nth(I + 1, List)};
col_at(_, _) -> {error, truncated}.

%% Interpret an unsigned little-endian value of Bits width as signed.
to_signed(V, Bits) ->
    case V band (1 bsl (Bits - 1)) of
        0 -> V;
        _ -> V - (1 bsl Bits)
    end.

decode_value(R, _S, _Col, true, B) ->
    {ok, jb_puts(B, <<"null">>), R};
decode_value(R0, S, Col, false, B0) ->
    case col_at(Col, S#table_schema.column_types) of
        {error, E} -> {error, E};
        {ok, ?TYPE_LONGLONG} ->
            {V, R1} = le(R0, 8),
            case r_error(R1) of
                true  -> {error, truncated};
                false -> {ok, jb_num(B0, to_signed(V, 64)), R1}
            end;
        {ok, ?TYPE_LONG} ->
            {V, R1} = le(R0, 4),
            case r_error(R1) of
                true  -> {error, truncated};
                false -> {ok, jb_num(B0, to_signed(V, 32)), R1}
            end;
        {ok, ?TYPE_VARCHAR} ->
            case col_at(Col, S#table_schema.varchar_len_bytes) of
                {ok, Lb} when Lb =:= 1; Lb =:= 2 ->
                    {Slen, R1} = le(R0, Lb),
                    case r_error(R1) of
                        true -> {error, truncated};
                        false ->
                            case Slen > ?VARCHAR_CAP - 1 of
                                true -> {error, unsupported};
                                false ->
                                    {Val, R2} = strn(R1, Slen, ?VARCHAR_CAP),
                                    case r_error(R2) of
                                        true  -> {error, truncated};
                                        false -> {ok, jb_json_str(B0, Val), R2}
                                    end
                            end
                    end;
                _ -> {error, unsupported}
            end;
        {ok, _Other} -> {error, unsupported};
        _ -> {error, unsupported}
    end.

decode_rows(R0, S, PresentBitmap, B0) ->
    NbSize = (S#table_schema.nullable_count + 7) div 8,
    case NbSize > ?MAX_BITMAP_BYTES of
        true  -> {error, unsupported};
        false ->
            B1 = jb_puts(B0, <<",\"rows\":[">>),
            decode_rows_loop(R0, S, PresentBitmap, NbSize, B1, 0)
    end.

decode_rows_loop(R, S, Pbm, NbSize, B, RowNo) ->
    case r_error(R) =:= false andalso r_rem(R) > 0 of
        false -> decode_rows_done(R, B);
        true ->
            Start = r_pos(R),
            {NullBm, R1} = le(R, NbSize),
            case r_error(R1) of
                true -> {error, truncated};
                false ->
                    B1 = case RowNo of 0 -> B; _ -> jb_putc(B, $,) end,
                    B2 = jb_putc(B1, $[),
                    case decode_row_values(R1, S, Pbm, NullBm, B2, 0, true) of
                        {error, E} -> {error, E};
                        {ok, B3, R2} ->
                            B4 = jb_putc(B3, $]),
                            case r_error(R2) of
                                true -> {error, truncated};
                                false ->
                                    %% Malformed bytes must not spin forever.
                                    case r_pos(R2) =< Start of
                                        true  -> {error, invalid};
                                        false -> decode_rows_loop(R2, S, Pbm,
                                                                  NbSize, B4,
                                                                  RowNo + 1)
                                    end
                            end
                    end
            end
    end.

decode_rows_done(R, B) ->
    case r_error(R) of
        true  -> {error, truncated};
        false -> {ok, jb_puts(B, <<"]}">>), R}
    end.

decode_row_values(R, S, _Pbm, _NullBm, B, I, _First)
  when I >= S#table_schema.column_count ->
    {ok, B, R};
decode_row_values(R0, S, Pbm, NullBm, B0, I, First) ->
    Bit = 1 bsl I,
    case Pbm band Bit of
        0 -> decode_row_values(R0, S, Pbm, NullBm, B0, I + 1, First);
        _ ->
            B1 = case First of
                     true  -> B0;
                     false -> jb_putc(B0, $,)
                 end,
            IsNull = (NullBm band Bit) =/= 0,
            case decode_value(R0, S, I, IsNull, B1) of
                {error, E} -> {error, E};
                {ok, B2, R1} ->
                    case r_error(R1) of
                        true  -> {error, truncated};
                        false -> decode_row_values(R1, S, Pbm, NullBm, B2,
                                                   I + 1, false)
                    end
            end
    end.

%% ===================================================================
%% === [6] EventParser ===
%% ===================================================================
%% Header decoding, one named handler per event kind, and dispatch_event/4.
%% Each handler returns {ok, JsonBuilder1, Registry1} | {error, Reason}.

-spec parse_header(binary()) -> {ok, map()} | {error, atom()}.
parse_header(Bin) when is_binary(Bin) ->
    case read_header(new_reader(Bin)) of
        {error, E} -> {error, E};
        {ok, H, _R} ->
            {ok, #{ts    => H#event_header.timestamp,
                   type  => H#event_header.event_type,
                   sid   => H#event_header.server_id,
                   size  => H#event_header.event_size,
                   next  => H#event_header.next_position,
                   flags => H#event_header.flags}}
    end;
parse_header(_) -> {error, truncated}.

read_header(R0) ->
    {Ts,    R1} = le(R0, 4),
    {Type,  R2} = le(R1, 1),
    {Sid,   R3} = le(R2, 4),
    {Size,  R4} = le(R3, 4),
    {Next,  R5} = le(R4, 4),
    {Flags, R6} = le(R5, 2),
    H = #event_header{timestamp = Ts, event_type = Type, server_id = Sid,
                      event_size = Size, next_position = Next, flags = Flags},
    case r_error(R6) of
        true  -> {error, truncated};
        false -> {ok, H, R6}
    end.

rows_name(?EV_WRITE_ROWS_V2)  -> <<"WRITE_ROWS_EVENT_V2">>;
rows_name(?EV_UPDATE_ROWS_V2) -> <<"UPDATE_ROWS_EVENT_V2">>;
rows_name(?EV_DELETE_ROWS_V2) -> <<"DELETE_ROWS_EVENT_V2">>;
rows_name(_)                  -> <<"ROWS_EVENT_V2">>.

%% FORMAT_DESCRIPTION_EVENT (15).
parse_fde(R0, H, Body, B0, Reg) ->
    case byte_size(Body) >= 2 + ?FDE_VERSION_LEN + 1 of
        false -> {error, truncated};
        true ->
            {BV, R1} = le(R0, 2),
            {VerRaw, R2} = raw(R1, ?FDE_VERSION_LEN),
            Keep = min(byte_size(VerRaw), ?VERSION_CAP - 1),
            ServerVersion = cstr(binary:part(VerRaw, 0, Keep)),
            <<Alg>> = binary:part(Body, byte_size(Body) - 1, 1),
            case r_error(R2) of
                true -> {error, truncated};
                false ->
                    {ok, jb_emit(B0, [
                        {s, <<"{\"type\":\"FORMAT_DESCRIPTION_EVENT\",\"timestamp\":">>},
                        {n, H#event_header.timestamp},
                        {s, <<",\"binlog_version\":">>}, {n, BV},
                        {s, <<",\"server_version\":">>}, {j, ServerVersion},
                        {s, <<",\"checksum_alg\":">>},   {n, Alg},
                        {s, <<"}">>}]), Reg}
            end
    end.

%% GTID_LOG_EVENT (33).
parse_gtid(R0, H, B0, Reg) ->
    {_, R1}   = le(R0, 1),                 % flags
    {Sid, R2} = raw(R1, 16),
    {Gno, R3} = le(R2, 8),
    case r_error(R3) of
        true -> {error, truncated};
        false ->
            {ok, jb_emit(B0, [
                {s, <<"{\"type\":\"GTID_LOG_EVENT\",\"timestamp\":">>},
                {n, H#event_header.timestamp},
                {s, <<",\"gno\":">>}, {n, Gno},
                {s, <<",\"sid\":">>}, {j, hex_bytes(Sid)},
                {s, <<"}">>}]), Reg}
    end.

%% QUERY_EVENT (2).
parse_query(R0, H, B0, Reg) ->
    {_, R1}     = le(R0, 4),              % thread_id
    {_, R2}     = le(R1, 4),              % exec_time
    {DbLen, R3} = le(R2, 1),
    {_, R4}     = le(R3, 2),              % error_code
    {SvLen, R5} = le(R4, 2),
    R6 = skip(R5, SvLen),                 % status_vars
    {Db, R7}    = strn(R6, DbLen, ?DB_CAP),
    {_, R8}     = le(R7, 1),              % trailing NUL after db
    {Query, R9} = strn(R8, r_rem(R8), ?QUERY_CAP),
    case r_error(R9) of
        true -> {error, truncated};
        false ->
            {ok, jb_emit(B0, [
                {s, <<"{\"type\":\"QUERY_EVENT\",\"timestamp\":">>},
                {n, H#event_header.timestamp},
                {s, <<",\"db\":">>},    {j, Db},
                {s, <<",\"query\":">>}, {j, Query},
                {s, <<"}">>}]), Reg}
    end.

%% ROWS_QUERY_LOG_EVENT (29).
parse_rows_query(R0, H, B0, Reg) ->
    {Len, R1} = lenenc(R0),
    {Q, R2}   = strn(R1, Len, ?ROWS_QUERY_CAP),
    case r_error(R2) of
        true -> {error, truncated};
        false ->
            {ok, jb_emit(B0, [
                {s, <<"{\"type\":\"ROWS_QUERY_LOG_EVENT\",\"timestamp\":">>},
                {n, H#event_header.timestamp},
                {s, <<",\"query\":">>}, {j, Q},
                {s, <<"}">>}]), Reg}
    end.

%% TABLE_MAP_EVENT (19): decode, validate and register the schema.
parse_table_map(R0, H, B0, Reg) ->
    {Tid, R1}   = le(R0, 6),
    {_, R2}     = le(R1, 2),              % flags
    {DbLen, R3} = le(R2, 1),
    {Db, R4}    = strn(R3, DbLen, ?DB_CAP),
    {_, R5}     = le(R4, 1),              % NUL
    {TbLen, R6} = le(R5, 1),
    {Tb, R7}    = strn(R6, TbLen, ?TABLE_CAP),
    {_, R8}     = le(R7, 1),              % NUL
    {Cc, R9}    = lenenc(R8),
    case r_error(R9) of
        true -> {error, truncated};
        false ->
            case Cc =:= 0 orelse Cc > ?MAX_COLS of
                true -> {error, unsupported};
                false ->
                    {TypesBin, R10} = raw(R9, Cc),
                    {MdLen, R11} = lenenc(R10),
                    MdStart = r_pos(R11),
                    MdEnd = MdStart + MdLen,
                    %% md_len / md_start must stay inside the body.
                    case r_error(R11) orelse MdLen > r_len(R11)
                         orelse MdStart > r_len(R11) - MdLen of
                        true -> {error, truncated};
                        false ->
                            Types = binary:bin_to_list(TypesBin),
                            case parse_metadata(Types, R11, [], MdEnd) of
                                {error, E} -> {error, E};
                                {ok, Vlen} ->
                                    parse_table_map_tail(R11, H, MdEnd, Cc,
                                                         Tid, Db, Tb, Types,
                                                         Vlen, B0, Reg)
                            end
                    end
            end
    end.

%% VARCHAR metadata: 2-byte maxlen decides the length-prefix width (1|2).
parse_metadata([], _R, Acc, _MdEnd) ->
    {ok, lists:reverse(Acc)};
parse_metadata([?TYPE_VARCHAR | Ts], R0, Acc, MdEnd) ->
    case r_error(R0) =:= false andalso r_pos(R0) + 2 =< MdEnd of
        false -> {error, truncated};
        true ->
            {MaxLen, R1} = le(R0, 2),
            Lb = case MaxLen > 255 of true -> 2; false -> 1 end,
            parse_metadata(Ts, R1, [Lb | Acc], MdEnd)
    end;
parse_metadata([_ | Ts], R, Acc, MdEnd) ->
    parse_metadata(Ts, R, [0 | Acc], MdEnd).

parse_table_map_tail(R11, H, MdEnd, Cc, Tid, Db, Tb, Types, Vlen, B0, Reg) ->
    Nb = (Cc + 7) div 8,
    case Nb > ?MAX_BITMAP_BYTES of
        true -> {error, unsupported};
        false ->
            R12 = R11#reader{pos = MdEnd},  % skip any extra metadata
            {NullBm, R13} = le(R12, Nb),
            case r_error(R13) of
                true -> {error, truncated};
                false ->
                    Nullable = count_bits(NullBm, Cc),
                    S = #table_schema{table_id = Tid, db = Db, table = Tb,
                                      column_count = Cc, column_types = Types,
                                      varchar_len_bytes = Vlen,
                                      nullable_count = Nullable},
                    Reg1 = reg_put(Reg, S),
                    TypesIo = [<<"[">>,
                               join([integer_to_binary(X) || X <- Types]),
                               <<"]">>],
                    {ok, jb_emit(B0, [
                        {s, <<"{\"type\":\"TABLE_MAP_EVENT\",\"timestamp\":">>},
                        {n, H#event_header.timestamp},
                        {s, <<",\"table_id\":">>}, {n, Tid},
                        {s, <<",\"db\":">>}, {j, Db},
                        {s, <<",\"table\":">>}, {j, Tb},
                        {s, <<",\"column_count\":">>}, {n, Cc},
                        {s, <<",\"column_types\":">>}, {s, TypesIo},
                        {s, <<"}">>}]), Reg1}
            end
    end.

count_bits(Bm, Cc) ->
    length([I || I <- lists:seq(0, Cc - 1), (Bm band (1 bsl I)) =/= 0]).

%% WRITE/UPDATE/DELETE_ROWS_EVENT_V2 (30/31/32).
parse_rows_v2(R0, H, B0, Reg) ->
    Type = H#event_header.event_type,
    {Tid, R1}      = le(R0, 6),
    {_, R2}        = le(R1, 2),            % flags
    {ExtraLen, R3} = le(R2, 2),           % includes its own 2 bytes
    case ExtraLen < 2 of
        true -> {error, unsupported};
        false ->
            R4 = skip(R3, ExtraLen - 2),
            {Cc, R5} = lenenc(R4),
            case r_error(R5) of
                true -> {error, truncated};
                false ->
                    case Cc =:= 0 orelse Cc > ?MAX_COLS of
                        true -> {error, unsupported};
                        false ->
                            BmSize = (Cc + 7) div 8,
                            case BmSize > ?MAX_BITMAP_BYTES of
                                true -> {error, unsupported};
                                false ->
                                    {Pbm, R6} = le(R5, BmSize),
                                    R7 = case Type of
                                             ?EV_UPDATE_ROWS_V2 ->
                                                 {_, Rx} = le(R6, BmSize),
                                                 Rx;
                                             _ -> R6
                                         end,
                                    case r_error(R7) of
                                        true -> {error, truncated};
                                        false ->
                                            case reg_get(Reg, Tid) of
                                                none -> {error, no_schema};
                                                S ->
                                                    B1 = jb_emit(B0, [
                                                        {s, <<"{\"type\":\"">>},
                                                        {s, rows_name(Type)},
                                                        {s, <<"\",\"timestamp\":">>},
                                                        {n, H#event_header.timestamp},
                                                        {s, <<",\"table_id\":">>}, {n, Tid},
                                                        {s, <<",\"db\":">>}, {j, S#table_schema.db},
                                                        {s, <<",\"table\":">>}, {j, S#table_schema.table}]),
                                                    case decode_rows(R7, S, Pbm, B1) of
                                                        {error, E} -> {error, E};
                                                        {ok, B2, _R8} -> {ok, B2, Reg}
                                                    end
                                            end
                                    end
                            end
                    end
            end
    end.

%% XID_EVENT (16).
parse_xid(R0, H, B0, Reg) ->
    {Xid, R1} = le(R0, 8),
    case r_error(R1) of
        true -> {error, truncated};
        false ->
            {ok, jb_emit(B0, [
                {s, <<"{\"type\":\"XID_EVENT\",\"timestamp\":">>},
                {n, H#event_header.timestamp},
                {s, <<",\"xid\":">>}, {n, Xid},
                {s, <<"}">>}]), Reg}
    end.

%% ROTATE_EVENT (4).
parse_rotate(R0, H, B0, Reg) ->
    {Position, R1} = le(R0, 8),
    {Nf, R2} = strn(R1, r_rem(R1), ?ROTATE_FILE_CAP),
    case r_error(R2) of
        true -> {error, truncated};
        false ->
            {ok, jb_emit(B0, [
                {s, <<"{\"type\":\"ROTATE_EVENT\",\"timestamp\":">>},
                {n, H#event_header.timestamp},
                {s, <<",\"position\":">>}, {n, Position},
                {s, <<",\"next_file\":">>}, {j, Nf},
                {s, <<"}">>}]), Reg}
    end.

%% UNKNOWN: safe skip, one stable one-line record.
parse_unknown(H, B0, Reg) ->
    {ok, jb_emit(B0, [
        {s, <<"{\"type\":\"UNKNOWN\",\"timestamp\":">>},
        {n, H#event_header.timestamp},
        {s, <<",\"type_id\":">>}, {n, H#event_header.event_type},
        {s, <<",\"event_size\":">>}, {n, H#event_header.event_size},
        {s, <<"}">>}]), Reg}.

dispatch_event(H, Body, Reg, B0) ->
    R0 = new_reader(Body),
    case H#event_header.event_type of
        ?EV_FORMAT_DESC    -> parse_fde(R0, H, Body, B0, Reg);
        ?EV_GTID           -> parse_gtid(R0, H, B0, Reg);
        ?EV_QUERY          -> parse_query(R0, H, B0, Reg);
        ?EV_ROWS_QUERY     -> parse_rows_query(R0, H, B0, Reg);
        ?EV_TABLE_MAP      -> parse_table_map(R0, H, B0, Reg);
        ?EV_WRITE_ROWS_V2  -> parse_rows_v2(R0, H, B0, Reg);
        ?EV_UPDATE_ROWS_V2 -> parse_rows_v2(R0, H, B0, Reg);
        ?EV_DELETE_ROWS_V2 -> parse_rows_v2(R0, H, B0, Reg);
        ?EV_XID            -> parse_xid(R0, H, B0, Reg);
        ?EV_ROTATE         -> parse_rotate(R0, H, B0, Reg);
        _                  -> parse_unknown(H, B0, Reg)
    end.

%% ===================================================================
%% === [7] Public API ===
%% ===================================================================
%% parse_buffer/1: verify magic, decode the 19-byte header, bound
%% event_size, verify CRC32 over header+body, dispatch, and emit exactly
%% one canonical JSONL line per event. All failures are error tuples.

-spec parse_buffer(binary()) -> {ok, iolist()} | {error, atom()}.
parse_buffer(Data) when is_binary(Data), byte_size(Data) >= ?MAGIC_SIZE ->
    case binary:part(Data, 0, ?MAGIC_SIZE) of
        ?MAGIC ->
            Rest = binary:part(Data, ?MAGIC_SIZE,
                               byte_size(Data) - ?MAGIC_SIZE),
            parse_events(Rest, reg_new(), []);
        _ -> {error, invalid}
    end;
parse_buffer(_) -> {error, invalid}.

parse_events(<<>>, _Reg, Acc) ->
    {ok, lists:reverse(Acc)};
parse_events(Bin, Reg, Acc) ->
    case read_header(new_reader(Bin)) of
        {error, E} -> {error, E};
        {ok, H, _R} ->
            Size = H#event_header.event_size,
            BinSize = byte_size(Bin),
            case Size < ?HEADER_SIZE + ?CRC_SIZE of
                true -> {error, truncated};
                false ->
                    case Size > ?MAX_EVENT_SIZE orelse Size > BinSize of
                        true -> {error, truncated};
                        false ->
                            BodySize = Size - ?HEADER_SIZE - ?CRC_SIZE,
                            Body = binary:part(Bin, ?HEADER_SIZE, BodySize),
                            <<Stored:32/little>> =
                                binary:part(Bin, Size - ?CRC_SIZE, ?CRC_SIZE),
                            Calc = crc32(binary:part(Bin, 0, Size - ?CRC_SIZE)),
                            case Stored =:= Calc of
                                false -> {error, checksum};
                                true ->
                                    case dispatch_event(H, Body, Reg, jb_new()) of
                                        {error, E} -> {error, E};
                                        {ok, B1, Reg1} ->
                                            case jb_finish(B1) of
                                                {error, E} -> {error, E};
                                                {ok, Line} ->
                                                    Rest = binary:part(Bin, Size,
                                                                       BinSize - Size),
                                                    parse_events(Rest, Reg1,
                                                                 [[Line, <<"\n">>] | Acc])
                                            end
                                    end
                            end
                    end
            end
    end.
