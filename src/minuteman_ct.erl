%%%-------------------------------------------------------------------
%%% @author sdhillon
%%% @copyright (C) 2015, <COMPANY>
%%% @doc
%%%
%%% @end
%%% Created : 09. Dec 2015 1:41 AM
%%%-------------------------------------------------------------------
-module(minuteman_ct).
-author("sdhillon").

-behaviour(gen_server).

%% API
-export([start_link/1, handle_mapping/2]).

%% gen_server callbacks
-export([init/1,
  handle_call/3,
  handle_cast/2,
  handle_info/2,
  terminate/2,
  code_change/3]).

% This is the error code for a duplicate conntrack on 64-bit Linux
% But it can also represent other errors
% Like, conntrack not compiled

-define(MAYBE_DUPLICATE_CONNTRACK, 2717908991).
-record(state, {socket}).

-include_lib("gen_socket/include/gen_socket.hrl").
-include_lib("gen_netlink/include/netlink.hrl").
-include("enfhackery.hrl").
%% These are the default max values from the kernel
-define(SNDBUF_DEFAULT, 212992).
-define(RCVBUF_DEFAULT, 212992).

% The default size buffer we allocate to receive something from the kernel.
-define(RECV_SIZE, 8192).

%%%===================================================================
%%% API
%%%===================================================================

handle_mapping(Num, Mapping) ->
  gen_server:call(?SERVER_NAME_WITH_NUM(Num), {handle_mapping, Mapping}).
%%--------------------------------------------------------------------
%% @doc
%% Starts the server
%%
%% @end
%%--------------------------------------------------------------------
-spec(start_link(Num :: non_neg_integer()) ->
  {ok, Pid :: pid()} | ignore | {error, Reason :: term()}).
start_link(Num) ->
  gen_server:start_link({local, ?SERVER_NAME_WITH_NUM(Num)}, ?MODULE, [], []).

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
  {ok, Socket} = socket(netlink, raw, ?NETLINK_NETFILTER, []),
  ok = gen_socket:setsockopt(Socket, ?SOL_SOCKET, ?SO_RCVBUF, ?RCVBUF_DEFAULT),
  ok = gen_socket:setsockopt(Socket, ?SOL_SOCKET, ?SO_SNDBUF, ?SNDBUF_DEFAULT),
  netlink:rcvbufsiz(Socket, ?RCVBUF_DEFAULT),
  %% Our fates are linked.
  {gen_socket, RealPort, _, _, _, _} = Socket,
  erlang:link(RealPort),
  ok = gen_socket:bind(Socket, netlink:sockaddr_nl(netlink, 0, 0)),
  {ok, #state{socket = Socket}}.

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
handle_call({handle_mapping, Mapping}, _From, State = #state{socket = Socket}) ->
  try_mapping(Mapping, Socket),
  {reply, ok, State};
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
handle_info({Socket, input_ready}, State = #state{socket = Socket}) ->
  case gen_socket:recv(Socket, ?RECV_SIZE) of
    {ok, Data} ->
      Msg = netlink:nl_ct_dec(Data),
      case Msg of
        [{netlink, error, [], _, _, {ErrNo, _}}|_] when ErrNo == 0 ->
          ok;
        [{netlink, error, [], _, _, {ErrNo, SubData}}|_] ->
          SubMsg = netlink:nl_ct_dec(SubData),
          lager:warning("Errno (~p): ~p~n", [ErrNo, SubMsg])
      end;
    Other ->
      lager:warning("Unknown msg (ct): ~p~n", [Other])
  end,
  ok = gen_socket:input_event(Socket, true),
  {noreply, State};

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
terminate(_Reason, _State = #state{socket = Socket}) ->
  gen_socket:close(Socket),
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



nfnl_query(Socket, Query) ->
  Request = netlink:nl_ct_enc(Query),
  gen_socket:sendto(Socket, netlink:sockaddr_nl(netlink, 0, 0), Request),
  Answer = gen_socket:recv(Socket, 8192),
  case Answer of
    {ok, Reply} ->
      lager:debug("Reply: ~p~n", [netlink:nl_ct_dec(Reply)]),
      case netlink:nl_ct_dec(Reply) of
        [{netlink, error, [], _, _, {ErrNo, _}}|_] when ErrNo == 0 ->
          ok;
        [{netlink, error, [], _, _, {ErrNo, SubData}}|_] ->
          SubMsg = netlink:nl_ct_dec(SubData),
          lager:warning("Errno2 (~p): ~p~n", [ErrNo, SubMsg]),
          {error, ErrNo};
        [Msg|_] ->
          {error, Msg};
        Other ->
          Other
      end;
    Other ->
      Other
  end.


socket(Family, Type, Protocol, Opts) ->
  case proplists:get_value(netns, Opts) of
    undefined ->
      gen_socket:socket(Family, Type, Protocol);
    NetNs ->
      gen_socket:socketat(NetNs, Family, Type, Protocol)
  end.

-spec(try_mapping(#mapping{}, gen_socket:socket()) -> ok | {error, Reason :: term()}).
try_mapping(Mapping, Socket) ->
  Msg = build_ctnetlink_msg_create(Mapping),
  Status = nfnl_query(Socket, Msg),
  case Status of
    ok ->
      ok;
    {error, ?MAYBE_DUPLICATE_CONNTRACK} ->
      retry_mapping(Mapping, Socket);
    {error, Error} ->
      lager:warning("Mapping Status Error: ~p", [Error]),
      {error, Error};
    _ ->
      lager:debug("Mapping Status: ~p", [Status]),
      {error, unknown}
  end.

-spec(retry_mapping(#mapping{}, gen_socket:socket()) -> ok | {error, Reason :: term()}).
retry_mapping(Mapping, Socket) ->
  % Try deleting the "old" mapping - we don't really care
  % if it suceeds or not
  MsgDelete = build_ctnetlink_msg_delete(Mapping),
  _DeleteStatus = nfnl_query(Socket, MsgDelete),
  % Go back into creating the mapping
  MsgCreate = build_ctnetlink_msg_create(Mapping),
  CreateStatus = nfnl_query(Socket, MsgCreate),
  case CreateStatus of
    ok ->
      ok;
    {error, Error} ->
      lager:warning("Retried Mapping Status Error: ~p", [Error]),
      {error, Error};
    _ ->
      lager:debug("Retried Mapping Status: ~p", [CreateStatus]),
      {error, unknown}
  end.

-spec(build_ctnetlink_msg_delete(#mapping{}) -> [#ctnetlink{}]).
build_ctnetlink_msg_delete(Mapping) ->
  Seq = erlang:time_offset() + erlang:monotonic_time(),
  TupleOrig = tuple_orig(Mapping),
  TupleReply = tuple_reply(Mapping),
  Cmd = {inet, 0, 0, [
    TupleOrig,
    TupleReply,
    {protoinfo, [{tcp, []}]}
  ]},
  Msg = [#ctnetlink{type = delete, flags = [request, ack], seq = Seq, pid = 0, msg = Cmd}],
  Msg.

-spec(build_ctnetlink_msg_create(#mapping{}) -> [#ctnetlink{}]).
build_ctnetlink_msg_create(Mapping) ->
  Seq = erlang:time_offset() + erlang:monotonic_time(),
  TupleOrig = tuple_orig(Mapping),
  TupleReply = tuple_reply(Mapping),
  Cmd = {inet, 0, 0, [
    TupleOrig,
    TupleReply,
    {timeout, 2},
    {protoinfo, [{tcp, [{state, syn_sent}]}]},
    {nat_src,
      [{v4_src, Mapping#mapping.new_src_ip},
        {src_port, [{min_port, Mapping#mapping.new_src_port}, {max_port, Mapping#mapping.new_src_port}]}]},
    {nat_dst,
      [{v4_dst, Mapping#mapping.new_dst_ip},
        {dst_port, [{min_port, Mapping#mapping.new_dst_port}, {max_port, Mapping#mapping.new_dst_port}]}]}
  ]},
  Msg = [#ctnetlink{type = new, flags = [create, request, ack], seq = Seq, pid = 0, msg = Cmd}],
  Msg.

tuple_orig(Mapping) ->
  {tuple_orig,
    [{ip, [{v4_src, Mapping#mapping.orig_src_ip}, {v4_dst, Mapping#mapping.orig_dst_ip}]},
      {proto, [{num, tcp}, {src_port, Mapping#mapping.orig_src_port}, {dst_port, Mapping#mapping.orig_dst_port}]}]}.
tuple_reply(Mapping) ->
  {tuple_reply,
    [{ip, [{v4_src, Mapping#mapping.orig_dst_ip}, {v4_dst, Mapping#mapping.orig_src_ip}]},
      {proto, [{num, tcp}, {src_port, Mapping#mapping.orig_dst_port}, {dst_port, Mapping#mapping.orig_src_port}]}]}.
