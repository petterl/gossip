%% -*- tab-width: 4;erlang-indent-level: 4;indent-tabs-mode: nil -*-

-module(test_invite_server_fsm).

-compile(export_all).

-include_lib("eunit/include/eunit.hrl").

-define(assertSend(Pid, Stq),
        ?assertEqual(ok, gossip_server_inv_fsm:send(Pid, Stq)),
        ?assertMatch(Stq, recv(transport))).

-define(assertRecv(Pid, Stq, Method),
        ?assertEqual(ok, gossip_server_inv_fsm:recv(Pid, Stq)),
        ?assertMatch({_,Stq, _}, recv({application,Method}))).

-define(assertDown(Pid),
        erlang:monitor(process, Pid),
        ?assertMatch({'DOWN',_,_,_,_}, recv())).

-define(assertResponse(Side, Code),
        (fun() ->
                 case recv(Side) of
                     {_,Stq,_} ->
                         ?assertEqual(response, stq:type(Stq)),
                         ?assertEqual(Code, stq:code(Stq));
                     Stq ->
                         ?assertEqual(response, stq:type(Stq)),
                         ?assertEqual(Code, stq:code(Stq))
                 end
         end)()).


invite_test_() ->
    {"Invite Tests",{setup, fun setup/0, fun teardown/1,
     [{"INV -> 200",fun sunny_day/0},
      {"INV -> 100 -> 200",fun wait_for_100/0},
      {"INV -> 100 -> INV -> 100 -> 200",fun wait_for_100_retransmit_inv/0},
      {"INV -> 180 -> 200",fun provisional_resp/0},
      {"INV -> 180 -> INV -> 180 -> 200",
       fun provisional_resp_restransmit_inv/0},
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
    meck:expect(gossip_transport, send, fun(_Type, MeckStq) ->
                                                Self ! {transport, MeckStq}
                                        end),
    meck:expect(gossip_transport, type, fun(Type) ->
                                                Type
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
    
    {ok, Pid} = setup("id", StqInv, tcp, []),

    %% Check that invite is sent to application
    ?assertMatch({"id", StqInv, tcp}, recv({application,invite})),

    ?assertSend(Pid, Stq200),
    
    ?assertDown(Pid).

wait_for_100() ->
    
    StqInv = stq:new(invite, <<"sip:bob@localhost.com">>, {2,0}),
    Stq200 = stq:new(200, <<"OK">>, {2,0}),
    
    {ok, Pid} = setup("id", StqInv, tcp, []),

    %% Check that invite is sent to application
    ?assertMatch({"id", StqInv, tcp}, recv({application,invite})),

    ?assertResponse(transport, 100),
    
    ?assertSend(Pid, Stq200),
    ?assertDown(Pid).

wait_for_100_retransmit_inv() ->
    
    StqInv = stq:new(invite, <<"sip:bob@localhost.com">>, {2,0}),
    Stq200 = stq:new(200, <<"OK">>, {2,0}),
    
    {ok, Pid} = setup("id", StqInv, tcp, []),

    %% Check that invite is sent to application
    ?assertMatch({"id", StqInv, tcp}, recv({application,invite})),

    ?assertResponse(transport, 100),

    %% Retransmit invite
    gossip_server_inv_fsm:recv(Pid, StqInv),

    ?assertResponse(transport, 100),

    ?assertSend(Pid, Stq200),
    
    ?assertDown(Pid).

provisional_resp() ->
    StqInv = stq:new(invite, <<"sip:bob@localhost.com">>, {2,0}),
    Stq180 = stq:new(180, <<"Ringing">>, {2,0}),
    Stq200 = stq:new(200, <<"OK">>, {2,0}),

    %% Start FSM and check that INVITE is sent to application
    {ok, Pid} = setup("id", StqInv, tcp, []),
    ?assertMatch({"id", StqInv, tcp}, recv({application,invite})),

    %% Send 180 and check that it is sent to transport
    ?assertSend(Pid, Stq180),

    %% Send 200 and check that it is sent to transport
    ?assertSend(Pid, Stq200),

    %% Check that fsm has terminated
    ?assertDown(Pid).

provisional_resp_restransmit_inv() ->
    StqInv = stq:new(invite, <<"sip:bob@localhost.com">>, {2,0}),
    Stq180 = stq:new(180, <<"Ringing">>, {2,0}),
    Stq200 = stq:new(200, <<"OK">>, {2,0}),

    %% Start FSM and check that INVITE is sent to application
    {ok, Pid} = setup("id", StqInv, tcp, []),
    ?assertMatch({"id", StqInv, tcp}, recv({application,invite})),

    %% Send 180 and check that it is sent to transport
    ?assertSend(Pid, Stq180),

    %% Retransmit INV
    gossip_server_inv_fsm:recv(Pid, StqInv),
    ?assertResponse(transport, 180),

    %% Send 200 and check that it is sent to transport
    ?assertSend(Pid, Stq200),

    %% Check that fsm has terminated
    ?assertDown(Pid).

final_non_200_resp() ->
    T1 = 100,
    TH = 64 * T1,
    T4 = 10,
    StqInv = stq:new(invite, <<"sip:bob@localhost.com">>, {2,0}),
    Stq301 = stq:new(301, <<"Moved Permanently">>, {2,0}),
    StqAck = stq:new(ack, <<"sip:bob@localhost.com">>, {2,0}),

    %% Start FSM and check that INVITE is sent to application
    {ok, Pid} = setup("id", StqInv, tcp, [{t1,T1},{t4,T4}]),
    ?assertMatch({"id", StqInv, tcp}, recv({application,invite})),

    %% Send 301 and check that it is sent to transport
    ?assertSend(Pid, Stq301),
    ?assertMatch({TH, timerH, _}, recv(timer)),
    
    %% Send ACK and check that it is sent to application
    ?assertRecv(Pid, StqAck, ack),
    TimerI = recv(timer),
    ?assertMatch({0,timerI,_}, TimerI),
    {_,timerI,Ref} = TimerI,

    %% Trigger timerI
    ?assertEqual(ok, gen_fsm:send_event(Pid, {timeout, Ref, timerI})),

    %% Check that fsm has terminated
    ?assertDown(Pid).

final_non_200_resp_nonreliable() ->
    T1 = 100,
    TH = 64 * T1,
    T4 = 10,
    ConInfo = udp, 
    StqInv = stq:new(invite, <<"sip:bob@localhost.com">>, {2,0}),
    Stq301 = stq:new(301, <<"Moved Permanently">>, {2,0}),
    StqAck = stq:new(ack, <<"sip:bob@localhost.com">>, {2,0}),

    %% Start FSM and check that INVITE is sent to application
    {ok, Pid} = setup("id", StqInv, ConInfo, [{t1,T1},{t4,T4}]),
    ?assertMatch({"id", StqInv, ConInfo}, recv({application,invite})),

    %% Send 301 and check that it is sent to transport
    ?assertSend(Pid, Stq301),
    ?assertMatch({T1, timerG, _}, recv(timer)),
    ?assertMatch({TH, timerH, _}, recv(timer)),
    
    %% Send ACK and check that it is sent to application
    ?assertRecv(Pid, StqAck, ack),
    TimerI = recv(timer),
    ?assertMatch({T4,timerI,_}, TimerI),
    {_,timerI,Ref} = TimerI,

    %% Trigger timerI
    ?assertEqual(ok, gen_fsm:send_event(Pid, {timeout, Ref, timerI})),

    %% Check that fsm has terminated
    ?assertDown(Pid).

recv() ->
    recv(250).
recv(TO) when is_integer(TO) ->
    receive
        Msg ->
            Msg
    after TO ->
            timeout
    end;
recv(Tag) ->
    recv(Tag, 250).
recv(Tag, TO) ->
    receive
        {Tag,Msg} ->
            Msg
    after TO ->
            timeout
    end.
