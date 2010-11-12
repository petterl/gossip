%% -*- tab-width: 4;erlang-indent-level: 4;indent-tabs-mode: nil -*-

-module(test_transaction).

-compile(export_all).

-include_lib("eunit/include/eunit.hrl").

transaction_test_() ->
    {"Transaction handler Tests",{setup, fun setup/0, fun teardown/1,
     [{"Get a Transaction id", fun get_tid/0},
      {"Fail on non compliant TID", fun fail_non_compliant/0},
      {"Fail on missing Via", fun fail_non_compliant2/0},
      {"Get same TID for ack", fun get_tid_ack/0},
      {"2 transactions from one client different TID", fun diff_tid_same_sentby/0},
      {"2 clients same branch different TID", fun diff_tid_same_branch/0}
]}}.

setup() ->
    ok.

teardown(_) ->
    ok.

get_tid() ->
    Stq = stq:new(invite, <<"sip:bob@localhost.com">>, {2,0}), 
    HStq = stq:header('Via',{<<"SIP/2.0/UDP 192.0.2.4">>,
                              [{<<"branch">>,<<"z9hG4bKnashds10">>}]}, 
                      1, Stq),
    ?assertMatch({_,_,invite}, gossip_transaction:get_transaction_id(HStq)).

fail_non_compliant() ->
    Stq = stq:new(invite, <<"sip:bob@localhost.com">>, {2,0}), 
    HStq = stq:header('Via',{<<"SIP/2.0/UDP 192.0.2.4">>,
                              [{<<"branch">>,<<"nashds10">>}]}, 
                      1, Stq),
    ?assertMatch({error, {non_compliant_branch, _}}, 
                 gossip_transaction:get_transaction_id(HStq)).

fail_non_compliant2() ->
    StqInv = stq:new(invite, <<"sip:bob@localhost.com">>, {2,0}),
    ?assertMatch({error, missing_via_header}, 
                 gossip_transaction:get_transaction_id(StqInv)).

get_tid_ack() ->
    Stq = stq:new(invite, <<"sip:bob@localhost.com">>, {2,0}), 
    HStq = stq:header('Via',{<<"SIP/2.0/UDP 192.0.2.4">>,
                              [{<<"branch">>,<<"z9hG4bKnashds10">>}]}, 
                      1, Stq),
    StqA = stq:new(ack, <<"sip:bob@localhost.com">>, {2,0}), 
    HStqA = stq:header('Via',{<<"SIP/2.0/UDP 192.0.2.4">>,
                              [{<<"branch">>,<<"z9hG4bKnashds10">>}]}, 
                      1, StqA),
    InvTid = gossip_transaction:get_transaction_id(HStq),
    AckTid = gossip_transaction:get_transaction_id(HStqA),
    ?assertEqual(AckTid, InvTid).
    
diff_tid_same_sentby() ->
    Stq = stq:new(invite, <<"sip:bob@localhost.com">>, {2,0}), 
    HStq = stq:header('Via',{<<"SIP/2.0/UDP 192.0.2.4">>,
                              [{<<"branch">>,<<"z9hG4bKnashds10">>}]}, 
                      1, Stq),
    HStq2 = stq:header('Via',{<<"SIP/2.0/UDP 192.0.2.4">>,
                              [{<<"branch">>,<<"z9hG4bKnashds11">>}]}, 
                       1, Stq),
    Tid1 = gossip_transaction:get_transaction_id(HStq),
    Tid2 = gossip_transaction:get_transaction_id(HStq2),    
    ?assertNot(Tid1 =:= Tid2).

diff_tid_same_branch() ->
    Stq = stq:new(invite, <<"sip:bob@localhost.com">>, {2,0}), 
    HStq = stq:header('Via',{<<"SIP/2.0/UDP 192.0.2.4">>,
                              [{<<"branch">>,<<"z9hG4bKnashds10">>}]}, 
                      1, Stq),
    HStq2 = stq:header('Via',{<<"SIP/2.0/UDP 192.0.2.5">>,
                              [{<<"branch">>,<<"z9hG4bKnashds10">>}]}, 
                       1, Stq),
    Tid1 = gossip_transaction:get_transaction_id(HStq),
    Tid2 = gossip_transaction:get_transaction_id(HStq2),    
    ?assertNot(Tid1 =:= Tid2).
