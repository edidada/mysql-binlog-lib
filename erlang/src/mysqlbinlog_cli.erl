%%% CLI entry module for the Erlang implementation (invoked by escript).
-module(mysqlbinlog_cli).

-export([run/1]).

usage() ->
    io:format(standard_error,
              "Usage: mysqlbinlog-erl --file <path> [--format jsonl]~n", []).

collect(["--help" | _]) -> help;
collect(Args) -> collect(Args, undefined, "jsonl").

collect([], Path, Fmt) -> {Path, Fmt};
collect(["--file", P | Rest], _Path, Fmt) -> collect(Rest, P, Fmt);
collect(["--format", F | Rest], Path, _Fmt) -> collect(Rest, Path, F);
collect([_ | Rest], Path, Fmt) -> collect(Rest, Path, Fmt).

-spec run([string()]) -> ok | no_return().
run(Args) ->
    case collect(Args) of
        help ->
            usage(),
            ok;
        {undefined, _} ->
            usage(),
            halt(2);
        {_Path, Fmt} when Fmt =/= "jsonl" ->
            io:format(standard_error, "only --format jsonl is supported~n", []),
            halt(2);
        {Path, _} ->
            run_file(Path)
    end.

run_file(Path) ->
    case file:read_file(Path) of
        {ok, Bin} ->
            case mysqlbinlog:parse_buffer(Bin) of
                {ok, Io} ->
                    io:put_chars(Io),
                    ok;
                {error, E} ->
                    io:format(standard_error, "parse failed: ~p~n", [E]),
                    halt(1)
            end;
        {error, E} ->
            io:format(standard_error, "cannot open file: ~p: ~p~n", [Path, E]),
            halt(2)
    end.
