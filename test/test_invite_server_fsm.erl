%% -*- tab-width: 4;erlang-indent-level: 4;indent-tabs-mode: nil -*-

-module(test_invite_server_fsm).

-compile(export_all).

-include_lib("eunit/include/eunit.hrl").

invite_test_() ->
    {"Invite Tests",{setup, fun setup/0, fun teardown/1,
     [{"INV -> 200",fun sunny_day/0},
      {"INV -> 100 -> 200",fun wait_for_100/0},
      {"INV -> 100 -> INV -> 100 -> 200",fun wait_for_100_retransmit_inv/0},
      {"INV -> 180 -> 200",fun provisional_resp/0},
      {"INV -> 301 -> ACK",fun final_non_200_resp/0},
      {"INV -> 301 -> ACK (udp)",fun final_non_200_resp_nonreliable/0}]}}.

setup() ->
    code:unstick_mod(gen_fsm),
    MeckModules = [meck_module, gossip_transport, gen_fsm],
    lists:map(fun(Mod) ->
                      meck:new(Mod,[passthrough]),
                      Mod
              end, MeckModules).

setup(Id, Stq, ConInfo, Opts) ->
    setup(Id, Stq, ConInfo, Opts, tcp).
setup(Id, Stq, ConInfo, Opts, Transport) ->
    Self = self(),
    meck:expect(meck_module, invite,
                fun(MeckId, MeckStq, MeckConInfo) ->
                        Self ! {{application,invite},
                                {MeckId, MeckStq, MeckConInfo}}
                end),
    meck:expect(meck_module, ack,
                fun(MeckId, MeckStq, MeckConInfo) ->
                        Self ! {{application,ack},
                                {MeckId, MeckStq, MeckConInfo}}
                end),
    meck:expect(gossip_transport, send, fun(phony, MeckStq) ->
                                                Self ! {transport, MeckStq}
                                        end),
    meck:expect(gossip_transport, type, fun(phony) ->
                                                Transport
                                        end),
    meck:expect(gen_fsm, start_timer, fun(Val, Msg) ->
                                              Ref = make_ref(),
                                              Self ! {timer, {Val, Msg, Ref}},
                                              Ref
                                      end),
    Res = (catch gossip_server_inv_fsm:start_link(
                   Id, Stq, ConInfo, [meck_module], Opts)),
    ?assertMatch({ok, Pid} when is_pid(Pid), Res),
    Res.

teardown(_) ->
    meck:unload(),
    code:stick_mod(gen_fsm).

sunny_day() ->
    StqInv = stq:new(invite, <<"sip:bob@localhost.com">>, {2,0}),
    Stq200 = stq:new(200, <<"OK">>, {2,0}),
    
    {ok, Pid} = setup("id", StqInv, phony, []),

    %% Check that invite is sent to application
    ?assertMatch({"id", StqInv, phony}, recv({application,invite})),

    ?assertEqual(ok, gossip_server_inv_fsm:send(Pid, Stq200)),

    ?assertMatch(Stq200, recv(transport)),
    erlang:monitor(process, Pid),
    ?assertMatch({'DOWN',_,_,_,_}, recv()),
    
    ok.

wait_for_100() ->
    
    StqInv = stq:new(invite, <<"sip:bob@localhost.com">>, {2,0}),
    Stq200 = stq:new(200, <<"OK">>, {2,0}),
    
    {ok, Pid} = setup("id", StqInv, phony, []),

    %% Check that invite is sent to application
    ?assertMatch({"id", StqInv, phony}, recv({application,invite})),

    Stq100 = recv(transport, 300),
    ?assertEqual(response, stq:type(Stq100)),
    ?assertEqual(100, stq:code(Stq100)),
    
    gossip_server_inv_fsm:send(Pid, Stq200),

    ?assertMatch(Stq200, recv(transport)),
    ?assertEqual(timeout, recv(1)),
    
    ok.

wait_for_100_retransmit_inv() ->
    
    StqInv = stq:new(invite, <<"sip:bob@localhost.com">>, {2,0}),
    Stq200 = stq:new(200, <<"OK">>, {2,0}),
    
    {ok, Pid} = setup("id", StqInv, phony, []),

    %% Check that invite is sent to application
    ?assertMatch({"id", StqInv, phony}, recv({application,invite})),

    Stq100 = recv(transport, 300),
    ?assertEqual(response, stq:type(Stq100)),
    ?assertEqual(100, stq:code(Stq100)),

    gossip_server_inv_fsm:recv(Pid, StqInv),

    Stq100Retrans = recv(transport),
    ?assertEqual(response, stq:type(Stq100Retrans)),
    ?assertEqual(100, stq:code(Stq100Retrans)),
    
    gossip_server_inv_fsm:send(Pid, Stq200),

    ?assertMatch(Stq200, recv(transport)),
    ?assertEqual(timeout, recv(1)),
    
    ok.

provisional_resp() ->
    StqInv = stq:new(invite, <<"sip:bob@localhost.com">>, {2,0}),
    Stq180 = stq:new(180, <<"Ringing">>, {2,0}),
    Stq200 = stq:new(200, <<"OK">>, {2,0}),

    %% Start FSM and check that INVITE is sent to application
    {ok, Pid} = setup("id", StqInv, phony, []),
    ?assertMatch({"id", StqInv, phony}, recv({application,invite})),

    %% Send 180 and check that it is sent to transport
    ?assertEqual(ok, gossip_server_inv_fsm:send(Pid, Stq180)),
    ?assertMatch(Stq180, recv(transport)),

    %% Send 200 and check that it is sent to transport
    ?assertEqual(ok, gossip_server_inv_fsm:send(Pid, Stq200)),
    ?assertMatch(Stq200, recv(transport)),

    %% Check that fsm has terminated
    erlang:monitor(process, Pid),
    ?assertMatch({'DOWN',_,_,_,_}, recv()),
    
    ok.

final_non_200_resp() ->
    T1 = 100,
    TH = 64 * T1,
    T4 = 10,
    StqInv = stq:new(invite, <<"sip:bob@localhost.com">>, {2,0}),
    Stq301 = stq:new(301, <<"Moved Permanently">>, {2,0}),
    StqAck = stq:new(ack, <<"sip:bob@localhost.com">>, {2,0}),

    %% Start FSM and check that INVITE is sent to application
    {ok, Pid} = setup("id", StqInv, phony, [{t1,T1},{t4,T4}]),
    ?assertMatch({"id", StqInv, phony}, recv({application,invite})),

    %% Send 301 and check that it is sent to transport
    ?assertEqual(ok, gossip_server_inv_fsm:send(Pid, Stq301)),
    ?assertMatch(Stq301, recv(transport)),
    ?assertMatch({TH, timerH, _}, recv(timer)),
    
    %% Send ACK and check that it is sent to application
    ?assertEqual(ok, gossip_server_inv_fsm:recv(Pid, StqAck)),
    ?assertMatch({"id",StqAck, phony}, recv({application,ack})),
    TimerI = recv(timer),
    ?assertMatch({0,timerI,_}, TimerI),
    {_,timerI,Ref} = TimerI,

    %% Trigger timerI
    ?assertEqual(ok, gen_fsm:send_event(Pid, {timeout, Ref, timerI})),

    %% Check that fsm has terminated
    erlang:monitor(process, Pid),
    ?assertMatch({'DOWN',_,_,_,_}, recv()),
    
    ok.

final_non_200_resp_nonreliable() ->
    T1 = 100,
    TH = 64 * T1,
    T4 = 10,
    StqInv = stq:new(invite, <<"sip:bob@localhost.com">>, {2,0}),
    Stq301 = stq:new(301, <<"Moved Permanently">>, {2,0}),
    StqAck = stq:new(ack, <<"sip:bob@localhost.com">>, {2,0}),

    %% Start FSM and check that INVITE is sent to application
    {ok, Pid} = setup("id", StqInv, phony, [{t1,T1},{t4,T4}], udp),
    ?assertMatch({"id", StqInv, phony}, recv({application,invite})),

    %% Send 301 and check that it is sent to transport
    ?assertEqual(ok, gossip_server_inv_fsm:send(Pid, Stq301)),
    ?assertMatch(Stq301, recv(transport)),
    ?assertMatch({T1, timerG, _}, recv(timer)),
    ?assertMatch({TH, timerH, _}, recv(timer)),
    
    %% Send ACK and check that it is sent to application
    ?assertEqual(ok, gossip_server_inv_fsm:recv(Pid, StqAck)),
    ?assertMatch({"id",StqAck, phony}, recv({application,ack})),
    TimerI = recv(timer),
    ?assertMatch({T4,timerI,_}, TimerI),
    {_,timerI,Ref} = TimerI,

    %% Trigger timerI
    ?assertEqual(ok, gen_fsm:send_event(Pid, {timeout, Ref, timerI})),

    %% Check that fsm has terminated
    erlang:monitor(process, Pid),
    ?assertMatch({'DOWN',_,_,_,_}, recv()),
    
    ok.

recv() ->
    recv(200).
recv(TO) when is_integer(TO) ->
    receive
        Msg ->
            Msg
    after TO ->
            timeout
    end;
recv(Tag) ->
    recv(Tag, 200).
recv(Tag, TO) ->
    receive
        {Tag,Msg} ->
            Msg
    after TO ->
            timeout
    end.
