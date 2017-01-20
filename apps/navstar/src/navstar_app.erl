%%%-------------------------------------------------------------------
%% @doc navstar public API
%% @end
%%%-------------------------------------------------------------------

-module('navstar_app').

-behaviour(application).
-define(DEFAULT_CONFIG_LOCATION, "/opt/mesosphere/etc/navstar.app.config").

-define(MASTERS_KEY, {masters, riak_dt_orswot}).

%% Application callbacks
-export([
    start/2,
    stop/1
]).

%%====================================================================
%% API
%%====================================================================

start(_StartType, _StartArgs) ->
    load_config(),
    maybe_add_master(),
    maybe_start_minuteman(),
    'navstar_sup':start_link().

%%--------------------------------------------------------------------
stop(_State) ->
    ok.

%%====================================================================
%% Internal functions
%%====================================================================

maybe_start_minuteman() ->
    LB = application:get_env(navstar, enable_lb, false),
    IPVS = application:get_env(navstar, enable_ipvs, false),
    case {LB,IPVS}  of
        {false, _} ->
            ok;
        {true,true} -> %% minuteman with ipvs
            {ok, _} = application:ensure_all_started(minuteman);
        _ -> %% stable minuteman
            {ok, _} = application:ensure_all_started(minuteman18)
    end.

maybe_add_master() ->
    case application:get_env(navstar, is_master, false) of
        false ->
            ok;
        true ->
            add_master()
    end.

add_master() ->
    Masters = lashup_kv:value([masters]),
    case orddict:find(?MASTERS_KEY, Masters) of
        error ->
            add_master2();
        {ok, Value} ->
            add_master2(Value)
    end.
add_master2(OldMasterList) ->
    case lists:member(node(), OldMasterList) of
        true ->
            ok;
        false ->
            add_master2()
    end.
add_master2() ->
    lashup_kv:request_op([masters],
        {update, [
            {update, ?MASTERS_KEY, {add, node()}}
        ]}).

load_config() ->
    case file:consult(?DEFAULT_CONFIG_LOCATION) of
        {ok, Result} ->
            load_config(Result),
            lager:info("Loaded config: ~p", [?DEFAULT_CONFIG_LOCATION]);
        {error, enoent} ->
            lager:info("Did not load config: ~p", [?DEFAULT_CONFIG_LOCATION])
    end.

load_config([Result = [_]]) ->
    lists:foreach(fun load_app_config/1, Result).

load_app_config({App, Options}) ->
    lists:foreach(fun({OptionKey, OptionValue}) -> application:set_env(App, OptionKey, OptionValue) end, Options).
