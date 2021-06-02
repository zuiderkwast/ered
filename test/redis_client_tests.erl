-module(redis_client_tests).

-include_lib("eunit/include/eunit.hrl").

% -compile([export_all]).


run_test_() ->
    [
     {spawn, fun request_t/0},
     {spawn, fun fail_connect_t/0},
     {spawn, fun fail_parse_t/0},
     {spawn, fun server_close_socket_t/0},
     {spawn, fun bad_request_t/0},
     {spawn, fun server_buffer_full_t/0},
     {spawn, fun bad_option_t/0},
     {spawn, fun bad_connection_option_t/0},
     {spawn, fun server_buffer_full_reconnect_t/0},
     {spawn, fun send_timeout_t/0}
    ].

request_t() ->
    {ok, ListenSock} = gen_tcp:listen(0, [binary, {active , false}]),
    {ok, Port} = inet:port(ListenSock),
    spawn_link(fun() ->
		       {ok, Sock} = gen_tcp:accept(ListenSock),
		       {ok, <<"*1\r\n$4\r\nping\r\n">>} = gen_tcp:recv(Sock, 0),
		       ok = gen_tcp:send(Sock, <<"+pong\r\n">>),
		       receive ok -> ok end
	       end),
    {ok,Pid} = redis_client:start_link("127.0.0.1", Port, []),
    {ok, <<"pong">>} = redis_client:request(Pid, <<"ping">>).


fail_connect_t() ->
    {ok,Pid} = redis_client:start_link("127.0.0.1", 0, [{info_pid, self()}]),
    {Pid, {connection_down,{connect_error,econnrefused}}} = get_msg(),
    % make sure there are no more connection down messages
    timeout = receive _ -> ok after 500 -> timeout end.


fail_parse_t() ->
    {ok, ListenSock} = gen_tcp:listen(0, [binary, {active , false}]),
    {ok, Port} = inet:port(ListenSock),
    spawn_link(fun() ->
		       {ok, Sock} = gen_tcp:accept(ListenSock),
		       {ok, <<"*1\r\n$4\r\nping\r\n">>} = gen_tcp:recv(Sock, 0),
		       %% bad format of message
		       ok = gen_tcp:send(Sock, <<"&pong\r\n">>),

		       %% resend from client
		       {ok, Sock2} = gen_tcp:accept(ListenSock),
		       {ok, <<"*1\r\n$4\r\nping\r\n">>} = gen_tcp:recv(Sock2, 0),
		       ok = gen_tcp:send(Sock2, <<"+pong\r\n">>),
		       receive ok -> ok end
	       end),
    {ok, Client} = redis_client:start_link("127.0.0.1", Port, [{info_pid, self()}]),
    Pid = self(),
    spawn_link(fun() ->
		       Pid ! redis_client:request(Client, <<"ping">>)
	       end),
    {Client, connection_up} = get_msg(),
    {Client, {connection_down,{parse_error,{invalid_data,<<"&pong">>}}}} = get_msg(),
    {Client, connection_up} = get_msg(),
    {ok, <<"pong">>} = get_msg().


server_close_socket_t() ->
    {ok, ListenSock} = gen_tcp:listen(0, [binary, {active , false}]),
    {ok, Port} = inet:port(ListenSock),
    spawn_link(fun() ->
		       {ok, Sock} = gen_tcp:accept(ListenSock),
		       gen_tcp:close(Sock),

		       %% resend from client
		       {ok, Sock2} = gen_tcp:accept(ListenSock),
		       receive ok -> ok end
	       end),
    {ok, Client} = redis_client:start_link("127.0.0.1", Port, [{info_pid, self()}]),
    {Client, connection_up} = get_msg(),
    {Client, {connection_down,{recv_error, closed}}} = get_msg(),
    {Client, connection_up} = get_msg().


bad_request_t() ->
    {ok, ListenSock} = gen_tcp:listen(0, [binary, {active , false}]),
    {ok, Port} = inet:port(ListenSock),
    spawn_link(fun() ->
		       {ok, Sock} = gen_tcp:accept(ListenSock),
		       receive ok -> ok end
	       end),
    {ok, Client} = redis_client:start_link("127.0.0.1", Port, [{info_pid, self()}]),
    {Client, connection_up} = get_msg(),
    ?_assertException(error, badarg, redis_client:request(Client, bad_request)).


server_buffer_full_t() ->
    {ok, ListenSock} = gen_tcp:listen(0, [binary, {active , false}]),
    {ok, Port} = inet:port(ListenSock),
    spawn_link(fun() ->
		       {ok, Sock} = gen_tcp:accept(ListenSock),
		       % expect 5 ping
		       Ping = <<"*1\r\n$4\r\nping\r\n">>,
		       Expected = iolist_to_binary(lists:duplicate(5, Ping)),
		       {ok, Expected} = gen_tcp:recv(Sock, size(Expected)),
		       % should be nothing more since only 5 pending
		       {error, timeout} = gen_tcp:recv(Sock, 0, 0),

		       timer:sleep(500),

		       gen_tcp:send(Sock, lists:duplicate(5, <<"+pong\r\n">>)),

		       % next the 5 waiting
		       {ok, Expected} = gen_tcp:recv(Sock, size(Expected)),
		       % should be nothing more since only 5 pending
		       {error, timeout} = gen_tcp:recv(Sock, 0, 0),
		       gen_tcp:send(Sock, lists:duplicate(5, <<"+pong\r\n">>)),

		       receive ok -> ok end
	       end),
    {ok, Client} = redis_client:start_link("127.0.0.1", Port, [{info_pid, self()}, {max_waiting, 5}, {max_pending, 5}]),
    {Client, connection_up} = get_msg(),

    Pid = self(),
    [redis_client:request_cb(Client, <<"ping">>, fun(Reply) -> Pid ! {N, Reply} end) || N <- lists:seq(1,11)],
    {6, {error, queue_overflow}} = get_msg(),
    [{N, {ok, <<"pong">>}} = get_msg()|| N <- [1,2,3,4,5,7,8,9,10,11]].


server_buffer_full_reconnect_t() ->
    {ok, ListenSock} = gen_tcp:listen(0, [binary, {active , false}]),
    {ok, Port} = inet:port(ListenSock),
    spawn_link(fun() ->
		       {ok, Sock} = gen_tcp:accept(ListenSock),
		       % expect 5 ping
		       Ping = <<"*1\r\n$4\r\nping\r\n">>,
		       Expected = iolist_to_binary(lists:duplicate(5, Ping)),
		       {ok, Expected} = gen_tcp:recv(Sock, size(Expected)),
		       % should be nothing more since only 5 pending
		       {error, timeout} = gen_tcp:recv(Sock, 0, 0),

		       gen_tcp:close(Sock),

		       {ok, Sock2} = gen_tcp:accept(ListenSock),
		       {ok, Expected} = gen_tcp:recv(Sock2, size(Expected)),

		       gen_tcp:send(Sock2, lists:duplicate(5, <<"+pong\r\n">>)),
		       % should be nothing more since only 5 pending
		       {error, timeout} = gen_tcp:recv(Sock2, 0, 0),
		       receive ok -> ok end

	       end),
    {ok, Client} = redis_client:start_link("127.0.0.1", Port, [{info_pid, self()}, {max_waiting, 5}, {max_pending, 5}]),
    {Client, connection_up} = get_msg(),

    Pid = self(),
    [redis_client:request_cb(Client, <<"ping">>, fun(Reply) -> Pid ! {N, Reply} end) || N <- lists:seq(1,11)],
    {6, {error, queue_overflow}} = get_msg(),
    {Client, {connection_down,{recv_error, closed}}} = get_msg(),
    [{N, {error, queue_overflow}} = get_msg() || N <- [1,2,3,4,5]],
    {Client, connection_up} = get_msg(),
    [{N, {ok, <<"pong">>}} = get_msg() || N <- [7,8,9,10,11]].


bad_option_t() ->
    ?_assertError({badarg,bad_option}, redis_client:start_link("127.0.0.1", 0, [bad_option])).

bad_connection_option_t() ->
    ?_assertError({badarg,bad_option}, redis_client:start_link("127.0.0.1", 0,
							       [{info_pid, self()},
								{connection_opts, [bad_option]}])).

send_timeout_t() ->
    {ok, ListenSock} = gen_tcp:listen(0, [binary, {active , false}]),
    {ok, Port} = inet:port(ListenSock),
    spawn_link(fun() ->
		       {ok, Sock} = gen_tcp:accept(ListenSock),
		       {ok, <<"*1\r\n$4\r\nping\r\n">>} = gen_tcp:recv(Sock, 0),

		       % do nothing more on first socket, wait for timeout and reconnect
		       {ok, Sock2} = gen_tcp:accept(ListenSock),
		       {ok, <<"*1\r\n$4\r\nping\r\n">>} = gen_tcp:recv(Sock2, 0),
		       ok = gen_tcp:send(Sock2, <<"+pong\r\n">>),
		       receive ok -> ok end
	       end),
    {ok, Client} = redis_client:start_link("127.0.0.1", Port, [{info_pid, self()},
							       {connection_opts, [{response_timeout, 100}]}
							       ]),
    {Client, connection_up} = get_msg(),
    Pid = self(),
    redis_client:request_cb(Client, <<"ping">>, fun(Reply) -> Pid ! {reply, Reply} end),
    % this should come after max 1000ms
    {Client, {connection_down, {recv_error,timeout}}} = get_msg(200),
    {Client, connection_up} = get_msg(),
    {reply, {ok, <<"pong">>}} = get_msg(),
    no_more_msgs().


get_msg() ->
    get_msg(infinity).

get_msg(Timeout) ->
    receive Msg -> Msg after Timeout -> timeout end.

no_more_msgs() ->
    timeout = get_msg(0).

%% close
%% connect resp3/password/etc
%% Add test description
%% Add help function for receive

