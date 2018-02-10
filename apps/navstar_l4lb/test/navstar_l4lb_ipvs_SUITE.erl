%%%-------------------------------------------------------------------
%%% @author sdhillon
%%% @copyright (C) 2016, <COMPANY>
%%% @doc
%%%
%%% @end
%%% Created : 22. Oct 2016 9:37 PM
%%%-------------------------------------------------------------------
-module(navstar_l4lb_ipvs_SUITE).
-author("sdhillon").

-include_lib("common_test/include/ct.hrl").
-include("navstar_l4lb.hrl").

%% These tests rely on some commands that circle ci does automatically
%% Look at circle.yml for more
-export([all/0]).

-export([test_v4/1, test_v6/1]).

-export([init_per_testcase/2, end_per_testcase/2]).

all() -> all(os:cmd("id -u"), os:getenv("CIRCLECI")).

-compile(export_all).

%% root tests
all("0\n", false) ->
    [test_v4, test_v6];

%% non root tests
all(_, _) -> [].

init_per_testcase(_, Config) ->
    "" = os:cmd("ipvsadm -C"),
    os:cmd("ip link del minuteman"),
    os:cmd("ip link add minuteman type dummy"),
    os:cmd("ip link del webserver"),
    os:cmd("ip link add webserver type dummy"),
    os:cmd("ip link set webserver up"),
    os:cmd("ip addr add 1.1.1.1/32 dev webserver"),
    os:cmd("ip addr add 1.1.1.2/32 dev webserver"),
    os:cmd("ip addr add 1.1.1.3/32 dev webserver"),
    os:cmd("ip addr add fc01::1/128 dev webserver"),
    application:set_env(navstar_l4lb, agent_polling_enabled, false),
    {ok, _} = application:ensure_all_started(inets),
    {ok, _} = application:ensure_all_started(navstar_l4lb),
    Config.

end_per_testcase(_, _Config) ->
    ok = application:stop(navstar_l4lb),
    ok = application:stop(lashup),
    ok = application:stop(mnesia).

make_v4_webserver(Idx) ->
    make_webserver({1, 1, 1, Idx}).

make_v6_webserver() ->
    make_webserver({16#fc01, 16#0, 16#0, 16#0, 16#0, 16#0, 16#0, 16#1}).
    
make_webserver(IP) ->
    file:make_dir("/tmp/htdocs"),
    {ok, Pid} = inets:start(httpd, [
        {port, 0},
        {server_name, "httpd_test"},
        {server_root, "/tmp"},
        {document_root, "/tmp/htdocs"},
        {bind_address, IP}
    ]),
    Pid.

%webservers() ->
%    lists:map(fun make_webserver/1, lists:seq(1,3)).

webserver(Pid) ->
    Info = httpd:info(Pid),
    Port = proplists:get_value(port, Info),
    IP = proplists:get_value(bind_address, Info),
    {IP, Port}.

add_webserver(VIP, {IP, Port}) ->
    % inject an update for this vip
    {ok, _} = lashup_kv:request_op(?VIPS_KEY2, {update, [{update, {VIP, riak_dt_orswot}, {add, {IP, {IP, Port}}}}]}).

remove_webserver(VIP, {IP, Port}) ->
    % inject an update for this vip
    {ok, _} = lashup_kv:request_op(?VIPS_KEY2, {update, [{update, {VIP, riak_dt_orswot}, {remove, {IP, {IP, Port}}}}]}).

remove_vip(VIP) ->
    {ok, _} = lashup_kv:request_op(?VIPS_KEY2, {update, [{remove, {VIP, riak_dt_orswot}}]}).


test_vip(Family, VIP) ->
    %% Wait for lashup state to take effect
    timer:sleep(1000),
    test_vip(3, Family, VIP).

test_vip(0, _, _) ->
    error;
test_vip(Tries, Family, VIP = {tcp, IP0, Port}) ->
    IP1 = inet:ntoa(IP0),
    URI = uri(Family, IP1, Port),
    case httpc:request(get, {URI, _Headers = []}, [{timeout, 500}, {connect_timeout, 500}], []) of
        {ok, _} ->
            ok;
        {error, _} ->
            test_vip(Tries - 1, VIP)
    end.

uri(inet, IP, Port) ->
    lists:flatten(io_lib:format("http://~s:~b/", [IP, Port]));
uri(inet6, IP, Port) ->
    lists:flatten(io_lib:format("http://[~s]:~b/", [IP, Port])).

test_v4(_Config) ->
    Family = inet,
    timer:sleep(1000),
    W1 = make_v4_webserver(1),
    W2 = make_v4_webserver(2),
    VIP = {tcp, {11, 0, 0, 1}, 8080},
    add_webserver(VIP, webserver(W1)),
    ok = test_vip(Family, VIP),
    remove_webserver(VIP, webserver(W1)),
    inets:stop(stand_alone, W1),
    add_webserver(VIP, webserver(W2)),
    ok = test_vip(Family, VIP),
    remove_webserver(VIP, webserver(W2)),
    error = test_vip(Family, VIP),
    remove_vip(VIP),
    error = test_vip(Family, VIP).

test_v6(_Config) ->
    Family = inet6,
    timer:sleep(1000),
    W = make_v6_webserver(),
    VIP = {tcp, {16#fd01, 16#0, 16#0, 16#0, 16#0, 16#0, 16#0, 16#1}, 8080},
    add_webserver(VIP, webserver(W)),
    ok = test_vip(Family, VIP),
    remove_webserver(VIP, webserver(W)),
    error = test_vip(Family, VIP),
    remove_vip(VIP),
    error = test_vip(Family, VIP).
