%%%-------------------------------------------------------------------
%% @doc navstar public API
%% @end
%%%-------------------------------------------------------------------

-module(navstar_overlay_app).
-behaviour(application).

%% Application callbacks
-export([start/2,
         stop/1]).

%%====================================================================
%% API
%%====================================================================

start(_StartType, _StartArgs) ->
    navstar_overlay_sup:start_link([application:get_env(navstar_overlay, enable_overlay, true)]).

stop(_State) ->
    ok.
