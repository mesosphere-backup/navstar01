%%%-------------------------------------------------------------------
%%% @author sdhillon
%%% @copyright (C) 2016, <COMPANY>
%%% @doc
%%%
%%% @end
%%% Created : 27. May 2016 9:27 PM
%%%-------------------------------------------------------------------
-module(navstar_overlay_configure).
-author("sdhillon").
-author("dgoel").

%% API
-export([start_link/1, stop/1, maybe_configure/2]).

-include_lib("mesos_state/include/mesos_state_overlay_pb.hrl").

-type config() :: #{key := term(), value := term()}.

-spec(start_link(config()) -> pid()).
start_link(Config) ->
   MyPid = self(),
   spawn_link(?MODULE, maybe_configure, [Config, MyPid]).

stop(Pid) ->
    unlink(Pid),
    exit(Pid, kill).

reply(Pid, Msg) ->
    Pid ! Msg.

-spec(maybe_configure(config(), pid()) -> term()).
maybe_configure(Config, MyPid) ->
    lager:debug("Started applying config ~p~n", [Config]),
    KnownOverlays = navstar_overlay_poller:overlays(),
    {ok, Netlink} = navstar_overlay_netlink:start_link(),
    lists:map(
        fun(Overlay) -> try_configure_overlay(Netlink, Config, Overlay) end,
        KnownOverlays
    ),
    navstar_overlay_netlink:stop(Netlink),
    lager:debug("Done applying config ~p for overlays ~p~n", [Config, KnownOverlays]),
    reply(MyPid, {navstar_overlay_configure, applied_config, Config}).

-spec(try_configure_overlay(Pid :: pid(), config(), #mesos_state_agentoverlayinfo{}) -> term()).
try_configure_overlay(Pid, Config, Overlay) ->
    #mesos_state_agentoverlayinfo{
        info = #mesos_state_overlayinfo{
            subnet = Subnet, 
            subnet6 = Subnet6
        }
    } = Overlay,
    try_configure_overlay(Pid, Config, Overlay, Subnet),
    try_configure_overlay(Pid, Config, Overlay, Subnet6).

try_configure_overlay(_Pid, _Config, _Overlay, undefined) ->
    ok;
try_configure_overlay(Pid, Config, Overlay, Subnet) ->
    ParsedSubnet = parse_subnet(Subnet),
    try_configure_overlay2(Pid, Config, Overlay, ParsedSubnet).

-type prefix_len() :: 0..32.
-spec(parse_subnet(Subnet :: binary()) -> {inet:ipv4_address(), prefix_len()}).
parse_subnet(Subnet) ->
    [IPBin, PrefixLenBin] = binary:split(Subnet, <<"/">>),
    {ok, IP} = inet:parse_address(binary_to_list(IPBin)),
    PrefixLen = erlang:binary_to_integer(PrefixLenBin),
    true = is_integer(PrefixLen),
    true = 0 =< PrefixLen andalso PrefixLen =< 128,
    {IP, PrefixLen}.

try_configure_overlay2(Pid, 
  _Config = #{key := [navstar, overlay, Subnet], value := LashupValue},
  Overlay, ParsedSubnet) when Subnet == ParsedSubnet ->
    lists:map(
        fun(Value) -> maybe_configure_overlay_entry(Pid, Overlay, Value) end,
        LashupValue
    );
try_configure_overlay2(_Pid, _Config, _Overlay, _ParsedSubnet) ->
    ok.

maybe_configure_overlay_entry(Pid, Overlay, {{VTEPIPPrefix, riak_dt_map}, Value}) ->
    MyIP = navstar_overlay_poller:ip(),
    case lists:keyfind({agent_ip, riak_dt_lwwreg}, 1, Value) of
        {_, MyIP} ->
            ok;
        _Any ->
            configure_overlay_entry(Pid, Overlay, VTEPIPPrefix, Value)
    end.

configure_overlay_entry(Pid, Overlay, _VTEPIPPrefix = {VTEPIP, _PrefixLen}, LashupValue) ->
    #mesos_state_agentoverlayinfo{
        backend = #mesos_state_backendinfo{
            vxlan = #mesos_state_vxlaninfo{
                vtep_name = VTEPName
            }
        }
    } = Overlay,
    {_, MAC} = lists:keyfind({mac, riak_dt_lwwreg}, 1, LashupValue),
    {_, AgentIP} = lists:keyfind({agent_ip, riak_dt_lwwreg}, 1, LashupValue),
    {_, {SubnetIP, SubnetPrefixLen}} = lists:keyfind({subnet, riak_dt_lwwreg}, 1, LashupValue),

    %% TEST only : writes the parameters to a file
    maybe_print_parameters([AgentIP, binary_to_list(VTEPName),
                            VTEPIP, MAC, SubnetIP, SubnetPrefixLen]),

    VTEPNameStr = binary_to_list(VTEPName),
    MACTuple = list_to_tuple(MAC),
    Family = determine_family(inet:ntoa(SubnetIP)),
    {ok, _} = navstar_overlay_netlink:ipneigh_replace(Pid, Family, VTEPIP, MACTuple, VTEPNameStr),
    {ok, _} = navstar_overlay_netlink:iproute_replace(Pid, Family, SubnetIP, SubnetPrefixLen, VTEPIP, main),
    case Family of
      inet ->
        {ok, _} = navstar_overlay_netlink:bridge_fdb_replace(Pid, AgentIP, MACTuple, VTEPNameStr),
        {ok, _} = navstar_overlay_netlink:iproute_replace(Pid, Family, AgentIP, 32, VTEPIP, 42);
      _  ->
         ok
    end.

determine_family(IP) ->
    case inet:parse_ipv4_address(IP) of
      {ok, _} -> inet;
      _ -> inet6
    end.

-ifdef(TEST).
maybe_print_parameters(Parameters) ->
    {ok, PrivDir} = application:get_env(navstar_overlay, outputdir),
    File = filename:join(PrivDir, node()),
    ok = file:write_file(File, io_lib:fwrite("~p.\n",[Parameters]), [append]).

-else.
maybe_print_parameters(_) ->
    ok.
-endif.
