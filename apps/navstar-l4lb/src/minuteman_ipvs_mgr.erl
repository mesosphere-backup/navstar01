%%%-------------------------------------------------------------------
%%% @author sdhillon
%%% @copyright (C) 2016, <COMPANY>
%%% @doc
%%%
%%% @end
%%% Created : 01. Nov 2016 7:35 AM
%%%-------------------------------------------------------------------
-module(minuteman_ipvs_mgr).
-author("sdhillon").

-behaviour(gen_server).

%% API
-export([start_link/0]).

-export([get_dests/2,
         add_dest/4,
         remove_dest/3,
         add_dest/6,
         remove_dest/6]).
-export([get_services/1,
         add_service/4,
         remove_service/2,
         remove_service/4]).
-export([service_address/1,
         destination_address/1]).

%% gen_server callbacks
-export([init/1,
         handle_call/3,
         handle_cast/2,
         handle_info/2,
         terminate/2,
         code_change/3]).

-define(SERVER, ?MODULE).

-record(state, {
    netlink_generic :: pid(),
    family
}).
-type state() :: #state{}.
-include_lib("gen_netlink/include/netlink.hrl").

-define(IP_VS_CONN_F_FWD_MASK, 16#7).       %%  mask for the fwd methods
-define(IP_VS_CONN_F_MASQ, 16#0).           %%  masquerading/NAT
-define(IP_VS_CONN_F_LOCALNODE, 16#1).      %%  local node
-define(IP_VS_CONN_F_TUNNEL, 16#2).         %%  tunneling
-define(IP_VS_CONN_F_DROUTE, 16#3).         %%  direct routing
-define(IP_VS_CONN_F_BYPASS, 16#4).         %%  cache bypass
-define(IP_VS_CONN_F_SYNC, 16#20).          %%  entry created by sync
-define(IP_VS_CONN_F_HASHED, 16#40).        %%  hashed entry
-define(IP_VS_CONN_F_NOOUTPUT, 16#80).      %%  no output packets
-define(IP_VS_CONN_F_INACTIVE, 16#100).     %%  not established
-define(IP_VS_CONN_F_OUT_SEQ, 16#200).      %%  must do output seq adjust
-define(IP_VS_CONN_F_IN_SEQ, 16#400).       %%  must do input seq adjust
-define(IP_VS_CONN_F_SEQ_MASK, 16#600).     %%  in/out sequence mask
-define(IP_VS_CONN_F_NO_CPORT, 16#800).     %%  no client port set yet
-define(IP_VS_CONN_F_TEMPLATE, 16#1000).    %%  template, not connection
-define(IP_VS_CONN_F_ONE_PACKET, 16#2000).  %%  forward only one packet

-define(IP_VS_SVC_F_PERSISTENT, 16#1).          %% persistent port */
-define(IP_VS_SVC_F_HASHED,     16#2).          %% hashed entry */
-define(IP_VS_SVC_F_ONEPACKET,  16#4).          %% one-packet scheduling */
-define(IP_VS_SVC_F_SCHED1,     16#8).          %% scheduler flag 1 */
-define(IP_VS_SVC_F_SCHED2,     16#10).          %% scheduler flag 2 */
-define(IP_VS_SVC_F_SCHED3,     16#20).          %% scheduler flag 3 */

-define(IPVS_PROTOCOLS, [tcp, udp]). %% protocols to query gen_netlink for

-type service() :: term().
-type dest() :: term().
-export_type([service/0, dest/0]).

%%%===================================================================
%%% API
%%%===================================================================

-spec(get_services(Pid :: pid()) -> [service()]).
get_services(Pid) ->
    gen_server:call(Pid, get_services).

-spec(add_service(Pid :: pid(), IP :: inet:ip4_address(), Port :: inet:port_number(),
                  Protocol :: protocol()) -> ok | error).
add_service(Pid, IP, Port, Protocol) ->
    gen_server:call(Pid, {add_service, IP, Port, Protocol}).

-spec(remove_service(Pid :: pid(), Service :: service()) -> ok | error).
remove_service(Pid, Service) ->
    gen_server:call(Pid, {remove_service, Service}).

-spec(remove_service(Pid :: pid(), IP :: inet:ip4_address(),
                     Port :: inet:port_number(),
                     Protocol :: protocol()) -> ok | error).
remove_service(Pid, IP, Port, Protocol) ->
    gen_server:call(Pid, {remove_service, IP, Port, Protocol}).

-spec(get_dests(Pid :: pid(), Service :: service()) -> [dest()]).
get_dests(Pid, Service) ->
    gen_server:call(Pid, {get_dests, Service}).

-spec(remove_dest(Pid :: pid(), Service :: service(),
                  Dest :: dest()) -> ok | error).
remove_dest(Pid, Service, Dest) ->
    gen_server:call(Pid, {remove_dest, Service, Dest}).

-spec(remove_dest(Pid :: pid(), ServiceIP :: inet:ip4_address(),
                  ServicePort :: inet:port_number(),
                  DestIP :: inet:ip4_address(), DestPort :: inet:port_number(),
                  Protocol :: protocol()) -> ok | error).
remove_dest(Pid, ServiceIP, ServicePort, DestIP, DestPort, Protocol) ->
    gen_server:call(Pid, {remove_dest, ServiceIP, ServicePort, DestIP, DestPort, Protocol}).

-spec(add_dest(Pid :: pid(), Service :: service(), IP :: inet:ip4_address(),
               Port :: inet:port_number()) -> ok | error).
add_dest(Pid, Service, IP, Port) ->
    gen_server:call(Pid, {add_dest, Service, IP, Port}).

-spec(add_dest(Pid :: pid(), ServiceIP :: inet:ip4_address(), ServicePort :: inet:port_number(),
               DestIP :: inet:ip4_address(), DestPort :: inet:port_number(),
               Protocol :: protocol()) -> ok | error).
add_dest(Pid, ServiceIP, ServicePort, DestIP, DestPort, Protocol) ->
    gen_server:call(Pid, {add_dest, ServiceIP, ServicePort, DestIP, DestPort, Protocol}).

%%--------------------------------------------------------------------
%% @doc
%% Starts the server
%%
%% @end
%%--------------------------------------------------------------------
-spec(start_link() ->
    {ok, Pid :: pid()} | ignore | {error, Reason :: term()}).
start_link() ->
    gen_server:start_link(?MODULE, [], []).

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Initializes the server
%%
%% @spec init(Args) -> {ok, State} |
%%                     {ok, State, Timeout} |
%%                     ignore |
%%                     {stop, Reason}
%% @end
%%--------------------------------------------------------------------
-spec(init(Args :: term()) ->
    {ok, State :: state()} | {ok, State :: state(), timeout() | hibernate} |
    {stop, Reason :: term()} | ignore).
init([]) ->
    {ok, Pid} = gen_netlink_client:start_link(),
    {ok, Family} = gen_netlink_client:get_family(Pid, "IPVS"),
    {ok, #state{netlink_generic = Pid, family = Family}}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling call messages
%%
%% @end
%%--------------------------------------------------------------------
-spec(handle_call(Request :: term(), From :: {pid(), Tag :: term()},
    State :: state()) ->
    {reply, Reply :: term(), NewState :: state()} |
    {reply, Reply :: term(), NewState :: state(), timeout() | hibernate} |
    {noreply, NewState :: state()} |
    {noreply, NewState :: state(), timeout() | hibernate} |
    {stop, Reason :: term(), Reply :: term(), NewState :: state()} |
    {stop, Reason :: term(), NewState :: state()}).

handle_call(get_services, _From, State) ->
    Reply = handle_get_services(State),
    {reply, Reply, State};
handle_call({add_service, IP, Port, Protocol}, _From, State) ->
    Reply = handle_add_service(IP, Port, Protocol, State),
    {reply, Reply, State};
handle_call({remove_service, Service}, _From, State) ->
    Reply = handle_remove_service(Service, State),
    {reply, Reply, State};
handle_call({remove_service, IP, Port, Protocol}, _From, State) ->
    Reply = handle_remove_service(IP, Port, Protocol, State),
    {reply, Reply, State};
handle_call({get_dests, Service}, _From, State) ->
    Reply = handle_get_dests(Service, State),
    {reply, Reply, State};
handle_call({add_dest, Service, IP, Port}, _From, State) ->
    Reply = handle_add_dest(Service, IP, Port, State),
    {reply, Reply, State};
handle_call({add_dest, ServiceIP, ServicePort, DestIP, DestPort, Protocol}, _From, State) ->
    Reply = handle_add_dest(ServiceIP, ServicePort, DestIP, DestPort, Protocol, State),
    {reply, Reply, State};
handle_call({remove_dest, Service, Dest}, _From, State) ->
    Reply = handle_remove_dest(Service, Dest, State),
    {reply, Reply, State};
handle_call({remove_dest, ServiceIP, ServicePort, DestIP, DestPort, Protocol}, _From, State) ->
    Reply = handle_remove_dest(ServiceIP, ServicePort, DestIP, DestPort, Protocol, State),
    {reply, Reply, State}.

-spec(service_address(service()) -> {protocol(), inet:ip4_address(), inet:port_number()}).
service_address(Service) ->
    % proactively added default because centos-7.2 3.10.0-514.6.1.el7.x86_64 kernel is
    % missing this property for destination addresses
    Inet = netlink_codec:family_to_int(inet),
    AF = proplists:get_value(address_family, Service, Inet),
    Protocol = netlink_codec:protocol_to_atom(proplists:get_value(protocol, Service)),
    AddressBin = proplists:get_value(address, Service),
    AddressList = binary:bin_to_list(AddressBin),
    Port = proplists:get_value(port, Service),
    case netlink_codec:family_to_atom(AF) of
        inet ->
            InetAddr = list_to_tuple(lists:sublist(AddressList, 4)),
            {Protocol, InetAddr, Port}
    end.

-spec(destination_address(Destination :: dest()) -> {inet:ip4_address(), inet:port_number()}).
destination_address(Destination) ->
    % centos-7.2 3.10.0-514.6.1.el7.x86_64 kernel is missing this property
    Inet = netlink_codec:family_to_int(inet),
    AF = proplists:get_value(address_family, Destination, Inet),
    AddressBin = proplists:get_value(address, Destination),
    AddressList = binary:bin_to_list(AddressBin),
    Port = proplists:get_value(port, Destination),
    case netlink_codec:family_to_atom(AF) of
        inet ->
            InetAddr = list_to_tuple(lists:sublist(AddressList, 4)),
            {InetAddr, Port}
    end.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling cast messages
%%
%% @end
%%--------------------------------------------------------------------
-spec(handle_cast(Request :: term(), State :: state()) ->
    {noreply, NewState :: state()} |
    {noreply, NewState :: state(), timeout() | hibernate} |
    {stop, Reason :: term(), NewState :: state()}).
handle_cast(_Request, State) ->
    {noreply, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling all non call/cast messages
%%
%% @spec handle_info(Info, State) -> {noreply, State} |
%%                                   {noreply, State, Timeout} |
%%                                   {stop, Reason, State}
%% @end
%%--------------------------------------------------------------------
-spec(handle_info(Info :: timeout() | term(), State :: state()) ->
    {noreply, NewState :: state()} |
    {noreply, NewState :: state(), timeout() | hibernate} |
    {stop, Reason :: term(), NewState :: state()}).
handle_info(_Info, State) ->
    {noreply, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% This function is called by a gen_server when it is about to
%% terminate. It should be the opposite of Module:init/1 and do any
%% necessary cleaning up. When it returns, the gen_server terminates
%% with Reason. The return value is ignored.
%%
%% @spec terminate(Reason, State) -> void()
%% @end
%%--------------------------------------------------------------------
-spec(terminate(Reason :: (normal | shutdown | {shutdown, term()} | term()),
    State :: state()) -> term()).
terminate(_Reason, _State) ->
    ok.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Convert process state when code is changed
%%
%% @spec code_change(OldVsn, State, Extra) -> {ok, NewState}
%% @end
%%--------------------------------------------------------------------
-spec(code_change(OldVsn :: term() | {down, term()}, State :: state(),
    Extra :: term()) ->
    {ok, NewState :: state()} | {error, Reason :: term()}).
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%%===================================================================
%%% Internal functions
%%%===================================================================

-spec(handle_get_services(State :: state()) -> [service()]).
handle_get_services(State) ->
    lists:foldl(
      fun(Protocol, Acc) ->
              Services = handle_get_services(inet, Protocol, State),
              Acc ++ Services
      end, [], ?IPVS_PROTOCOLS).

-spec(handle_get_services(AddressFamily :: family(), Protocol :: protocol(),
                          State :: state()) -> [service()]).
handle_get_services(AddressFamily, Protocol, #state{netlink_generic = Pid, family = Family}) ->
    AddressFamily1 = netlink_codec:family_to_int(AddressFamily),
    Protocol1 = netlink_codec:protocol_to_int(Protocol),
    Message =
        #get_service{
           request =
               [{service,
                 [{address_family, AddressFamily1},
                  {protocol, Protocol1}
                 ]}
               ]},
    {ok, Replies} = gen_netlink_client:request(Pid, Family, ipvs, [root, match], Message),
    [proplists:get_value(service, MaybeService)
     || #netlink{msg = #new_service{request = MaybeService}}
            <- Replies,
        proplists:is_defined(service, MaybeService)].

-spec(handle_remove_service(IP :: inet:ip4_address(), Port :: inet:port_number(),
                            Protocol :: protocol(),
                            State :: state()) -> ok | error).
handle_remove_service(IP, Port, Protocol, State) ->
    Protocol1 = netlink_codec:protocol_to_int(Protocol),
    Service = ip_to_address(IP) ++ [{port, Port}, {protocol, Protocol1}],
    handle_remove_service(Service, State).

-spec(handle_remove_service(Service :: service(), State :: state()) -> ok | error).
handle_remove_service(Service, #state{netlink_generic = Pid, family = Family}) ->
    case gen_netlink_client:request(Pid, Family, ipvs, [], #del_service{request = [{service, Service}]}) of
        {ok, _} -> ok;
        _ -> error
    end.

-spec(handle_add_service(IP :: inet:ip4_address(), Port :: inet:port_number(),
                         Protocol :: protocol(), State :: state()) -> ok | error).
handle_add_service(IP, Port, Protocol, #state{netlink_generic = Pid, family = Family}) ->
    Flags = 0,
    Service0 = [
        {protocol, netlink_codec:protocol_to_int(Protocol)},
        {port, Port},
        {sched_name, "wlc"},
        {netmask, 16#ffffffff},
        {flags, Flags, 16#ffffffff},
        {timeout, 0}
    ],
    Service1 = ip_to_address(IP) ++ Service0,
    lager:info("Adding Service: ~p", [Service1]),
    case gen_netlink_client:request(Pid, Family, ipvs, [], #new_service{request = [{service, Service1}]}) of
        {ok, _} -> ok;
        _ -> error
    end.

-spec(handle_get_dests(Service :: service(), State :: state()) -> [dest()]).
handle_get_dests(Service, #state{netlink_generic = Pid, family = Family}) ->
    Message = #get_dest{request = [{service, Service}]},
    {ok, Replies} = gen_netlink_client:request(Pid, Family, ipvs, [root, match], Message),
    [proplists:get_value(dest, MaybeDest) || #netlink{msg = #new_dest{request = MaybeDest}} <- Replies,
        proplists:is_defined(dest, MaybeDest)].

-spec(handle_add_dest(ServiceIP :: inet:ip4_address(), ServicePort :: inet:port_number(),
                      DestIP :: inet:ip4_address(), DestPort :: inet:port_number(),
                      Protocol :: protocol(), State :: state()) -> ok | error).
handle_add_dest(ServiceIP, ServicePort, DestIP, DestPort, Protocol, State) ->
    Protocol1 = netlink_codec:protocol_to_int(Protocol),
    Service = ip_to_address(ServiceIP) ++ [{port, ServicePort}, {protocol, Protocol1}],
    handle_add_dest(Service, DestIP, DestPort, State).

-spec(handle_add_dest(Service :: service(), IP :: inet:ip4_address(),
                      Port :: inet:port_number(), State :: state()) -> ok | error).
handle_add_dest(Service, IP, Port, #state{netlink_generic = Pid, family = Family}) ->
    Base = [{fwd_method, ?IP_VS_CONN_F_MASQ}, {weight, 1}, {u_threshold, 0}, {l_threshold, 0}],
    Dest = [{port, Port}] ++ Base ++ ip_to_address(IP),
    lager:info("Adding backend ~p to service ~p~n", [{IP, Port}, Service]),
    Msg = #new_dest{request = [{dest, Dest}, {service, Service}]},
    case gen_netlink_client:request(Pid, Family, ipvs, [], Msg) of
        {ok, _} -> ok;
        _ -> error
    end.

-spec(handle_remove_dest(ServiceIP :: inet:ip4_address(), ServicePort :: inet:port_number(),
                         DestIP :: inet:ip4_address(), DestPort :: inet:port_number(),
                         Protocol :: protocol(), State :: state()) -> ok | error).
handle_remove_dest(ServiceIP, ServicePort, DestIP, DestPort, Protocol, State) ->
    Protocol1 = netlink_codec:protocol_to_int(Protocol),
    Service = ip_to_address(ServiceIP) ++ [{port, ServicePort}, {protocol, Protocol1}],
    Dest = ip_to_address(DestIP) ++ [{port, DestPort}],
    handle_remove_dest(Service, Dest, State).

-spec(handle_remove_dest(Service :: service(), Dest :: dest(), State :: state()) -> ok | error).
handle_remove_dest(Service, Dest, #state{netlink_generic = Pid, family = Family}) ->
    lager:info("Deleting Dest: ~p~n", [Dest]),
    Msg = #del_dest{request = [{dest, Dest}, {service, Service}]},
    case gen_netlink_client:request(Pid, Family, ipvs, [], Msg) of
        {ok, _} -> ok;
        _ -> error
    end.

ip_to_address(IP0) when size(IP0) == 4 ->
    [{address_family, netlink_codec:family_to_int(inet)}, {address, ip_to_address2(IP0)}];
ip_to_address(IP0) when size(IP0) == 16 ->
    [{address_family, netlink_codec:family_to_int(inet6)}, {address, ip_to_address2(IP0)}].

ip_to_address2(IP0) ->
    IP1 = tuple_to_list(IP0),
    IP2 = binary:list_to_bin(IP1),
    Padding = 8 * (16 - size(IP2)),
    <<IP2/binary, 0:Padding/integer>>.

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").

destination_address_test_() ->
    D = [{address, <<10, 10, 0, 83, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0>>},
         {port, 9042},
         {fwd_method, 0},
         {weight, 1},
         {u_threshold, 0},
         {l_threshold, 0},
         {active_conns, 0},
         {inact_conns, 0},
         {persist_conns, 0},
         {stats, [{conns, 0},
                 {inpkts, 0},
                 {outpkts, 0},
                 {inbytes, 0},
                 {outbytes, 0},
                 {cps, 0},
                 {inpps, 0},
                 {outpps, 0},
                 {inbps, 0},
                 {outbps, 0}]}],
    DAddr = {{10, 10, 0, 83}, 9042},
    [?_assertEqual(DAddr, destination_address(D))].

service_address_tcp_test_() ->
    service_address_(tcp).

service_address_udp_test_() ->
    service_address_(udp).

service_address_(Protocol) ->
    S = [{address_family, 2},
         {protocol, proto_num(Protocol)},
         {address, <<11, 197, 245, 133, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0>>},
         {port, 9042},
         {sched_name, "wlc"},
         {flags, 2, 4294967295},
         {timeout, 0},
         {netmask, 4294967295},
         {stats, [{conns, 0},
                 {inpkts, 0},
                 {outpkts, 0},
                 {inbytes, 0},
                 {outbytes, 0},
                 {cps, 0},
                 {inpps, 0},
                 {outpps, 0},
                 {inbps, 0},
                 {outbps, 0}]}],
    SAddr = {Protocol, {11, 197, 245, 133}, 9042},
    [?_assertEqual(SAddr, service_address(S))].

proto_num(tcp) -> 6;
proto_num(udp) -> 17.
-endif.
