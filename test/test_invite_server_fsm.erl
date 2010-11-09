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
        ?assertMatch({'DOWN',_,_,_,_}, recv()),
        ?assertEqual(timeout, recv(1))).

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
      {"INV -> INV -> 200", fun retransmit_inv/0},
      {"INV -> 180 -> 200",fun provisional_resp/0},
      {"INV -> 180 -> INV -> 180 -> 200",
       fun provisional_resp_restransmit_inv/0},
      {"INV -> 301 -> ACK",fun final_non_2xx_resp/0},
      {"INV -> 301 -> ACK (udp)",fun final_non_2xx_resp_nonreliable/0},
      {"INV -> 301 -> TimerG -> 301 -> ACK", fun final_non_2xx_timerG/0},
      {"INV -> 301 -> TimerH", fun final_non_2xx_timerH/0},
      {"INV -> 301 -> INV -> 301 -> ACK",fun final_non_2xx_resp_retransmit_inv/0},
      {"INV -> 301 -> ACK -> ACK", fun final_non_2xx_resp_retransmit_ack/0},
      {"INV -> TransErr", fun transport_error_invite/0},
      {"INV -> 180 -> TransErr", fun transport_error_provisional/0},
      {"INV -> 301 -> TransErr", fun transport_error_final_non_2xx/0}]}}.

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
    meck:expect(meck_module, transport_error,
                fun(MeckId, Reason, MeckConInfo) ->
                        Self ! {{application,transport_error},
                                {MeckId, Reason, MeckConInfo}}
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

retransmit_inv() ->
    StqInv = stq:new(invite, <<"sip:bob@localhost.com">>, {2,0}),
    Stq200 = stq:new(200, <<"OK">>, {2,0}),
    
    {ok, Pid} = setup("id", StqInv, tcp, []),

    %% Check that invite is sent to application
    ?assertMatch({"id", StqInv, tcp}, recv({application,invite})),

    %% Receive retransmitted INVITE from network
    gossip_server_inv_fsm:recv(Pid, StqInv),
    ?assertEqual(timeout, recv({application, invite}, 10)),

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

final_non_2xx_resp() ->
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

final_non_2xx_resp_nonreliable() ->
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

final_non_2xx_timerG() ->
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
    TimerG = recv(timer),
    ?assertMatch({T1,timerG,_}, TimerG),
    {_,timerG,RefG} = TimerG,
    ?assertMatch({TH, timerH, _}, recv(timer)),
    
    %% Trigger TimerG
    ?assertEqual(ok, gen_fsm:send_event(Pid, {timeout, RefG, timerG})),

    TG = T1 * 2,
    ?assertMatch({TG,timerG,_}, recv(timer)),
    %% Check that 301 is resent
    ?assertResponse(transport, 301),

    %% Send ACK and check that it is sent to application
    ?assertRecv(Pid, StqAck, ack),
    TimerI = recv(timer),
    ?assertMatch({T4,timerI,_}, TimerI),
    {_,timerI,Ref} = TimerI,

    %% Trigger timerI
    ?assertEqual(ok, gen_fsm:send_event(Pid, {timeout, Ref, timerI})),

    %% Check that fsm has terminated
    ?assertDown(Pid).

final_non_2xx_timerH() ->
    T1 = 2,
    TH = 64 * T1,
    T4 = 10,
    ConInfo = tcp, 
    StqInv = stq:new(invite, <<"sip:bob@localhost.com">>, {2,0}),
    Stq301 = stq:new(301, <<"Moved Permanently">>, {2,0}),

    %% Start FSM and check that INVITE is sent to application
    {ok, Pid} = setup("id", StqInv, ConInfo, [{t1,T1},{t4,T4}]),
    ?assertMatch({"id", StqInv, ConInfo}, recv({application,invite})),

    %% Send 301 and check that it is sent to transport
    ?assertSend(Pid, Stq301),
    TimerH = recv(timer),
    ?assertMatch({TH,timerH,_}, TimerH),
    {_,timerH,RefH} = TimerH,
    
    %% Trigger TimerH
    ?assertEqual(ok, gen_fsm:send_event(Pid, {timeout, RefH, timerH})),
    ?assertMatch({_, timerH, _}, recv({application,transport_error})),

    %% Check that fsm has terminated
    ?assertDown(Pid).

final_non_2xx_resp_retransmit_inv() ->
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
    
    %% Receive retransmitted INVITE from network
    gossip_server_inv_fsm:recv(Pid, StqInv),

    ?assertMatch(Stq301, recv(transport)),
        
    %% Send ACK and check that it is sent to application
    ?assertRecv(Pid, StqAck, ack),
    TimerI = recv(timer),
    ?assertMatch({0,timerI,_}, TimerI),
    {_,timerI,Ref} = TimerI,

    %% Trigger timerI
    ?assertEqual(ok, gen_fsm:send_event(Pid, {timeout, Ref, timerI})),

    %% Check that fsm has terminated
    ?assertDown(Pid).

final_non_2xx_resp_retransmit_ack() ->
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

    %% Receive retransmitted INVITE from network
    gossip_server_inv_fsm:recv(Pid, StqAck),
    ?assertEqual(timeout, recv({application, ack}, 10)),

    %% Trigger timerI
    ?assertEqual(ok, gen_fsm:send_event(Pid, {timeout, Ref, timerI})),

    %% Check that fsm has terminated
    ?assertDown(Pid).

transport_error_invite() ->
    StqInv = stq:new(invite, <<"sip:bob@localhost.com">>, {2,0}),
    
    {ok, Pid} = setup("id", StqInv, tcp, []),

    %% Check that invite is sent to application
    ?assertMatch({"id", StqInv, tcp}, recv({application,invite})),

    gossip_server_inv_fsm:transport_error(Pid, fail),
    ?assertMatch({_, fail, _}, recv({application, transport_error})),

    ?assertDown(Pid).

transport_error_provisional() ->
    StqInv = stq:new(invite, <<"sip:bob@localhost.com">>, {2,0}),
    Stq180 = stq:new(180, <<"Ringing">>, {2,0}),
    
    {ok, Pid} = setup("id", StqInv, tcp, []),

    %% Check that invite is sent to application
    ?assertMatch({"id", StqInv, tcp}, recv({application,invite})),

    %% Send 180 and check that it is sent to transport
    ?assertSend(Pid, Stq180),

    gossip_server_inv_fsm:transport_error(Pid, fail),
    ?assertMatch({_, fail, _}, recv({application, transport_error})),

    ?assertDown(Pid).

transport_error_final_non_2xx() ->
    T1 = 100,
    TH = 64 * T1,
    T4 = 10,
    StqInv = stq:new(invite, <<"sip:bob@localhost.com">>, {2,0}),
    Stq301 = stq:new(301, <<"Moved Permanently">>, {2,0}),
    
    {ok, Pid} = setup("id", StqInv, tcp, [{t1,T1},{t4,T4}]),

    %% Check that invite is sent to application
    ?assertMatch({"id", StqInv, tcp}, recv({application,invite})),

    %% Send 301 and check that it is sent to transport
    ?assertSend(Pid, Stq301),
    ?assertMatch({TH, timerH, _}, recv(timer)),

    gossip_server_inv_fsm:transport_error(Pid, fail),
    ?assertMatch({_, fail, _}, recv({application, transport_error})),

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

get_state(Pid) ->
    {status,_Pid,_ModTpl, List} = sys:get_status(Pid),
    io:format("~p",[List]),
    AllData = lists:flatten([ X || {data,X} <- lists:last(List) ]),
    proplists:get_value("StateData",AllData).
