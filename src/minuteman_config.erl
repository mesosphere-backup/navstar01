%%%-------------------------------------------------------------------
%%% @author sdhillon, Tyler Neely
%%% @copyright (C) 2015, Mesosphere
%%% @doc
%%%
%%% @end
%%% Created : 08. Dec 2015 8:58 PM
%%%-------------------------------------------------------------------
-module(minuteman_config).
-author("sdhillon").
-author("Tyler Neely").

%% API
-export([
  agent_poll_interval/0,
  networking/0,
  agent_polling_enabled/0,
  agent_port/0,
  agent_dets_path/1,
  min_named_ip/0,
  max_named_ip/0,
  minuteman_iface/0,
  metrics_interval_seconds/0,
  metrics_splay_seconds/0
  ]).

metrics_interval_seconds() ->
  application:get_env(minuteman, metrics_interval_seconds, 20).

metrics_splay_seconds() ->
  application:get_env(minuteman, metrics_interval_seconds, 2).

minuteman_iface() ->
  application:get_env(minuteman, iface, "minuteman").

agent_poll_interval() ->
  application:get_env(minuteman, agent_poll_interval, 2000).

networking() ->
  application:get_env(minuteman, enable_networking, true).

agent_polling_enabled() ->
  application:get_env(minuteman, agent_polling_enabled, true).

agent_port() ->
  application:get_env(minuteman, agent_port, 5051).

agent_dets_basedir() ->
  application:get_env(minuteman, agent_dets_basedir, "/var/lib/dcos/navstar/minuteman/dets").

agent_dets_path(DetsName) ->
  filename:join([agent_dets_basedir(), DetsName]).

-spec(min_named_ip() -> inet:ip4_address()).
min_named_ip() ->
  application:get_env(minuteman, min_named_ip, {11, 0, 0, 0}).

-spec(max_named_ip() -> inet:ip4_address()).
-ifndef(TEST).
max_named_ip() ->
  application:get_env(minuteman, max_named_ip, {11, 255, 255, 254}).
-else.
max_named_ip() ->
  application:get_env(minuteman, max_named_ip, {11, 0, 0, 254}).
-endif.
