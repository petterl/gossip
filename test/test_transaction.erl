%% -*- tab-width: 4;erlang-indent-level: 4;indent-tabs-mode: nil -*-

-module(test_transaction).

-compile(export_all).

-include_lib("eunit/include/eunit.hrl").

transaction_test_() ->
    {"Transaction handler Tests",{setup, fun setup/0, fun teardown/1,
     [{"Get a Transaction id", fun get_tid/0},
      {"Fail on non compliant TID", fun fail_non_compliant/0},
      {"Get same TID for ack", fun get_tid_ack/0},
      {"2 transactions from one client different TID", fun diff_tid_same_sentby/0},
      {"2 clients same branch different TID", fun diff_tid_same_branch/0}
]}}.

setup() ->
    ok.

teardown(_) ->
    ok.

get_tid() ->
    StqInv = stq:new(invite, <<"sip:bob@localhost.com">>, {2,0}),
    StqInv1 = stq:header('Via', 
                         <<"SIP/2.0/UDP 192.0.2.4;branch=z9hG4bKnashds10">>, 
                         1, StqInv),
    ?assertMatch({_,_,invite}, gossip_transaction:get_transaction_id(StqInv1)).

fail_non_compliant() ->
    StqInv = stq:new(invite, <<"sip:bob@localhost.com">>, {2,0}),
    StqInv1 = stq:header('Via', 
                         <<"SIP/2.0/UDP 192.0.2.4;branch=nashds10">>, 
                         1, StqInv),
    ?assertMatch({error, non_compliant_branch, _}, 
                 gossip_transaction:get_transaction_id(StqInv1)).

get_tid_ack() ->
    StqInv0 = stq:new(invite, <<"sip:bob@localhost.com">>, {2,0}),
    StqInv = stq:header('Via', 
                         <<"SIP/2.0/UDP 192.0.2.4;branch=z9hG4bKnashds10">>, 
                         1, StqInv0),
    StqAck0 = stq:new(invite, <<"sip:bob@localhost.com">>, {2,0}),
    StqAck = stq:header('Via', 
                         <<"SIP/2.0/UDP 192.0.2.4;branch=z9hG4bKnashds10">>, 
                         1, StqAck0),

    InvTid = gossip_transaction:get_transaction_id(StqInv),
    AckTid = gossip_transaction:get_transaction_id(StqAck),
    ?assertEqual(AckTid, InvTid).
    
diff_tid_same_sentby() ->
    StqInv = stq:new(invite, <<"sip:bob@localhost.com">>, {2,0}),
    StqInv1 = stq:header('Via', 
                         <<"SIP/2.0/UDP 192.0.2.4;branch=z9hG4bKnashds10">>, 
                         1, StqInv),
    StqInv2 = stq:header('Via', 
                         <<"SIP/2.0/UDP 192.0.2.4;branch=z9hG4bKnashds11">>, 
                         1, StqInv),
    Tid1 = gossip_transaction:get_transaction_id(StqInv1),
    Tid2 = gossip_transaction:get_transaction_id(StqInv2),    
    ?assertNot(Tid1 =:= Tid2).

diff_tid_same_branch() ->
    StqInv = stq:new(invite, <<"sip:bob@localhost.com">>, {2,0}),
    StqInv1 = stq:header('Via', 
                         <<"SIP/2.0/UDP 192.0.2.4;branch=z9hG4bKnashds10">>, 
                         1, StqInv),
    StqInv2 = stq:header('Via', 
                         <<"SIP/2.0/UDP 192.0.2.5;branch=z9hG4bKnashds10">>, 
                         1, StqInv),
    Tid1 = gossip_transaction:get_transaction_id(StqInv1),
    Tid2 = gossip_transaction:get_transaction_id(StqInv2),    
    ?assertNot(Tid1 =:= Tid2).
