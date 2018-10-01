%%%-------------------------------------------------------------------
%%% @author sdhillon
%%% @copyright (C) 2016, <COMPANY>
%%% @doc
%%%
%%% @end
%%% Created : 27. May 2016 9:27 PM
%%%-------------------------------------------------------------------
-module(navstar_overlay_poller).
-author("sdhillon").

-behaviour(gen_server).

%% API
-export([start_link/0, ip/0, overlays/0, netlink/0]).

%% gen_server callbacks
-export([init/1,
    handle_call/3,
    handle_cast/2,
    handle_info/2,
    terminate/2,
    code_change/3]).


-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-endif.

-define(SERVER, ?MODULE).
-define(MIN_POLL_PERIOD, 30000). %% 30 secs
-define(MAX_POLL_PERIOD, 120000). %% 120 secs
-define(VXLAN_UDP_PORT, 64000).

-include("navstar_overlay.hrl").
-include_lib("stdlib/include/ms_transform.hrl").
-include_lib("mesos_state/include/mesos_state_overlay_pb.hrl").
-include_lib("gen_netlink/include/netlink.hrl").

-define(TABLE, 42).
-define(MASTERS_KEY, {masters, riak_dt_orswot}).


-record(state, {
    known_overlays = ordsets:new(),
    ip = undefined :: undefined | inet:ip4_address(),
    poll_period = ?MIN_POLL_PERIOD :: integer(),
    netlink :: undefined | pid() 
}).


%%%===================================================================
%%% API
%%%===================================================================

ip() ->
    gen_server:call(?SERVER, ip).

overlays() ->
    gen_server:call(?SERVER, overlays).

netlink() ->
    gen_server:call(?SERVER, netlink).

%%--------------------------------------------------------------------
%% @doc
%% Starts the server
%%
%% @end
%%--------------------------------------------------------------------
-spec(start_link() ->
    {ok, Pid :: pid()} | ignore | {error, Reason :: term()}).
start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

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
    {ok, State :: #state{}} | {ok, State :: #state{}, timeout() | hibernate} |
    {stop, Reason :: term()} | ignore).
init([]) ->
    {ok, Pid} = gen_netlink_client:start_link(?NETLINK_ROUTE),
    timer:send_after(0, poll),
    {ok, #state{netlink = Pid}}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling call messages
%%
%% @end
%%--------------------------------------------------------------------
-spec(handle_call(Request :: term(), From :: {pid(), Tag :: term()},
    State :: #state{}) ->
    {reply, Reply :: term(), NewState :: #state{}} |
    {reply, Reply :: term(), NewState :: #state{}, timeout() | hibernate} |
    {noreply, NewState :: #state{}} |
    {noreply, NewState :: #state{}, timeout() | hibernate} |
    {stop, Reason :: term(), Reply :: term(), NewState :: #state{}} |
    {stop, Reason :: term(), NewState :: #state{}}).
handle_call(ip, _From, State = #state{ip = IP}) ->
    {reply, IP, State};
handle_call(overlays, _From, State = #state{known_overlays = KnownOverlays}) ->
    {reply, KnownOverlays, State};
handle_call(netlink, _From, State = #state{netlink = NETLINK}) ->
    {reply, NETLINK, State};
handle_call(_Request, _From, State) ->
    {reply, ok, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling cast messages
%%
%% @end
%%--------------------------------------------------------------------
-spec(handle_cast(Request :: term(), State :: #state{}) ->
    {noreply, NewState :: #state{}} |
    {noreply, NewState :: #state{}, timeout() | hibernate} |
    {stop, Reason :: term(), NewState :: #state{}}).
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
-spec(handle_info(Info :: timeout() | term(), State :: #state{}) ->
    {noreply, NewState :: #state{}} |
    {noreply, NewState :: #state{}, timeout() | hibernate} |
    {stop, Reason :: term(), NewState :: #state{}}).
handle_info(poll, State0) ->
    State1 =
        case poll(State0) of
            {error, Reason} ->
                lager:warning("Overlay Poller could not poll: ~p~n", [Reason]),
                State0#state{poll_period = ?MIN_POLL_PERIOD};
            {ok, NewState} ->
                NewPollPeriod = update_poll_period(NewState#state.poll_period),
                NewState#state{poll_period = NewPollPeriod}
        end,
    timer:send_after(State1#state.poll_period, poll),
    {noreply, State1};
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
    State :: #state{}) -> term()).
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
-spec(code_change(OldVsn :: term() | {down, term()}, State :: #state{},
    Extra :: term()) ->
    {ok, NewState :: #state{}} | {error, Reason :: term()}).
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%%===================================================================
%%% Internal functions
%%%===================================================================

scheme() ->
    case os:getenv("MESOS_STATE_SSL_ENABLED") of
        "true" ->
            "https";
        _ ->
            "http"
    end.

update_poll_period(OldPollPeriod) when OldPollPeriod*2 =< ?MAX_POLL_PERIOD ->
    OldPollPeriod*2;
update_poll_period(_) ->
    ?MAX_POLL_PERIOD.

poll(State0) ->
    Options = [
        {timeout, application:get_env(?APP, timeout, ?DEFAULT_TIMEOUT)},
        {connect_timeout, application:get_env(?APP, connect_timeout, ?DEFAULT_CONNECT_TIMEOUT)}
    ],
    IP = inet:ntoa(mesos_state:ip()),
    Masters = masters(),
    BaseURI =
        case ordsets:is_element(node(), Masters) of
            true ->
                scheme() ++ "://~s:5050/overlay-agent/overlay";
            false ->
                scheme() ++ "://~s:5051/overlay-agent/overlay"
        end,

    URI = lists:flatten(io_lib:format(BaseURI, [IP])),
    Headers = [{"Accept", "application/x-protobuf"}, {"node", atom_to_list(node())}],
    Response = httpc:request(get, {URI, Headers}, Options, [{body_format, binary}]),
    handle_response(State0, Response).

handle_response(_State0, {error, Reason}) ->
    {error, Reason};
handle_response(State0, {ok, {_StatusLine = {_HTTPVersion, 200 = _StatusCode, _ReasonPhrase}, _Headers, Body}}) ->
    parse_response(State0, Body);
handle_response(_State0, {ok, {StatusLine, _Headers, _Body}}) ->
    {error, StatusLine}.

parse_response(State0 = #state{known_overlays = KnownOverlays}, Body) ->
    AgentInfo = #mesos_state_agentinfo{} = mesos_state_overlay_pb:decode_msg(Body, mesos_state_agentinfo),
    #mesos_state_agentinfo{ip = IP0} = AgentInfo,
    IP1 = process_ip(IP0),
    State1 = State0#state{ip = IP1},
    Overlays = ordsets:from_list(AgentInfo#mesos_state_agentinfo.overlays),
    NewOverlays = ordsets:subtract(Overlays, KnownOverlays),
    State2 = lists:foldl(fun add_overlay/2, State1, NewOverlays),
    {ok, State2}.

process_ip(IPBin0) ->
    [IPBin1|_MaybePort] = binary:split(IPBin0, <<":">>),
    IPStr = binary_to_list(IPBin1),
    {ok, IP} = inet:parse_ipv4_address(IPStr),
    IP.

add_overlay(
    Overlay = #mesos_state_agentoverlayinfo{state = #'mesos_state_agentoverlayinfo.state'{status = 'STATUS_OK'}},
    State0 = #state{known_overlays = KnownOverlays0}) ->
    KnownOverlays1 = ordsets:add_element(Overlay, KnownOverlays0),
    State1 = State0#state{known_overlays = KnownOverlays1},
    config_overlay(Overlay, State1),
    maybe_add_overlay_to_lashup(Overlay, State1),
    State1;
add_overlay(Overlay, State) ->
    lager:warning("Overlay not okay: ~p", [Overlay]),
    State.

config_overlay(Overlay, State) ->
    maybe_create_vtep(Overlay, State),
    maybe_add_ip_rule(Overlay, State).

create_vtep_link(VXLan, #state{netlink = Pid}) ->
    #mesos_state_vxlaninfo{
        vni = VNI,
        vtep_mac = VTEPMAC,
        vtep_name = VTEPName
    } = VXLan,
    VTEPNameStr = binary_to_list(VTEPName),
    ParsedVTEPMAC = list_to_tuple(parse_vtep_mac(VTEPMAC)),
    navstar_overlay_netlink:iplink_add(Pid, VTEPNameStr, "vxlan", VNI, ?VXLAN_UDP_PORT),
    {ok, _} = navstar_overlay_netlink:iplink_set(Pid, ParsedVTEPMAC, VTEPNameStr).

maybe_create_vtep_link(VXLan, State=#state{netlink = Pid}) ->
    #mesos_state_vxlaninfo{
        vtep_name = VTEPName
    } = VXLan,
    VTEPNameStr = binary_to_list(VTEPName),
    case check_vtep_link(Pid, VXLan) of
        false ->
            lager:debug("~p will be created.", [VTEPNameStr]),
            create_vtep_link(VXLan, State);
        {true, true} ->
            lager:debug("Attributes of ~p are up-to-date.", [VTEPNameStr]);
        {true, false} ->
            lager:debug("Attributes of ~p are not update-to-date, and vtep will be recreated.", [VTEPNameStr]),
            navstar_overlay_netlink:iplink_delete(Pid, VTEPNameStr),
            create_vtep_link(VXLan, State)
    end,

    create_vtep_addr(VXLan, State).

maybe_create_vtep(_Overlay = #mesos_state_agentoverlayinfo{backend = Backend}, State) ->
    #mesos_state_backendinfo{vxlan = VXLan} = Backend,
    maybe_create_vtep_link(VXLan, State).

create_vtep_addr(VXLan, #state{netlink = Pid}) ->
    #mesos_state_vxlaninfo{
        vtep_ip = VTEPIP,
        vtep_name = VTEPName
    } = VXLan,
    VTEPNameStr = binary_to_list(VTEPName),
    {ParsedVTEPIP, PrefixLen} = parse_subnet(VTEPIP),
    {ok, _} = navstar_overlay_netlink:ipaddr_replace(Pid, ParsedVTEPIP, PrefixLen, VTEPNameStr).

check_vtep_link(Pid, VXLan) ->
    #mesos_state_vxlaninfo{vtep_name = VTEPName} = VXLan,
    VTEPNameStr = binary_to_list(VTEPName),
    case navstar_overlay_netlink:iplink_show(Pid, VTEPNameStr) of
        {ok, [#rtnetlink{type=newlink, msg=Msg}]} ->
            {unspec, arphrd_ether, _, _, _, LinkInfo} = Msg,
            Match = match_vtep_link(VXLan, LinkInfo),
            {true, Match};
        {error, ErrorCode, ResponseMsg} ->
            lager:info("Failed to find ~p for error_code: ~p, msg: ~p", [VTEPNameStr, ErrorCode, ResponseMsg]),
            false
    end.

match_vtep_link(VXLan, Link) ->
    #mesos_state_vxlaninfo{vtep_mac = VTEPMAC, vni = VNI} = VXLan,
    Expected =
        [{address, binary:list_to_bin(parse_vtep_mac(VTEPMAC))},
         {linkinfo, [{kind, "vxlan"}, {data, [{id, VNI}, {port, ?VXLAN_UDP_PORT}]}]}],
    match(Expected, Link).

match(Expected, List) when is_list(Expected) ->
    lists:all(fun (KV) -> match(KV, List) end, Expected);
match({K, V}, List) ->
    case lists:keyfind(K, 1, List) of
        false -> false;
        {K, V} -> true;
        {K, V0} -> match(V, V0)
    end;
match(_Attr, _List) ->
    false.

maybe_add_ip_rule(_Overlay = #mesos_state_agentoverlayinfo{info = #mesos_state_overlayinfo{subnet = Subnet}},
 #state{netlink = Pid}) ->
    {ParsedSubnetIP, PrefixLen} = parse_subnet(Subnet),
    {ok, Rules} = navstar_overlay_netlink:iprule_show(Pid),
    Rule = navstar_overlay_netlink:make_iprule(ParsedSubnetIP, PrefixLen, ?TABLE),
    case navstar_overlay_netlink:is_iprule_present(Rules, Rule) of
        false ->
            {ok, _} = navstar_overlay_netlink:iprule_add(Pid, ParsedSubnetIP, PrefixLen, ?TABLE);
        _ ->
            ok
    end.

%% Always return an ordered set of masters
-spec(masters() -> [node()]).
masters() ->
    Masters = lashup_kv:value([masters]),
    case orddict:find(?MASTERS_KEY, Masters) of
        error ->
            [];
        {ok, Value} ->
            ordsets:from_list(Value)
    end.

maybe_add_overlay_to_lashup(Overlay = #mesos_state_agentoverlayinfo{info = #mesos_state_overlayinfo{subnet = Subnet}},
    State) ->
    ParsedSubnet = parse_subnet(Subnet),
    Key = [navstar, overlay, ParsedSubnet],
    LashupValue = lashup_kv:value(Key),
    Now = erlang:system_time(nano_seconds),
    case check_subnet(Overlay, State, LashupValue, Now) of
        ok ->
            ok;
        Updates ->
            lager:info("Overlay poller updating lashup"),
            {ok, _} = lashup_kv:request_op(Key, {update, [Updates]})
    end.

-type prefix_len() :: 0..32.
-spec(parse_subnet(Subnet :: binary()) -> {inet:ipv4_address(), prefix_len()}).
parse_subnet(Subnet) ->
    [IPBin, PrefixLenBin] = binary:split(Subnet, <<"/">>),
    {ok, IP} = inet:parse_ipv4_address(binary_to_list(IPBin)),
    PrefixLen = erlang:binary_to_integer(PrefixLenBin),
    true = is_integer(PrefixLen),
    true = 0 =< PrefixLen andalso PrefixLen =< 32,
    {IP, PrefixLen}.

check_subnet(
    #mesos_state_agentoverlayinfo{backend = Backend, subnet = LocalSubnet},
    _State = #state{ip = AgentIP}, LashupValue, Now) ->

    #mesos_state_backendinfo{vxlan = VXLan} = Backend,
    #mesos_state_vxlaninfo{
        vtep_ip = VTEPIPStr,
        vtep_mac = VTEPMac
    } = VXLan,
    ParsedLocalSubnet = parse_subnet(LocalSubnet),
    ParsedVTEPMac = parse_vtep_mac(VTEPMac),

    ParsedVTEPIP = parse_subnet(VTEPIPStr),
    case lists:keyfind({ParsedVTEPIP, riak_dt_map}, 1, LashupValue) of
        {{ParsedVTEPIP, riak_dt_map}, _Value} ->
            ok;
        false ->
            {update,
                {ParsedVTEPIP, riak_dt_map},
                {update, [
                    {update, {mac, riak_dt_lwwreg}, {assign, ParsedVTEPMac, Now}},
                    {update, {agent_ip, riak_dt_lwwreg}, {assign, AgentIP, Now}},
                    {update, {subnet, riak_dt_lwwreg}, {assign, ParsedLocalSubnet, Now}}
                    ]
                }
            }
    end.

parse_vtep_mac(MAC) ->
    MACComponents = binary:split(MAC, <<":">>, [global]),
    lists:map(
        fun(Component) ->
            binary_to_integer(Component, 16)
        end,
        MACComponents).

-ifdef(TEST).

deserialize_overlay_test() ->
    DataDir = code:priv_dir(navstar_overlay),
    OverlayFilename = filename:join(DataDir, "overlay.bindata.pb"),
    {ok, OverlayData} = file:read_file(OverlayFilename),
    Msg = mesos_state_overlay_pb:decode_msg(OverlayData, mesos_state_agentinfo),
    ?assertEqual(<<"10.0.0.160:5051">>, Msg#mesos_state_agentinfo.ip).

match_vtep_link_test() ->
    VNI = 1024,
    VTEPIP = <<"44.128.0.1/20">>,
    VTEPMAC = <<"70:b3:d5:80:00:01">>,
    VTEPMAC2 = <<"70:b3:d5:80:00:02">>,
    VTEPNAME = <<"vtep1024">>,
    {ok, [RtnetLinkInfo]} = file:consult("apps/navstar_overlay/testdata/vtep_link.data"),
    [#rtnetlink{type=newlink, msg=Msg}] = RtnetLinkInfo,
    {unspec, arphrd_ether, _, _, _, LinkInfo} = Msg,
    VXLan = #mesos_state_vxlaninfo{
        vni = VNI,
        vtep_ip = VTEPIP,
        vtep_mac = VTEPMAC,
        vtep_name = VTEPNAME
    },
    ?assertEqual(true, match_vtep_link(VXLan, LinkInfo)),

    VXLan2 = VXLan#mesos_state_vxlaninfo{vtep_mac=VTEPMAC2},
    ?assertEqual(false, match_vtep_link(VXLan2, LinkInfo)).

-endif.
