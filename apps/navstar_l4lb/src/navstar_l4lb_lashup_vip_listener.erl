%%%-------------------------------------------------------------------
%%% @author sdhillon
%%% @copyright (C) 2016, <COMPANY>
%%% @doc
%%%
%%% @end
%%% Created : 17. May 2016 5:06 PM
%%%-------------------------------------------------------------------
-module(navstar_l4lb_lashup_vip_listener).
-author("sdhillon").

-behaviour(gen_server).

%% API
-export([start_link/0]).
-export([integer_to_ip/1]).

%% gen_server callbacks
-export([init/1,
    handle_call/3,
    handle_cast/2,
    handle_info/2,
    terminate/2,
    lookup_vips/1,
    code_change/3]).

-ifdef(TEST).
-export([setup_monitor/0]).
-endif.

-include_lib("telemetry/include/telemetry.hrl").

-define(SERVER, ?MODULE).
-define(RPC_TIMEOUT, 5000).
-define(MON_CALLBACK_TIME, 5000).
-define(RPC_RETRY_TIME, 15000).

-include_lib("stdlib/include/ms_transform.hrl").
-include("navstar_l4lb.hrl").
-include_lib("mesos_state/include/mesos_state.hrl").
-include_lib("dns/include/dns.hrl").


-ifdef(TEST).
-include_lib("proper/include/proper.hrl").
-include_lib("eunit/include/eunit.hrl").
-endif.


-type family() :: inet | inet6.
-type ip4_num() :: 0..16#ffffffff.
-type ip6_num() :: 0..16#ffff.
-type ip6() :: {ip6_num(), ip6_num(), ip6_num(), ip6_num(), 
                ip6_num(), ip6_num(), ip6_num(), ip6_num()}. 
-record(state, {
    ref = erlang:error() :: reference(),
    min_ip_num = erlang:error(no_min_ip_num) :: ip4_num(),
    max_ip_num = erlang:error(no_max_ip_num) :: ip4_num(),
    last_ip6 = undefined :: ip6(),
    retry_timer :: undefined | reference(),
    monitorRef :: reference(),
    vips
    }).
-type state() :: #state{}.

-type ip_vip() :: {tcp | udp, inet:ip_address(), inet:port_number()}.
-type vip_name() :: binary().
-type named_vip() :: {tcp | udp, {name, {vip_name(), framework_name()}}, inet:port_number()}.
-type vip2() :: {ip_vip() | named_vip(), [{inet:ip_address(), ip_port()}]}.

%%%===================================================================
%%% API
%%%===================================================================

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
    {ok, State :: state()} | {ok, State :: state(), timeout() | hibernate} |
    {stop, Reason :: term()} | ignore).
init([]) ->
    ets_restart(name_to_ip),
    ets_restart(name_to_ip6),
    ets_restart(ip_to_name),
    MinIP = ip_to_integer(navstar_l4lb_config:min_named_ip()),
    MaxIP = ip_to_integer(navstar_l4lb_config:max_named_ip()),
    LastIP6 = navstar_l4lb_config:min_named_ip6(), 
    MonitorRef = setup_monitor(),
    {ok, Ref} = lashup_kv_events_helper:start_link(ets:fun2ms(fun({?VIPS_KEY2}) -> true end)),
    State = #state{ref = Ref, max_ip_num = MaxIP, min_ip_num = MinIP,
                   last_ip6 = LastIP6, monitorRef = MonitorRef},
    {ok, State}.

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
handle_call(_Request, _From, State) ->
    {reply, ok, State}.

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
handle_cast(push_vips, State) ->
    {noreply, State};
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
handle_info({lashup_kv_events, Event = #{ref := Reference}}, State0 = #state{ref = Reference}) ->
    State1 = handle_event(Event, State0),
    {noreply, State1};
handle_info({'DOWN', MonitorRef, process, _, _}, State = #state{monitorRef = MonitorRef}) ->
   lager:debug("Spartan monitor went off, maybe it got restarted"),
   erlang:send_after(?MON_CALLBACK_TIME, self(), retry_monitor),
   {noreply, State};
handle_info(retry_monitor, State = #state{retry_timer = Timer}) ->
   lager:debug("Setting retry due to monitor went off"),
   cancel_retry_timer(Timer),
   MonitorRef = setup_monitor(),
   NewTimer = erlang:send_after(?RPC_RETRY_TIME, self(), retry_spartan),
   {noreply, State#state{monitorRef = MonitorRef, retry_timer = NewTimer}};
handle_info(retry_spartan, State0) ->
    lager:debug("Retrying to push the DNS config"),
    State1 = retry_spartan(State0),
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
-spec(lookup_vips([{ip, inet:ip_address()}|{name, binary()}]) ->
                  [{name, binary()}|{ip, inet:ip_address()}|{badmatch, term()}]).
lookup_vips(Names) ->
    try
        lists:map(fun handle_lookup_vip/1, Names)
    catch
        error:badarg -> []
    end.

handle_lookup_vip({ip, IP}) ->
  case ets:lookup(ip_to_name, IP) of
    [{_, IPName}] -> {name, IPName};
    _ -> {badmatch, IP}
  end;
handle_lookup_vip({name, Name}) when is_binary(Name) ->
  case ets:lookup(name_to_ip, Name) of
    [{_, IP}] -> {ip, IP};
    _ -> {badmatch, Name}
  end;
handle_lookup_vip(Arg)  -> {badmatch, Arg}.

handle_event(_Event = #{value := VIPs}, State) ->
    handle_value(VIPs, State).

handle_value(VIPs0, State0 = #state{retry_timer = Timer}) ->
    cancel_retry_timer(Timer),
    VIPs1 = process_vips(VIPs0, State0),
    State1 = State0#state{vips = VIPs1},
    State2 = push_state_to_spartan(State1),
    navstar_l4lb_mgr:push_vips(VIPs1),
    State2.

cancel_retry_timer(Timer) when is_reference(Timer) ->
    erlang:cancel_timer(Timer);
cancel_retry_timer(_) ->
    ok.

process_vips(VIPs0, State) ->
    VIPs1 = lists:map(fun rewrite_keys/1, VIPs0),
    CategorizedVIPs = categories_vips(VIPs1),
    RebindVIPs = [rebind_names(Family, VIPs, State) 
                     || {Family, VIPs} <- CategorizedVIPs],
    lists:flatten(RebindVIPs).

rewrite_keys({{RealKey, riak_dt_orswot}, Value}) ->
    {RealKey, Value}.

categories_vips(VIPs) ->
    categories_vips(VIPs, [], []).

categories_vips([], V4_VIPs, V6_VIPs) ->
    [{inet, lists:reverse(V4_VIPs)}, {inet6, lists:reverse(V6_VIPs)}];
categories_vips([VIP|Rest], V4_VIPs, V6_VIPs) ->
    case categories_BE(VIP) of
        [inet] -> categories_vips(Rest, [VIP|V4_VIPs], V6_VIPs);
        [inet6] -> categories_vips(Rest, V4_VIPs, [VIP|V6_VIPs]);
        [inet, inet6] -> categories_vips(Rest, [VIP|V4_VIPs], [VIP|V6_VIPs])
    end.

categories_BE({{_Protocol, _Name, _PortNumber}, BEs}) ->
    Families = [navstar_l4lb_app:family(BEIP) || {_IP, {BEIP, _Port}} <- BEs],
    lists:usort(Families).

%% @doc Extracts name based vips. Binds names
-spec(rebind_names(family(), [vip2()], state()) -> [ip_vip()]).
rebind_names(_Family, [], _State) ->
    [];
rebind_names(Family, VIPs, State) ->
    Names0 = [Name || {{_Protocol, {name, Name}, _Portnumber}, _Backends} <- VIPs],
    Names1 = lists:map(fun({Name, FWName}) -> binary_to_name([Name, FWName]) end, Names0),
    Names2 = lists:usort(Names1),
    update_name_mapping(Family, Names2, State),
    lists:map(fun(VIP) -> rewrite_name(Family, VIP) end, VIPs).

-spec(rewrite_name(family(), vip2()) -> ip_vip()).
rewrite_name(Family, {{Protocol, {name, {Name, FWName}}, PortNum}, BEs}) ->
    Table = family_to_table(Family),
    FullName = binary_to_name([Name, FWName]),
    [{_, IP}] = ets:lookup(Table, FullName),
    {{Protocol, IP, PortNum}, BEs};
rewrite_name(_, Else) ->
    Else.

setup_monitor() ->
    monitor(process, {erldns_zone_cache, spartan_name()}).

retry_spartan(State) ->
    push_state_to_spartan(State).

push_state_to_spartan(State) ->
    ZoneNames = ?ZONE_NAMES,
    Zones = lists:map(fun(ZoneName) -> zone(ZoneName, State) end, ZoneNames),
    case push_zones(Zones) of
        ok ->
            State;
        error ->
            Timer = erlang:send_after(?RPC_RETRY_TIME, self(), retry_spartan),
            State#state{retry_timer = Timer}
    end.

push_zones([]) ->
    ok;
push_zones([Zone|Zones]) ->
    case push_zone(Zone) of
        ok ->
            push_zones(Zones);
        {error, Reason} ->
            lager:warning("Aborting pushing zones to Spartan: ~p", [Reason]),
            error
    end.

%% TODO(sargun): Based on the response to https://github.com/aetrion/erl-dns/issues/46 -- we might have to handle
%% returns from rpc which are errors
push_zone(Zone) ->
    case rpc:call(spartan_name(), erldns_zone_cache, put_zone, [Zone], ?RPC_TIMEOUT) of
        Reason = {badrpc, _} ->
            {error, Reason};
        ok ->
            ok
    end.

spartan_name() ->
    [_Node, Host] = binary:split(atom_to_binary(node(), utf8), <<"@">>),
    SpartanBinName = <<"spartan@", Host/binary>>,
    binary_to_atom(SpartanBinName, utf8).

-spec(zone([binary()], state()) -> {Name :: binary(), Sha :: binary(), [#dns_rr{}]}).
zone(ZoneComponents, State) ->
    Now = timeish(),
    zone(Now, ZoneComponents, State).

-spec(timeish() -> 0..4294967295).
timeish() ->
    case erlang:system_time(seconds) of
        Time when Time < 0 ->
            0;
        Time when Time > 4294967295 ->
            4294967295;
        Time ->
            Time + erlang:unique_integer([positive, monotonic])
    end.

-spec(zone(Now :: 0..4294967295, [binary()], state()) -> {Name :: binary(), Sha :: binary(), [#dns_rr{}]}).
zone(Now, ZoneComponents, _State) ->
    ZoneName = binary_to_name(ZoneComponents),
    Records0 = [
        #dns_rr{
            name = ZoneName,
            type = ?DNS_TYPE_SOA,
            ttl = 5,
            data = #dns_rrdata_soa{
                mname = binary_to_name([<<"ns">>|ZoneComponents]), %% Nameserver
                rname = <<"support.mesosphere.com">>,
                serial = Now, %% Hopefully there is not more than 1 update/sec :)
                refresh = 5,
                retry = 5,
                expire = 5,
                minimum = 1
            }
        },
        #dns_rr{
            name = binary_to_name(ZoneComponents),
            type = ?DNS_TYPE_NS,
            ttl = 3600,
            data = #dns_rrdata_ns{
                dname = binary_to_name([<<"ns">>|ZoneComponents])
            }
        },
        #dns_rr{
            name = binary_to_name([<<"ns">>|ZoneComponents]),
            type = ?DNS_TYPE_A,
            ttl = 3600,
            data = #dns_rrdata_a{
                ip = {198, 51, 100, 1} %% Default Spartan IP
            }
        }
    ],
    {_, _, Records1} = ets:foldl(fun add_record_fold/2, {inet, ZoneComponents, Records0}, name_to_ip),
    {_, _, Records2} = ets:foldl(fun add_record_fold/2, {inet6, ZoneComponents, Records1}, name_to_ip6),
    Sha = crypto:hash(sha, term_to_binary(Records2)),
    {ZoneName, Sha, Records2}.

add_record_fold({Name, IP}, {Family, ZoneComponents, Records}) ->
    RecordName = binary_to_name([Name] ++ ZoneComponents),
    Record = case Family of
                inet -> #dns_rr{
                          name = RecordName,
                          ttl = 5,
                          type = ?DNS_TYPE_A,
                          data = #dns_rrdata_a{ip = IP}};
                inet6 -> #dns_rr{
                          name = RecordName,
                          ttl = 5,
                          type = ?DNS_TYPE_AAAA,
                          data = #dns_rrdata_aaaa{ip = IP}}
              end,
    {Family, ZoneComponents, [Record|Records]}.

-spec(binary_to_name([binary()]) -> binary()).
binary_to_name(Binaries0) ->
    Binaries1 = lists:map(fun mesos_state:domain_frag/1, Binaries0),
    binary_join(Binaries1, <<".">>).

-spec(binary_join([binary()], Sep :: binary()) -> binary()).
binary_join(Binaries, Sep) ->
    lists:foldr(
        fun
            %% This short-circuits the first run
            (Binary, <<>>) ->
                Binary;
            (<<>>, Acc) ->
                Acc;
            (Binary, Acc) ->
                <<Binary/binary, Sep/binary, Acc/binary>>
        end,
        <<>>,
        Binaries
    ).


-spec(integer_to_ip(IntIP :: 0..4294967295) -> inet:ip4_address()).
integer_to_ip(IntIP) ->
    <<A, B, C, D>> = <<IntIP:32/integer>>,
    {A, B, C, D}.

-spec(ip_to_integer(inet:ip4_address()) -> 0..4294967295).
ip_to_integer(_IP = {A, B, C, D}) ->
    <<IntIP:32/integer>> = <<A, B, C, D>>,
    IntIP.


-spec(update_name_mapping(family(), Names :: term(), State :: state()) -> ok).
update_name_mapping(Family, Names, State) ->
    remove_old_names(Family, Names),
    add_new_names(Family, Names, State),
    ok.

%% This can be rewritten as an enumeration over the ets table, and the names passed to it.
remove_old_names(Family, NewNames) ->
    Table = family_to_table(Family),
    OldNames = lists:sort([Name || {Name, _IP} <- ets:tab2list(Table)]),
    NamesToDelete = ordsets:subtract(OldNames, NewNames),
    lists:foreach(fun(NameToDelete) -> remove_old_name(Table, NameToDelete) end, NamesToDelete).

remove_old_name(Table, NameToDelete) ->
    [{_, IP}] = ets:lookup(Table, NameToDelete),
    ets:delete(ip_to_name, IP),
    ets:delete(Table, NameToDelete).

add_new_names(Family, Names, State) ->
    lists:foreach(fun(Name) -> maybe_add_new_name(Family, Name, State) end, Names).

maybe_add_new_name(Family, Name, State) ->
    Table = family_to_table(Family),
    case ets:lookup(Table, Name) of
        [] ->
            add_new_name(Family, Name, State);
        _ ->
            ok
    end.

add_new_name(inet, Name, State) ->
    add_new_name_ipv4(Name, State);
add_new_name(inet6, Name, State) ->
    add_new_name_ipv6(Name, State).

add_new_name_ipv4(Name, State = #state{min_ip_num = MinIPNum, max_ip_num = MaxIPNum}) ->
    SearchStart = erlang:phash2(Name, MaxIPNum - MinIPNum),
    add_new_name_ipv4(Name, SearchStart + 1, SearchStart, State).

add_new_name_ipv4(_Name, SearchNext, SearchStart, #state{min_ip_num = MinIPNum, max_ip_num = MaxIPNum}) when
    SearchNext rem (MaxIPNum - MinIPNum) == SearchStart ->
    throw(out_of_ips);
add_new_name_ipv4(Name, SearchNext, SearchStart,
        State = #state{min_ip_num = MinIPNum, max_ip_num = MaxIPNum}) ->
    ActualIPNum = MinIPNum + (SearchNext rem (MaxIPNum - MinIPNum)),
    IP = integer_to_ip(ActualIPNum),
    case ets:lookup(ip_to_name, IP) of
        [] ->
            ets:insert(name_to_ip, {Name, IP}),
            ets:insert(ip_to_name, {IP, Name});
        _ ->
            add_new_name_ipv4(Name, SearchNext + 1, SearchStart, State)
    end.

add_new_name_ipv6(Name, State = #state{last_ip6 = LastIP6}) ->
    MinIP6 = navstar_l4lb_config:min_named_ip6(), 
    MaxIP6 = navstar_l4lb_config:max_named_ip6(),
    NextIP6 = next_ip6(LastIP6, MinIP6, MaxIP6),
    case ets:lookup(ip_to_name, NextIP6) of
        [] ->
            ets:insert(name_to_ip6, {Name, NextIP6}),
            ets:insert(ip_to_name, {NextIP6, Name});
        _ ->
            add_new_name_ipv6(Name, State#state{last_ip6 = NextIP6})
    end.

next_ip6(IP6, MinIP6, IP6) ->
    MinIP6;
next_ip6({Num0, 16#ffff, 16#ffff, 16#ffff, 16#ffff, 16#ffff, 16#ffff, 16#ffff}, _, _) ->
    {Num0 + 1, 0, 0, 0, 0, 0, 0, 0};
next_ip6({Num0, Num1, 16#ffff, 16#ffff, 16#ffff, 16#ffff, 16#ffff, 16#ffff}, _, _) ->
    {Num0, Num1 + 1, 0, 0, 0, 0, 0, 0};
next_ip6({Num0, Num1, Num2, 16#ffff, 16#ffff, 16#ffff, 16#ffff, 16#ffff}, _, _) ->
    {Num0, Num1, Num2 + 1, 0, 0, 0, 0, 0};
next_ip6({Num0, Num1, Num2, Num3, 16#ffff, 16#ffff, 16#ffff, 16#ffff}, _, _) ->
    {Num0, Num1, Num2, Num3 + 1, 0, 0, 0, 0};
next_ip6({Num0, Num1, Num2, Num3, Num4, 16#ffff, 16#ffff, 16#ffff}, _, _) ->
    {Num0, Num1, Num2, Num3, Num4 + 1, 0, 0, 0};
next_ip6({Num0, Num1, Num2, Num3, Num4, Num5, 16#ffff, 16#ffff}, _, _) ->
    {Num0, Num1, Num2, Num3, Num4, Num5 + 1, 0, 0};
next_ip6({Num0, Num1, Num2, Num3, Num4, Num5, Num6, 16#ffff}, _, _) ->
    {Num0, Num1, Num2, Num3, Num4, Num5, Num6 + 1, 0};
next_ip6({Num0, Num1, Num2, Num3, Num4, Num5, Num6, Num7}, _, _) ->
    {Num0, Num1, Num2, Num3, Num4, Num5, Num6, Num7 + 1}.

family_to_table(inet) -> name_to_ip;
family_to_table(inet6) -> name_to_ip6.

ets_restart(Tab) ->
    catch ets:delete(Tab),
    catch ets:new(Tab, [named_table, protected, {read_concurrency, true}]).

-ifdef(TEST).
state() ->
    %% 9/8
    ets_restart(name_to_ip),
    ets_restart(name_to_ip6),
    ets_restart(ip_to_name),
    LastIP6 = {16#fd01,16#c,16#0,16#0,16#0,16#0,16#0,16#0},
    #state{ref = undefined, min_ip_num = 16#0b000000, max_ip_num = 16#0b0000fe, last_ip6 = LastIP6}.

process_vips_tcp_test() ->
    process_vips(tcp).

process_vips_udp_test() ->
    process_vips(udp).

process_vips(Protocol) ->
    State = state(),
    VIPs = [
        {
            {{Protocol, {1, 2, 3, 4}, 80}, riak_dt_orswot},
            [{{10, 0, 3, 46}, {{10, 0, 3, 46}, 11778}}]
        },
        {
            {{Protocol, {name, {<<"/foo">>, <<"marathon">>}}, 80}, riak_dt_orswot},
            [{{10, 0, 3, 46}, {{10, 0, 3, 46}, 25458}}]
        },
        {
            {{Protocol, {name, {<<"/foo">>, <<"marathon">>}}, 80}, riak_dt_orswot},
            [{{10, 0, 3, 46}, {{16#fe01,16#c,16#0,16#0,16#0,16#0,16#0,16#1}, 25678}}]
        }
    ],
    Out = process_vips(VIPs, State),
    Expected = [
        {{Protocol, {1, 2, 3, 4}, 80}, [{{10, 0, 3, 46}, {{10, 0, 3, 46}, 11778}}]},
        {{Protocol, {11, 0, 0, 36}, 80}, [{{10, 0, 3, 46}, {{10, 0, 3, 46}, 25458}}]},
        {{Protocol, {16#fd01,16#c,16#0,16#0,16#0,16#0,16#0,16#1}, 80}, 
           [{{10, 0, 3, 46}, {{16#fe01,16#c,16#0,16#0,16#0,16#0,16#0,16#1}, 25678}}]}
    ],
    ?assertEqual(Expected, Out),
    State.

update_name_mapping_test() ->
    State0 = state(),
    update_name_mapping(inet, [test1, test2, test3], State0),
    NTIList = [{N, I} || {I, N} <- ets:tab2list(ip_to_name)],
    SortedList = lists:reverse(lists:usort(NTIList)),
    ?assertEqual(SortedList, ets:tab2list(name_to_ip)),
    ?assertEqual([{{11,0,0,244}, test1}, {{11,0,0,245}, test2}, {{11,0,0,246}, test3}], lists:usort(ets:tab2list(ip_to_name))),
    ?assertEqual([{test3, {11,0,0,246}}, {test2, {11,0,0,245}}, {test1, {11,0,0,244}}], ets:tab2list(name_to_ip)),
    update_name_mapping(inet, [test1, test3], State0),
    ?assertEqual([{{11,0,0,246}, test3}, {{11,0,0,244}, test1}], ets:tab2list(ip_to_name)),
    ?assertEqual([{test3, {11,0,0,246}}, {test1, {11,0,0,244}}], ets:tab2list(name_to_ip)).

update_name_mapping_v6_test() ->
    State0 = state(),
    update_name_mapping(inet6, [test1, test2, test3], State0),
    NTIList = [{N, I} || {I, N} <- ets:tab2list(ip_to_name)],
    SortedList = lists:reverse(lists:usort(NTIList)),
    ?assertEqual(SortedList, ets:tab2list(name_to_ip6)),
    ?assertEqual([{{16#fd01,16#c,16#0,16#0,16#0,16#0,16#0,16#1}, test1}, 
                  {{16#fd01,16#c,16#0,16#0,16#0,16#0,16#0,16#2}, test2}, 
                  {{16#fd01,16#c,16#0,16#0,16#0,16#0,16#0,16#3}, test3}], 
                  lists:usort(ets:tab2list(ip_to_name))),
    ?assertEqual([{test3, {16#fd01,16#c,16#0,16#0,16#0,16#0,16#0,16#3}}, 
                  {test2, {16#fd01,16#c,16#0,16#0,16#0,16#0,16#0,16#2}}, 
                  {test1, {16#fd01,16#c,16#0,16#0,16#0,16#0,16#0,16#1}}], 
                  ets:tab2list(name_to_ip6)),
    update_name_mapping(inet6, [test1, test3], State0),
    ?assertEqual([{{16#fd01,16#c,16#0,16#0,16#0,16#0,16#0,16#1}, test1}, 
                  {{16#fd01,16#c,16#0,16#0,16#0,16#0,16#0,16#3}, test3}], 
                  ets:tab2list(ip_to_name)),
    ?assertEqual([{test3, {16#fd01,16#c,16#0,16#0,16#0,16#0,16#0,16#3}}, 
                  {test1, {16#fd01,16#c,16#0,16#0,16#0,16#0,16#0,16#1}}], 
                  ets:tab2list(name_to_ip6)).


zone_test() ->
    State = process_vips(tcp),
    Components = [<<"l4lb">>, <<"thisdcos">>, <<"directory">>],
    Zone = zone(1463878088, Components, State),
    io:format("Zone ~p", [Zone]),
    Expected =
        {<<"l4lb.thisdcos.directory">>,
           <<158, 253, 241, 209, 102, 111, 218, 254, 243, 141,
             13, 251, 128, 184, 172, 162, 58, 251, 130, 236>>,
           [
             {dns_rr, <<"foo.marathon.l4lb.thisdcos.directory">>, 1, 28, 5,
               {dns_rrdata_aaaa, {64769 , 12, 0, 0, 0, 0, 0, 1}}},
             {dns_rr, <<"foo.marathon.l4lb.thisdcos.directory">>, 1, 1, 5,
               {dns_rrdata_a, {11, 0, 0, 36}}},
             {dns_rr, <<"l4lb.thisdcos.directory">>, 1, 6, 5,
               {dns_rrdata_soa, <<"ns.l4lb.thisdcos.directory">>,
                  <<"support.mesosphere.com">>, 1463878088, 5, 5, 5, 1}},
             {dns_rr, <<"l4lb.thisdcos.directory">>, 1, 2, 3600,
               {dns_rrdata_ns, <<"ns.l4lb.thisdcos.directory">>}},
             {dns_rr, <<"ns.l4lb.thisdcos.directory">>, 1, 1, 3600,
               {dns_rrdata_a, {198, 51, 100, 1}}}
           ]
        },

    ?assertEqual(Expected, Zone).
%%
%%    Expected = {<<"l4lb.thisdcos.directory">>,
%%        <<161, 204, 13, 14, 64, 13, 80, 62, 140, 205, 206, 161, 238, 57, 215,
%%            246, 172, 97, 183, 176>>,
%%        [{dns_rr, <<"foo4.marathon.l4lb.thisdcos.directory">>, 1, 1, 5,
%%            {dns_rrdata_a, {11, 0, 0, 86}}},
%%            {dns_rr, <<"foo3.marathon.l4lb.thisdcos.directory">>, 1, 1, 5,
%%                {dns_rrdata_a, {11, 0, 0, 0}}},
%%            {dns_rr, <<"foo2.marathon.l4lb.thisdcos.directory">>, 1, 1, 5,
%%                {dns_rrdata_a, {11, 0, 0, 108}}},
%%            {dns_rr, <<"foo1.marathon.l4lb.thisdcos.directory">>, 1, 1, 5,
%%                {dns_rrdata_a, {11, 0, 0, 36}}},
%%            {dns_rr, <<"l4lb.thisdcos.directory">>, 1, 6, 5,
%%                {dns_rrdata_soa, <<"ns.l4lb.thisdcos.directory">>,
%%                    <<"support.mesosphere.com">>, 1463878088, 5, 5, 5, 1}},
%%            {dns_rr, <<"l4lb.thisdcos.directory">>, 1, 2, 3600,
%%                {dns_rrdata_ns, <<"ns.l4lb.thisdcos.directory">>}},
%%            {dns_rr, <<"ns.l4lb.thisdcos.directory">>, 1, 1, 3600,
%%                {dns_rrdata_a, {198, 51, 100, 1}}}]},
%%    ?assertEqual(Expected, Zone).
%%
overallocate_test() ->
    State = #state{max_ip_num = Max, min_ip_num = Min} = state(),
    FakeNames = lists:seq(1, Max - Min + 1),
    ?assertThrow(out_of_ips, update_name_mapping(inet, FakeNames, State)).


ip_to_integer_test() ->
    ?assertEqual(4278190080, ip_to_integer({255, 0, 0, 0})),
    ?assertEqual(0, ip_to_integer({0, 0, 0, 0})),
    ?assertEqual(16711680, ip_to_integer({0, 255, 0, 0})),
    ?assertEqual(65535, ip_to_integer({0, 0, 255, 255})),
    ?assertEqual(16909060, ip_to_integer({1, 2, 3, 4})).

integer_to_ip_test() ->
    ?assertEqual({255, 0, 0, 0}, integer_to_ip(4278190080)),
    ?assertEqual({0, 0, 0, 0}, integer_to_ip(0)),
    ?assertEqual({0, 255, 0, 0}, integer_to_ip(16711680)),
    ?assertEqual({0, 0, 255, 255}, integer_to_ip(65535)),
    ?assertEqual({1, 2, 3, 4}, integer_to_ip(16909060)).


all_prop_test_() ->
    {timeout, 60, [fun() -> [] = proper:module(?MODULE, [{to_file, user}, {numtests, 100}]) end]}.


ip() ->
    {byte(), byte(), byte(), byte()}.
int_ip() ->
    integer(0, 4294967295).

valid_int_ip_range(Int) when Int >= 0 andalso Int =< 4294967295 ->
    true;
valid_int_ip_range(_) ->
    false.

prop_integer_to_ip() ->
    ?FORALL(
        IP,
        ip(),
        valid_int_ip_range(ip_to_integer(IP))
    ).

prop_integer_and_back() ->
    ?FORALL(
        IP,
        ip(),
        integer_to_ip(ip_to_integer(IP)) =:= IP
    ).

prop_ip_and_back() ->
    ?FORALL(
        IntIP,
        int_ip(),
        ip_to_integer(integer_to_ip(IntIP)) =:= IntIP
    ).

-endif.
