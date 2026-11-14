%%%-------------------------------------------------------------------
%%% Phase 1 offline MySQL binlog parser (Erlang/OTP, no third-party deps).
%%% Emits the canonical JSONL shared by every language implementation.
%%%-------------------------------------------------------------------
-module(mysqlbinlog).

-export([parse_buffer/1, parse_header/1, crc32/1]).

-define(MAGIC, <<16#FE, $b, $i, $n>>).

%% ------------------------------------------------------------------
%% CRC-32 (IEEE / zlib), implemented bitwise.
%% ------------------------------------------------------------------
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

%% ------------------------------------------------------------------
%% Public header parser.
%% ------------------------------------------------------------------
-spec parse_header(binary()) -> {ok, map()} | {error, atom()}.
parse_header(Bin) when byte_size(Bin) < 19 -> {error, truncated};
parse_header(<<T:32/little, Type:8, Sid:32/little, Size:32/little,
               Next:32/little, Flags:16/little, _/binary>>) ->
    {ok, #{ts => T, type => Type, sid => Sid, size => Size,
           next => Next, flags => Flags}};
parse_header(_) -> {error, truncated}.

%% ------------------------------------------------------------------
%% Whole-buffer parser.
%% ------------------------------------------------------------------
-spec parse_buffer(binary()) -> {ok, iolist()} | {error, atom()}.
parse_buffer(Data) ->
    try
        case Data of
            <<16#FE, $b, $i, $n, Rest/binary>> -> parse_events(Rest, #{}, []);
            _ -> {error, invalid}
        end
    catch
        throw:{binlog, Code} -> {error, Code}
    end.

parse_events(<<>>, _Reg, Acc) -> {ok, lists:reverse(Acc)};
parse_events(Bin, Reg, Acc) ->
    case parse_header(Bin) of
        {error, E} -> {error, E};
        {ok, H} ->
            Size = maps:get(size, H),
            if Size < 23 -> {error, truncated};
               byte_size(Bin) < Size -> {error, truncated};
               true ->
                   BodySize = Size - 23,
                   <<_:19/binary, Body:BodySize/binary, Stored:32/little, Rest/binary>> = Bin,
                    Calc = crc32(binary:part(Bin, 0, Size - 4)),
                    if Stored =/= Calc -> {error, checksum};
                       true ->
                           T = maps:get(ts, H),
                           Type = maps:get(type, H),
                           {Line, Reg1} = emit(Type, T, Size, Body, Reg),
                           parse_events(Rest, Reg1, [Line | Acc])
                    end
            end
    end.

%% ------------------------------------------------------------------
%% Body reader (map with bin + pos).
%% ------------------------------------------------------------------
new_r(Bin) -> #{bin => Bin, pos => 0}.

rd_le(#{bin := B, pos := P} = R, N) ->
    if P + N > byte_size(B) -> throw({binlog, truncated});
       true -> ok
    end,
    V = binary:decode_unsigned(binary:part(B, P, N), little),
    {V, R#{pos := P + N}}.

rd_raw(#{bin := B, pos := P} = R, N) ->
    if P + N > byte_size(B) -> throw({binlog, truncated});
       true -> ok
    end,
    {binary:part(B, P, N), R#{pos := P + N}}.

rd_skip(R, N) ->
    {_, R1} = rd_raw(R, N),
    R1.

rd_lenenc(R0) ->
    {B, R1} = rd_le(R0, 1),
    case B of
        X when X < 16#FB -> {X, R1};
        16#FB -> {0, R1};
        16#FC -> rd_le(R1, 2);
        16#FD -> rd_le(R1, 3);
        16#FE -> rd_le(R1, 8);
        _ -> {0, R1}
    end.

r_pos(R) -> maps:get(pos, R).
r_rem(R) ->
    #{bin := B, pos := P} = R,
    byte_size(B) - P.

%% ------------------------------------------------------------------
%% Canonical JSON helpers (iodata).
%% ------------------------------------------------------------------
json_str(Bin) -> [34, esc(Bin), 34].

esc(<<>>) -> [];
esc(<<C, Rest/binary>>) ->
    Chunk = case C of
        16#22 -> <<"\\\"">>;
        16#5C -> <<"\\\\">>;
        16#0A -> <<"\\n">>;
        16#0D -> <<"\\r">>;
        16#09 -> <<"\\t">>;
        _ when C < 16#20 -> list_to_binary(io_lib:format("\\u~4.16.0b", [C]));
        _ -> <<C>>
    end,
    [Chunk | esc(Rest)].

num(V) -> integer_to_binary(V).

hex_pair(B) -> <<(hx(B bsr 4)), (hx(B band 15))>>.
hx(N) when N < 10 -> $0 + N;
hx(N) -> $a + N - 10.

join([]) -> [];
join([X]) -> [X];
join([X | Xs]) -> [X, <<",">> | join(Xs)].

rows_name(30) -> <<"WRITE_ROWS_EVENT_V2">>;
rows_name(31) -> <<"UPDATE_ROWS_EVENT_V2">>;
rows_name(32) -> <<"DELETE_ROWS_EVENT_V2">>;
rows_name(_)  -> <<"ROWS_EVENT_V2">>.

%% ------------------------------------------------------------------
%% Event dispatch.
%% ------------------------------------------------------------------
emit(Type, T, Size, Body, Reg) ->
    R0 = new_r(Body),
    case Type of
        15 -> % FORMAT_DESCRIPTION_EVENT
            {BV, R1} = rd_le(R0, 2),
            {Tmp, _R2} = rd_raw(R1, 50),
            SV = hd(binary:split(Tmp, <<0>>)),
            Alg = binary:last(Body),
            Line = [<<"{\"type\":\"FORMAT_DESCRIPTION_EVENT\",\"timestamp\":">>, num(T),
                    <<",\"binlog_version\":">>, num(BV),
                    <<",\"server_version\":">>, json_str(SV),
                    <<",\"checksum_alg\":">>, num(Alg), <<"}\n">>],
            {Line, Reg};

        33 -> % GTID_LOG_EVENT
            {_, R1} = rd_le(R0, 1),
            {Sid, R2} = rd_raw(R1, 16),
            {Gno, _R3} = rd_le(R2, 8),
            Hex = list_to_binary([hex_pair(B) || B <- binary:bin_to_list(Sid)]),
            Line = [<<"{\"type\":\"GTID_LOG_EVENT\",\"timestamp\":">>, num(T),
                    <<",\"gno\":">>, num(Gno),
                    <<",\"sid\":">>, json_str(Hex), <<"}\n">>],
            {Line, Reg};

        2 -> % QUERY_EVENT
            {_, R1} = rd_le(R0, 4),
            {_, R2} = rd_le(R1, 4),
            {DbLen, R3} = rd_le(R2, 1),
            {_, R4} = rd_le(R3, 2),
            {SvLen, R5} = rd_le(R4, 2),
            R6 = rd_skip(R5, SvLen),
            {Db, R7} = rd_raw(R6, DbLen),
            {_, R8} = rd_le(R7, 1),
            {Query, _R9} = rd_raw(R8, r_rem(R8)),
            Line = [<<"{\"type\":\"QUERY_EVENT\",\"timestamp\":">>, num(T),
                    <<",\"db\":">>, json_str(Db),
                    <<",\"query\":">>, json_str(Query), <<"}\n">>],
            {Line, Reg};

        29 -> % ROWS_QUERY_LOG_EVENT
            {Len, R1} = rd_lenenc(R0),
            {Q, _R2} = rd_raw(R1, Len),
            Line = [<<"{\"type\":\"ROWS_QUERY_LOG_EVENT\",\"timestamp\":">>, num(T),
                    <<",\"query\":">>, json_str(Q), <<"}\n">>],
            {Line, Reg};

        19 -> % TABLE_MAP_EVENT
            {Tid, R1} = rd_le(R0, 6),
            {_, R2} = rd_le(R1, 2),
            {DbLen, R3} = rd_le(R2, 1),
            {Db, R4} = rd_raw(R3, DbLen),
            {_, R5} = rd_le(R4, 1),
            {TbLen, R6} = rd_le(R5, 1),
            {Tb, R7} = rd_raw(R6, TbLen),
            {_, R8} = rd_le(R7, 1),
            {Cc, R9} = rd_lenenc(R8),
            {TypesBin, R10} = rd_raw(R9, Cc),
            {MdLen, R11} = rd_lenenc(R10),
            MdStart = r_pos(R11),
            TypeList = binary:bin_to_list(TypesBin),
            Vlen = parse_metadata(TypeList, R11),
            R12 = R11#{pos := MdStart + MdLen},
            Nb = (Cc + 7) div 8,
            {NullBm, _R13} = rd_le(R12, Nb),
            Nullable = length([I || I <- lists:seq(0, Cc - 1),
                                    (NullBm band (1 bsl I)) =/= 0]),
            S = #{db => Db, table => Tb, cc => Cc, types => TypeList,
                  vlen => Vlen, nullable => Nullable},
            Reg1 = maps:put(Tid, S, Reg),
            Arr = [<<"[">>, join([num(X) || X <- TypeList]), <<"]">>],
            Line = [<<"{\"type\":\"TABLE_MAP_EVENT\",\"timestamp\":">>, num(T),
                    <<",\"table_id\":">>, num(Tid),
                    <<",\"db\":">>, json_str(Db),
                    <<",\"table\":">>, json_str(Tb),
                    <<",\"column_count\":">>, num(Cc),
                    <<",\"column_types\":">>, Arr, <<"}\n">>],
            {Line, Reg1};

        30 -> emit_rows(Type, T, Body, R0, Reg);
        31 -> emit_rows(Type, T, Body, R0, Reg);
        32 -> emit_rows(Type, T, Body, R0, Reg);

        16 -> % XID_EVENT
            {Xid, _R1} = rd_le(R0, 8),
            Line = [<<"{\"type\":\"XID_EVENT\",\"timestamp\":">>, num(T),
                    <<",\"xid\":">>, num(Xid), <<"}\n">>],
            {Line, Reg};

        4 -> % ROTATE_EVENT
            {Position, R1} = rd_le(R0, 8),
            {Nf, _R2} = rd_raw(R1, r_rem(R1)),
            Line = [<<"{\"type\":\"ROTATE_EVENT\",\"timestamp\":">>, num(T),
                    <<",\"position\":">>, num(Position),
                    <<",\"next_file\":">>, json_str(Nf), <<"}\n">>],
            {Line, Reg};

        _ -> % UNKNOWN -> safe skip
            Line = [<<"{\"type\":\"UNKNOWN\",\"timestamp\":">>, num(T),
                    <<",\"type_id\":">>, num(Type),
                    <<",\"event_size\":">>, num(Size), <<"}\n">>],
            {Line, Reg}
    end.

%% ------------------------------------------------------------------
%% ROWS_EVENT_V2 (30/31/32).
%% ------------------------------------------------------------------
emit_rows(Type, T, _Body, R0, Reg) ->
    {Tid, R1} = rd_le(R0, 6),
    {_, R2} = rd_le(R1, 2),
    {El, R3} = rd_le(R2, 2),
    R4 = rd_skip(R3, max(0, El - 2)),
    {Cc, R5} = rd_lenenc(R4),
    Bm = (Cc + 7) div 8,
    {P1, R6} = rd_le(R5, Bm),
    R7 = case Type of
             31 -> rd_skip(R6, Bm);
             _  -> R6
         end,
    S = case maps:find(Tid, Reg) of
            {ok, V} -> V;
            error -> throw({binlog, no_schema})
        end,
    Nbs = (maps:get(nullable, S) + 7) div 8,
    {RowsIo, _R8} = parse_rows(R7, Nbs, P1, S, []),
    Db = maps:get(db, S),
    Tb = maps:get(table, S),
    Line = [<<"{\"type\":\"">>, rows_name(Type),
            <<"\",\"timestamp\":">>, num(T),
            <<",\"table_id\":">>, num(Tid),
            <<",\"db\":">>, json_str(Db),
            <<",\"table\":">>, json_str(Tb),
            <<",\"rows\":[">>, join(RowsIo), <<"]}\n">>],
    {Line, Reg}.

parse_rows(R, Nbs, P1, S, Acc) ->
    case r_rem(R) of
        0 -> {lists:reverse(Acc), R};
        _ ->
            {NullBm, R1} = rd_le(R, Nbs),
            {RowIo, R2} = parse_row(R1, 0, maps:get(cc, S), P1, NullBm,
                                    maps:get(types, S), maps:get(vlen, S), [], true),
            parse_rows(R2, Nbs, P1, S, [[<<"[">>, RowIo, <<"]">>] | Acc])
    end.

parse_row(R, Cc, Cc, _P1, _NullBm, _Types, _Vlen, Acc, _First) ->
    {lists:reverse(Acc), R};
parse_row(R0, I, Cc, P1, NullBm, Types, Vlen, Acc, First) ->
    Bit = 1 bsl I,
    case (P1 band Bit) of
        0 -> parse_row(R0, I + 1, Cc, P1, NullBm, Types, Vlen, Acc, First);
        _ ->
            Sep = case First of true -> []; false -> [<<",">>] end,
            {ValIo, R1} =
                case (NullBm band Bit) =/= 0 of
                    true -> {[<<"null">>], R0};
                    false ->
                        T = lists:nth(I + 1, Types),
                        case T of
                            8 -> {V, Rx} = rd_le(R0, 8), {[num(V)], Rx};
                            3 -> {V, Rx} = rd_le(R0, 4), {[num(V)], Rx};
                            15 ->
                                Lb0 = lists:nth(I + 1, Vlen),
                                Lb = case Lb0 of 0 -> 1; _ -> Lb0 end,
                                {Slen, Rx} = rd_le(R0, Lb),
                                {Sx, Ry} = rd_raw(Rx, Slen),
                                {json_str(Sx), Ry};
                            _ -> throw({binlog, unsupported})
                        end
                end,
            parse_row(R1, I + 1, Cc, P1, NullBm, Types, Vlen,
                      [ValIo, Sep | Acc], false)
    end.

parse_metadata([], _R) -> [];
parse_metadata([15 | Ts], R0) ->
    {Mx, R1} = rd_le(R0, 2),
    L = case Mx > 255 of true -> 2; false -> 1 end,
    [L | parse_metadata(Ts, R1)];
parse_metadata([_ | Ts], R) ->
    [0 | parse_metadata(Ts, R)].
