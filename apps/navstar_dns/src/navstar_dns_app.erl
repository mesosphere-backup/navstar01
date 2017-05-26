%%%-------------------------------------------------------------------
%% @doc navstar public API
%% @end
%%%-------------------------------------------------------------------

-module('navstar_dns_app').

-behaviour(application).

%% Application callbacks
-export([
    start/2,
    stop/1
]).

%%====================================================================
%% API
%%====================================================================

start(_StartType, _StartArgs) ->
    navstar_app:load_config_files(navstar_dns),
    'navstar_dns_sup':start_link().

%%--------------------------------------------------------------------
stop(_State) ->
    ok.
