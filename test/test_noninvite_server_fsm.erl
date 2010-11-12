%% -*- tab-width: 4;erlang-indent-level: 4;indent-tabs-mode: nil -*-

-module(test_noninvite_server_fsm).

-compile(export_all).

-include_lib("eunit/include/eunit.hrl").

-define(assertSend(Pid, Stq),
        ?assertEqual(ok, gossip_server_noninv_fsm:send(Pid, Stq)),
        ?assertMatch(Stq, recv(transport))).

-define(assertRecv(Pid, Stq, Method),
        ?assertEqual(ok, gossip_server_noninv_fsm:recv(Pid, Stq)),
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


noninvite_test_() ->
    {"non-Invite Tests",{setup, fun setup/0, fun teardown/1,
     [{"REGISTER -> 200 -> TimerJ",fun sunny_day/0},
      {"REGISTER -> 200 -> TimerJ (udp)",fun sunny_day_unreliable/0},
      {"REGISTER -> 100 -> 200",fun wait_for_100/0},
      {"REGISTER -> 100 -> 200 (udp)",fun wait_for_100_unreliable/0},
      {"REGISTER -> 100 -> 100 -> 200",fun wait_for_100_retransmit_100/0},
      {"REGISTER -> 100 -> REGISTER -> 100 -> 200",
       fun wait_for_100_retransmit_reg/0},
      {"REGISTER -> REGISTER -> 200", fun retransmit_reg/0},
      {"REGISTER -> 200 -> REGISTER -> 200", fun retransmit_reg_unreliable/0},
      {"REGISTER -> 100 -> TransErr", fun transport_error_provisional/0},
      {"REGISTER -> 200 -> TransErr", fun transport_error_final_2xx/0},
      {"BYE -> 200", fun method_bye/0},
      {"CANCEL -> 200", fun method_cancel/0},
      {"OPTION -> 200", fun method_option/0},
      {"FOO -> 200", fun unknown_method/0}
     ]}}.

setup() ->
    code:unstick_mod(gen_fsm),
    MeckModules = [meck_module, gossip_transport, gen_fsm],
    lists:map(fun(Mod) ->
                      meck:new(Mod,[passthrough]),
                      Mod
              end, MeckModules).

setup(Id, Stq, ConInfo, Opts) ->
    Self = self(),
    meck:expect(meck_module, register,
                fun(MeckId, MeckStq, MeckConInfo) ->
                        Self ! {{application,register},
                                {MeckId, MeckStq, MeckConInfo}}
                end),
    meck:expect(meck_module, bye,
                fun(MeckId, MeckStq, MeckConInfo) ->
                        Self ! {{application,bye},
                                {MeckId, MeckStq, MeckConInfo}}
                end),
    meck:expect(meck_module, option,
                fun(MeckId, MeckStq, MeckConInfo) ->
                        Self ! {{application,option},
                                {MeckId, MeckStq, MeckConInfo}}
                end),
    meck:expect(meck_module, cancel,
                fun(MeckId, MeckStq, MeckConInfo) ->
                        Self ! {{application,cancel},
                                {MeckId, MeckStq, MeckConInfo}}
                end),
    meck:expect(meck_module, foo,
                fun(MeckId, MeckStq, MeckConInfo) ->
                        Self ! {{application,foo},
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
    Res = (catch gossip_server_noninv_fsm:start_link(
                   Id, Stq, ConInfo, [meck_module], Opts)),
    ?assertMatch({ok, Pid} when is_pid(Pid), Res),
    Res.

teardown(_) ->
    meck:unload(),
    code:stick_mod(gen_fsm).

sunny_day() ->
    StqReg = stq:new(register, <<"sip:bob@localhost.com">>, {2,0}),
    Stq200 = stq:new(200, <<"OK">>, {2,0}),
    
    {ok, Pid} = setup("id", StqReg, tcp, []),

    %% Check that invite is sent to application
    ?assertMatch({"id", StqReg, tcp}, recv({application,register})),

    ?assertSend(Pid, Stq200),
    TimerJ = recv(timer),
    ?assertMatch({0,timerJ,_}, TimerJ),
    {_,timerJ,Ref} = TimerJ,
    %% Trigger timerJ
    ?assertEqual(ok, gen_fsm:send_event(Pid, {timeout, Ref, timerJ})),
    
    ?assertDown(Pid).

sunny_day_unreliable() ->
    T1 = 10,
    TJ = 64 * T1,
    StqReg = stq:new(register, <<"sip:bob@localhost.com">>, {2,0}),
    Stq200 = stq:new(200, <<"OK">>, {2,0}),
    
    {ok, Pid} = setup("id", StqReg, udp, [{t1, T1}]),

    %% Check that invite is sent to application
    ?assertMatch({"id", StqReg, udp}, recv({application,register})),

    ?assertSend(Pid, Stq200),
    TimerJ = recv(timer),
    ?assertMatch({TJ,timerJ,_}, TimerJ),
    {_,timerJ,Ref} = TimerJ,
    %% Trigger timerJ
    ?assertEqual(ok, gen_fsm:send_event(Pid, {timeout, Ref, timerJ})),
    
    ?assertDown(Pid).

wait_for_100() ->    
    StqReg = stq:new(register, <<"sip:bob@localhost.com">>, {2,0}),
    Stq100 = stq:new(100, <<"Trying">>, {2,0}),
    Stq200 = stq:new(200, <<"OK">>, {2,0}),
    
    {ok, Pid} = setup("id", StqReg, tcp, []),

    %% Check that invite is sent to application
    ?assertMatch({"id", StqReg, tcp}, recv({application,register})),

    ?assertSend(Pid, Stq100),
    ?assertSend(Pid, Stq200),
    TimerJ = recv(timer),
    ?assertMatch({0,timerJ,_}, TimerJ),
    {_,timerJ,Ref} = TimerJ,
    %% Trigger timerJ
    ?assertEqual(ok, gen_fsm:send_event(Pid, {timeout, Ref, timerJ})),

    ?assertDown(Pid).

wait_for_100_unreliable() ->    
    T1 = 10,
    TJ = 64 * T1,
    StqReg = stq:new(register, <<"sip:bob@localhost.com">>, {2,0}),
    Stq100 = stq:new(100, <<"Trying">>, {2,0}),
    Stq200 = stq:new(200, <<"OK">>, {2,0}),
    
    {ok, Pid} = setup("id", StqReg, udp, [{t1, T1}]),

    %% Check that invite is sent to application
    ?assertMatch({"id", StqReg, udp}, recv({application,register})),

    ?assertSend(Pid, Stq100),
    ?assertSend(Pid, Stq200),
    TimerJ = recv(timer),
    ?assertMatch({TJ,timerJ,_}, TimerJ),
    {_,timerJ,Ref} = TimerJ,
    %% Trigger timerJ
    ?assertEqual(ok, gen_fsm:send_event(Pid, {timeout, Ref, timerJ})),

    ?assertDown(Pid).

wait_for_100_retransmit_100() ->    
    StqReg = stq:new(register, <<"sip:bob@localhost.com">>, {2,0}),
    Stq100 = stq:new(100, <<"Trying">>, {2,0}),
    Stq200 = stq:new(200, <<"OK">>, {2,0}),
    
    {ok, Pid} = setup("id", StqReg, tcp, []),

    %% Check that invite is sent to application
    ?assertMatch({"id", StqReg, tcp}, recv({application,register})),

    ?assertSend(Pid, Stq100),
    ?assertSend(Pid, Stq100),
    ?assertSend(Pid, Stq200),
    TimerJ = recv(timer),
    ?assertMatch({0,timerJ,_}, TimerJ),
    {_,timerJ,Ref} = TimerJ,
    %% Trigger timerJ
    ?assertEqual(ok, gen_fsm:send_event(Pid, {timeout, Ref, timerJ})),

    ?assertDown(Pid).

wait_for_100_retransmit_reg() ->
    StqReg = stq:new(register, <<"sip:bob@localhost.com">>, {2,0}),
    Stq100 = stq:new(100, <<"Trying">>, {2,0}),
    Stq200 = stq:new(200, <<"OK">>, {2,0}),
    
    {ok, Pid} = setup("id", StqReg, tcp, []),

    %% Check that invite is sent to application
    ?assertMatch({"id", StqReg, tcp}, recv({application,register})),

    ?assertSend(Pid, Stq100),

    %% Retransmit Register
    gossip_server_noninv_fsm:recv(Pid, StqReg),
    ?assertMatch(Stq100, recv(transport)),
    ?assertEqual(timeout, recv({application, register}, 10)),

    ?assertSend(Pid, Stq200),
    TimerJ = recv(timer),
    ?assertMatch({0,timerJ,_}, TimerJ),
    {_,timerJ,Ref} = TimerJ,
    %% Trigger timerJ
    ?assertEqual(ok, gen_fsm:send_event(Pid, {timeout, Ref, timerJ})),

    ?assertDown(Pid).

retransmit_reg() ->
    StqReg = stq:new(register, <<"sip:bob@localhost.com">>, {2,0}),
    Stq200 = stq:new(200, <<"OK">>, {2,0}),
    
    {ok, Pid} = setup("id", StqReg, tcp, []),

    %% Check that invite is sent to application
    ?assertMatch({"id", StqReg, tcp}, recv({application,register})),

    %% Retransmit Register
    gossip_server_noninv_fsm:recv(Pid, StqReg),
    ?assertEqual(timeout, recv({application, register}, 10)),

    ?assertSend(Pid, Stq200),
    TimerJ = recv(timer),
    ?assertMatch({0,timerJ,_}, TimerJ),
    {_,timerJ,Ref} = TimerJ,
    %% Trigger timerJ
    ?assertEqual(ok, gen_fsm:send_event(Pid, {timeout, Ref, timerJ})),

    ?assertDown(Pid).

retransmit_reg_unreliable() ->
    T1 = 10,
    TJ = 64 * T1,
    StqReg = stq:new(register, <<"sip:bob@localhost.com">>, {2,0}),
    Stq200 = stq:new(200, <<"OK">>, {2,0}),
    
    {ok, Pid} = setup("id", StqReg, udp, [{t1,T1}]),

    %% Check that invite is sent to application
    ?assertMatch({"id", StqReg, udp}, recv({application,register})),

    ?assertSend(Pid, Stq200),

    TimerJ = recv(timer),
    ?assertMatch({TJ,timerJ,_}, TimerJ),
    {_,timerJ,Ref} = TimerJ,

    %% Retransmit Register
    gossip_server_noninv_fsm:recv(Pid, StqReg),
    ?assertMatch(Stq200, recv(transport)),
    ?assertEqual(timeout, recv({application, register}, 10)),

    %% Trigger timerJ
    ?assertEqual(ok, gen_fsm:send_event(Pid, {timeout, Ref, timerJ})),

    ?assertDown(Pid).

transport_error_provisional() ->
    StqReg = stq:new(register, <<"sip:bob@localhost.com">>, {2,0}),
    Stq100 = stq:new(100, <<"Trying">>, {2,0}),
    
    {ok, Pid} = setup("id", StqReg, tcp, []),

    %% Check that invite is sent to application
    ?assertMatch({"id", StqReg, tcp}, recv({application,register})),

    ?assertSend(Pid, Stq100),

    gossip_server_noninv_fsm:transport_error(Pid, fail),
    ?assertMatch({_, fail, _}, recv({application, transport_error})),

    ?assertDown(Pid).

transport_error_final_2xx() ->
    StqReg = stq:new(register, <<"sip:bob@localhost.com">>, {2,0}),
    Stq200 = stq:new(200, <<"OK">>, {2,0}),
    
    {ok, Pid} = setup("id", StqReg, tcp, []),

    %% Check that invite is sent to application
    ?assertMatch({"id", StqReg, tcp}, recv({application,register})),

    ?assertSend(Pid, Stq200),
    ?assertMatch({_, timerJ, _}, recv(timer)),

    gossip_server_noninv_fsm:transport_error(Pid, fail),
    ?assertMatch({_, fail, _}, recv({application, transport_error})),

    ?assertDown(Pid).

method_bye() ->
    Stq = stq:new(bye, <<"sip:bob@localhost.com">>, {2,0}),
    Stq200 = stq:new(200, <<"OK">>, {2,0}),
    
    {ok, Pid} = setup("id", Stq, tcp, []),

    %% Check that invite is sent to application
    ?assertMatch({"id", Stq, tcp}, recv({application,bye})),

    ?assertSend(Pid, Stq200),
    TimerJ = recv(timer),
    ?assertMatch({0,timerJ,_}, TimerJ),
    {_,timerJ,Ref} = TimerJ,
    %% Trigger timerJ
    ?assertEqual(ok, gen_fsm:send_event(Pid, {timeout, Ref, timerJ})),
    
    ?assertDown(Pid).

method_cancel() ->
    Stq = stq:new(cancel, <<"sip:bob@localhost.com">>, {2,0}),
    Stq200 = stq:new(200, <<"OK">>, {2,0}),
    
    {ok, Pid} = setup("id", Stq, tcp, []),

    %% Check that cancel is sent to application
    ?assertMatch({"id", Stq, tcp}, recv({application,cancel})),

    ?assertSend(Pid, Stq200),
    TimerJ = recv(timer),
    ?assertMatch({0,timerJ,_}, TimerJ),
    {_,timerJ,Ref} = TimerJ,
    %% Trigger timerJ
    ?assertEqual(ok, gen_fsm:send_event(Pid, {timeout, Ref, timerJ})),
    
    ?assertDown(Pid).

method_option() ->
    Stq = stq:new(option, <<"sip:bob@localhost.com">>, {2,0}),
    Stq200 = stq:new(200, <<"OK">>, {2,0}),
    
    {ok, Pid} = setup("id", Stq, tcp, []),

    %% Check that invite is sent to application
    ?assertMatch({"id", Stq, tcp}, recv({application,option})),

    ?assertSend(Pid, Stq200),
    TimerJ = recv(timer),
    ?assertMatch({0,timerJ,_}, TimerJ),
    {_,timerJ,Ref} = TimerJ,
    %% Trigger timerJ
    ?assertEqual(ok, gen_fsm:send_event(Pid, {timeout, Ref, timerJ})),
    
    ?assertDown(Pid).

unknown_method() ->
    Stq = stq:new(foo, <<"sip:bob@localhost.com">>, {2,0}),
    Stq200 = stq:new(200, <<"OK">>, {2,0}),
    
    {ok, Pid} = setup("id", Stq, tcp, []),

    %% Check that invite is sent to application
    ?assertMatch({"id", Stq, tcp}, recv({application,foo})),

    ?assertSend(Pid, Stq200),
    TimerJ = recv(timer),
    ?assertMatch({0,timerJ,_}, TimerJ),
    {_,timerJ,Ref} = TimerJ,
    %% Trigger timerJ
    ?assertEqual(ok, gen_fsm:send_event(Pid, {timeout, Ref, timerJ})),
    
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
