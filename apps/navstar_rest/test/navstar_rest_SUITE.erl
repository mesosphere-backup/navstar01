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

-export([navstar_rest_dns_test/1]).

-include_lib("dns/include/dns.hrl").

-define(RECORDS_FIELD, {records, riak_dt_orswot}).

all() -> [navstar_rest_dns_test].

navstar_rest_dns_test(_Config) ->
    application:ensure_all_started(navstar_rest),
    ZoneName = <<"dcos.thisdcos.directory">>,
    Records = base_records(ZoneName),
    push_zone_to_lashup(ZoneName, Records),   
    URI = lists:flatten(io_lib:format("http://127.0.0.1:62080/dns/~s", [binary_to_list(ZoneName)])),
    {ok, {_Status, _Headers, Body}} = httpc:request(get, {URI, []}, [], [{body_format, binary}]),
    DecodedBody = jsx:decode(Body),
    [{<<"records">>, [_ | _]}] = DecodedBody,
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
