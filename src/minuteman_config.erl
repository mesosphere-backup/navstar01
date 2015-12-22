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
-export([master_uri/0,
  poll_interval/0,
  queue/0,
  networking/0,
  tcp_connect_threshold/0,
  tcp_consecutive_failure_threshold/0,
  tcp_failed_backend_backoff_period/0
  ]).


master_uri() ->
  application:get_env(minuteman, master_uri, "http://localhost:5050/state.json").


poll_interval() ->
  application:get_env(minuteman, poll_interval, 5000).


tcp_connect_threshold() ->
  application:get_env(minuteman, tcp_connect_threshold, 2000).

tcp_consecutive_failure_threshold() ->
  application:get_env(minuteman, tcp_consecutive_failure_threshold, 5).

tcp_failed_backend_backoff_period() ->
  application:get_env(minuteman, tcp_failed_backend_backoff_period, 30000).


%% Returns a integer
queue() ->
  case application:get_env(minuteman, queue, {50, 58}) of
    X when is_integer(X) ->
      {X, X};
    Y ->
      Y
  end.

networking() ->
  application:get_env(minuteman, enable_networking, true).
