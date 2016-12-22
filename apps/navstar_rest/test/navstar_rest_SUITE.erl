%%%-------------------------------------------------------------------
%%% @author dgoel
%%% @copyright (C) 2016, <COMPANY>
%%% @doc
%%%
%%% @end
%%% Created : 16. Dec 2016 04:58 PM
%%%-------------------------------------------------------------------
-module(navstar_rest_SUITE).
-author("dgoel").

-export([all/0]).

-export([navstar_rest_dns_post_test/1, navstar_rest_dns_get_test/1, 
         navstar_rest_dns_modify_test/1, navstar_rest_dns_overwrite_test/1]).

-include_lib("dns/include/dns.hrl").
-include_lib("eunit/include/eunit.hrl").
-include_lib("common_test/include/ct.hrl").

-define(RECORDS_FIELD, {records, riak_dt_orswot}).

all() -> [navstar_rest_dns_post_test, navstar_rest_dns_get_test, 
          navstar_rest_dns_modify_test, navstar_rest_dns_overwrite_test].

navstar_rest_dns_post_test(_Config) ->
    application:ensure_all_started(navstar_rest),
    ZoneName = <<"test.thisdcos.directory">>,
    Record = #{class => 1, data => #{ip => <<"9.0.0.1">>}, name => ZoneName, ttl => 3600, type => 1},
    Records = #{records => [Record]},
    Body = jsx:encode(Records),
    URI = lists:flatten(io_lib:format("http://127.0.0.1:62080/dns/~s", [binary_to_list(ZoneName)])),
    {ok, _} = httpc:request(post, {URI, [], "application/json", Body}, [], []),
    Value = lashup_kv:value([navstar, dns, zones, ZoneName]),
    io:format("Value ~p~n", [Value]),
    [{{records, riak_dt_orswot}, [_]}] = Value,
    ok.

navstar_rest_dns_get_test(_Config) ->
    application:ensure_all_started(navstar_rest),
    ZoneName = <<"dcos.thisdcos.directory">>,
    Records = base_records(ZoneName),
    push_zone_to_lashup(ZoneName, Records),   
    URI = lists:flatten(io_lib:format("http://127.0.0.1:62080/dns/~s", [binary_to_list(ZoneName)])),
    {ok, {_Status, _Headers0, Body}} = httpc:request(get, {URI, []}, [], [{body_format, binary}]),
    DecodedBody = jsx:decode(Body),
    io:format("DecodedBody: ~p~n", [DecodedBody]),
    [{<<"records">>, [_ | _]}] = DecodedBody,
    ok.

navstar_rest_dns_modify_test(_Config) ->
    application:ensure_all_started(navstar_rest),
    ZoneName = <<"dcos.thisdcos.directory">>,
    URI = lists:flatten(io_lib:format("http://127.0.0.1:62080/dns/~s", [binary_to_list(ZoneName)])),

    %% fetch current records
    {ok, {_Status, Headers, Body}} = httpc:request(get, {URI, []}, [], [{body_format, binary}]),
    RecordMap = jsx:decode(Body, [return_maps, {labels, atom}]),
    OldRecords = maps:get(records, RecordMap),
    [_,_] = OldRecords,

    %% modify records
    NewRecord = #{class => 1, data => #{ip => <<"9.0.0.1">>}, name => ZoneName, ttl => 3600, type => 1},
    AddedRecords = ordsets:union(ordsets:from_list(OldRecords), ordsets:from_list([NewRecord])),
    NewRecordMap = maps:put(records, AddedRecords, maps:new()),
    PostBody = jsx:encode(NewRecordMap),
    {ok, _} = httpc:request(post, {URI, Headers, "application/json", PostBody}, [], []),

    %% verify modified records
    Value = lashup_kv:value([navstar, dns, zones, ZoneName]),
    io:format("Final Records ~p~n", [Value]),
    [{{records, riak_dt_orswot}, [_,_,_]}] = Value,
    ok.

navstar_rest_dns_overwrite_test(_Config) ->
    application:ensure_all_started(navstar_rest),
    ZoneName = <<"dcos.thisdcos.directory">>,
    URI = lists:flatten(io_lib:format("http://127.0.0.1:62080/dns/~s", [binary_to_list(ZoneName)])),

    %% modify records
    NewRecord = #{class => 1, data => #{dname => "test.dcos.directory"}, name => ZoneName, ttl => 3600, type => 5},
    NewRecordMap = maps:put(records, [NewRecord], maps:new()),
    PostBody = jsx:encode(NewRecordMap),
    Headers = [{"clock", base64:encode_to_string(term_to_binary("overwrite"))}],
    {ok, _} = httpc:request(post, {URI, Headers, "application/json", PostBody}, [], []),

    %% verify modified records
    Value = lashup_kv:value([navstar, dns, zones, ZoneName]),
    io:format("Final Records ~p~n", [Value]),
    [{{records, riak_dt_orswot}, [_]}] = Value,
    ok.

base_records(ZoneName) ->
    ordsets:from_list(
    [
        #dns_rr{
            name = ZoneName,
            type = ?DNS_TYPE_SOA,
            ttl = 3600,
            data = #dns_rrdata_soa{
                mname = <<"ns.spartan">>, %% Nameserver
                rname = <<"support.mesosphere.com">>,
                serial = 1,
                refresh = 60,
                retry = 180,
                expire = 86400,
                minimum = 1
            }
        },
        #dns_rr{
            name = ZoneName,
            type = ?DNS_TYPE_NS,
            ttl = 3600,
            data = #dns_rrdata_ns{
                dname = <<"ns.spartan">>
            }
        }
    ]).

push_zone_to_lashup(ZoneName, Records) ->
    Key = [navstar, dns, zones, ZoneName],
    Ops = [{update, ?RECORDS_FIELD, {add_all, Records}}],
    lashup_kv:request_op(Key, {update, Ops}).
