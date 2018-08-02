%%%-------------------------------------------------------------------
%% @doc navstar top level supervisor.
%% @end
%%%-------------------------------------------------------------------

-module(navstar_sup).

-behaviour(supervisor).

%% API
-export([start_link/0]).

%% Supervisor callbacks
-export([init/1]).

-define(CHILD(I, Type), {I, {I, start_link, []}, permanent, 5000, Type, [I]}).
-define(SERVER, ?MODULE).

%%====================================================================
%% API functions
%%====================================================================

start_link() ->
    supervisor:start_link({local, ?SERVER}, ?MODULE, []).

%%====================================================================
%% Supervisor callbacks
%%====================================================================

%% Child :: {Id,StartFunc,Restart,Shutdown,Type,Modules}
init([]) ->
    {ok, { {one_for_all, 10000, 1}, [?CHILD(navstar_killer, worker)]} }.

%%====================================================================
%% Internal functions
%%====================================================================
