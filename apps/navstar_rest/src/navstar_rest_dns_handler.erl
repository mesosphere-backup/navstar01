%%%-------------------------------------------------------------------
%%% @author dgoel
%%% @copyright (C) 2016, <COMPANY>
%%% @doc
%%%
%%% @end
%%% Created : 15. Dec 2016 3:25 PM
%%%-------------------------------------------------------------------
-module(navstar_rest_dns_handler).
-author("dgoel").

-include("navstar_rest.hrl").
-include_lib("dns/include/dns.hrl").

%% API
-export([init/2]).
-export([content_types_provided/2, allowed_methods/2]).
-export([to_json/2]).

init(Req, Opts) ->
    {cowboy_rest, Req, Opts}.

content_types_provided(Req, State) ->
    {[
        {<<"application/json">>, to_json}
    ], Req, State}.

allowed_methods(Req, State) ->
    {[<<"GET">>], Req, State}.

to_json(Req, State) ->
    [Zone] = cowboy_req:path_info(Req),
    fetch_zone(Zone, Req, State).

fetch_zone(Zone, Req, State) ->
    {Value0, Clock} = lashup_kv:value2([navstar,dns,zones,Zone]),
    [Value1] = lists:map(fun encode_value/1, Value0),
    Body = jsx:encode(Value1),
    Req2 = cowboy_req:reply(200, [
        {<<"clock">>, base64:encode(term_to_binary(Clock))}
    ], Body, Req),
    {<<>>, Req2, State}.

encode_value({{Name, riak_dt_orswot}, Value}) ->
    #{Name => lists:map(fun encode_value2/1, Value)}.

encode_value2(Record0 = #dns_rr{data = Data}) ->
    DataMap = record_to_map(Data),
    Record1 = Record0#dns_rr{data = DataMap},
    record_to_map(Record1).
    
record_to_map(Record = #dns_rrdata_a{}) ->
    maps:from_list(lists:zip(record_info(fields, dns_rrdata_a), tl(tuple_to_list(Record))));
record_to_map(Record = #dns_rrdata_ns{}) ->
    maps:from_list(lists:zip(record_info(fields, dns_rrdata_ns), tl(tuple_to_list(Record))));
record_to_map(Record = #dns_rrdata_soa{}) ->
    maps:from_list(lists:zip(record_info(fields, dns_rrdata_soa), tl(tuple_to_list(Record))));
record_to_map(Record = #dns_rrdata_srv{}) ->
    maps:from_list(lists:zip(record_info(fields, dns_rrdata_srv), tl(tuple_to_list(Record))));
record_to_map(Record = #dns_rr{}) ->
    maps:from_list(lists:zip(record_info(fields, dns_rr), tl(tuple_to_list(Record)))).
