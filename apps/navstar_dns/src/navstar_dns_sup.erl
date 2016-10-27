%%%-------------------------------------------------------------------
%% @doc navstar top level supervisor.
%% @end
%%%-------------------------------------------------------------------

-module(navstar_dns_sup).

-behaviour(supervisor).

%% API
-export([start_link/0]).

%% Supervisor callbacks
-export([init/1]).

-define(SERVER, ?MODULE).


%% API
-export([]).
%% Helper macro for declaring children of supervisor
-define(CHILD(I, Type), {I, {I, start_link, []}, permanent, 5000, Type, [I]}).

%% ===================================================================
%% API functions
%% ===================================================================

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

%% ===================================================================
%% Supervisor callbacks
%% ===================================================================

init([]) ->
    KeyMgr =
    #{
        id => navstar_dns_key_mgr,
        start => {navstar_dns_key_mgr, start_link, []},
        restart => transient,
        modules => [navstar_dns_key_mgr],
        type => worker,
        shutdown => 5000
    },
    {ok, {{one_for_one, 5, 10}, [

        ?CHILD(navstar_dns_poll_server, worker),
        ?CHILD(navstar_dns_listener, worker),
        KeyMgr
    ]}}.
