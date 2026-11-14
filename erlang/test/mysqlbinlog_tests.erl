%%% EUnit tests (OTP built-in, no third-party deps).
-module(mysqlbinlog_tests).

-include_lib("eunit/include/eunit.hrl").

crc32_test() ->
    ?assertEqual(16#CBF43926, mysqlbinlog:crc32(<<"123456789">>)).

header_test() ->
    H = <<16#00:8, 16#F1:8, 16#53:8, 16#65:8, 15:8,
          1:32/little, 119:32/little, 123:32/little, 0:16/little>>,
    {ok, M} = mysqlbinlog:parse_header(H),
    ?assertEqual(1700000000, maps:get(ts, M)),
    ?assertEqual(15, maps:get(type, M)),
    ?assertEqual(1, maps:get(sid, M)),
    ?assertEqual(119, maps:get(size, M)),
    ?assertEqual(123, maps:get(next, M)),
    ?assertEqual(0, maps:get(flags, M)).

truncated_header_test() ->
    ?assertEqual({error, truncated}, mysqlbinlog:parse_header(<<0:80>>)).

bad_magic_test() ->
    ?assertEqual({error, invalid}, mysqlbinlog:parse_buffer(<<0, 0, 0, 0>>)).

golden_test() ->
    {ok, Data} = file:read_file("fixtures/demo.bin"),
    {ok, Expected} = file:read_file("fixtures/expected.jsonl"),
    {ok, Io} = mysqlbinlog:parse_buffer(Data),
    ?assertEqual(Expected, iolist_to_binary(Io)).
