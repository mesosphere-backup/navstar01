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
-export([content_types_provided/2, allowed_methods/2, content_types_accepted/2]).
-export([to_json/2, update_zone/2]).

-define(RECORDS_FIELD, {records, riak_dt_orswot}).

init(Req, Opts) ->
    {cowboy_rest, Req, Opts}.

content_types_provided(Req, State) ->
    {[
        {<<"application/json">>, to_json}
    ], Req, State}.

allowed_methods(Req, State) ->
    {[<<"GET">>, <<"POST">>], Req, State}.

content_types_accepted(Req, State) ->
    {[
        {<<"application/json">>, update_zone}
    ], Req, State}.

update_zone(Req, State) ->
    <<"POST">> = cowboy_req:method(Req),
    true = cowboy_req:has_body(Req),
    [ZoneName] = cowboy_req:path_info(Req),
    {ok, Body, _Req2} = cowboy_req:body(Req),
    Result = case cowboy_req:header(<<"clock">>, Req, <<>>) of
               <<>> ->
                   update_zone(ZoneName, [], Body);
               Clock0 ->
                   Clock1 = binary_to_term(base64:decode(Clock0)),
                   update_zone(ZoneName, Clock1, Body)
               end,
    Req2 = case Result of
             {error, Reason} ->
                 cowboy_req:reply(400, [], Reason, Req);
             _ ->
                 cowboy_req:reply(200, Req)
           end,
    {<<>>, Req2, State}.

update_zone(ZoneName, Clock, Body0) ->
    Body1 = jsx:decode(Body0, [return_maps, {labels, atom}]),
    Records = maps:get(records, Body1),
    ParsedRecords = lists:map(fun map_to_record/1, Records),
    push_zone_to_lashup(ZoneName, Clock, ParsedRecords).

push_zone_to_lashup(ZoneName, Clock, NewRecords) ->
    ZoneKey = [navstar, dns, zones, ZoneName],
    {OriginalMap, VClock} = lashup_kv:value2(ZoneKey),
    case {Clock, VClock} of
        {_, []} ->
           push_zone_to_lashup(ZoneKey, Clock, [], NewRecords);
        {[], _} -> {error, "To modify existing record, Clock header is required"};
        {_, _} ->
           {_, OldRecords0} = lists:keyfind(?RECORDS_FIELD, 1, OriginalMap),
           OldRecords1 = lists:usort(OldRecords0),
           push_zone_to_lashup(ZoneKey, Clock, OldRecords1, NewRecords)
    end.

push_zone_to_lashup(ZoneKey, Clock, OldRecords, NewRecords) ->
    case ops(OldRecords, NewRecords) of
        [] ->
            {ok, no_change};
        Ops ->
            lashup_kv:request_op(ZoneKey, Clock, {update, Ops})
    end.

ops(OldRecords, NewRecords) ->
    RecordsToDelete = ordsets:subtract(OldRecords, NewRecords),
    RecordsToAdd = ordsets:subtract(NewRecords, OldRecords),
    Ops0 = lists:foldl(fun delete_op/2, [], RecordsToDelete),
    case RecordsToAdd of
        [] ->
            Ops0;
        _ ->
            [{update, ?RECORDS_FIELD, {add_all, RecordsToAdd}}|Ops0]
    end.

delete_op(Record, Acc0) ->
    Op = {update, ?RECORDS_FIELD, {remove, Record}},
    [Op|Acc0].

to_json(Req, State) ->
    [Zone] = cowboy_req:path_info(Req),
    fetch_zone(Zone, Req, State).

fetch_zone(Zone, Req, State) ->
    {Value0, Clock} = lashup_kv:value2([navstar, dns, zones, Zone]),
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

map_to_record(#{class := Class, name := Name, ttl := TTL, type := Type, data := Data}) ->
    DataRecord = map_to_record(Type, Data),
    #dns_rr{class = Class, name = Name, ttl = TTL, type = Type, data = DataRecord}.

map_to_record(?DNS_TYPE_A, #{ip := IP}) when is_binary(IP)->
    IPStr = binary_to_list(IP),
    {ok, ParsedIP} = inet:parse_ipv4_address(IPStr),
    #dns_rrdata_a{ip = ParsedIP};
map_to_record(?DNS_TYPE_NS, #{dname := Dname}) ->
    #dns_rrdata_ns{dname = Dname};
map_to_record(?DNS_TYPE_SOA, #{mname := Mname, rname := Rname, serial := Serial, refresh := Refresh, retry := Retry,
               expire := Expire, minimum := Minimum}) ->
    #dns_rrdata_soa{mname = Mname, rname = Rname, serial = Serial, refresh = Refresh, retry = Retry, expire = Expire,
                    minimum = Minimum};
map_to_record(?DNS_TYPE_SRV, #{priority := Priority, weight := Weight, port := Port, target := Target}) ->
    #dns_rrdata_srv{priority = Priority, weight = Weight, port = Port, target = Target}.
