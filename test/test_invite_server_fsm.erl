%% -*- tab-width: 4;erlang-indent-level: 4;indent-tabs-mode: nil -*-

-module(test_invite_server_fsm).

-compile(export_all).

-include_lib("eunit/include/eunit.hrl").

invite_test_() ->
    {foreach, fun setup/0, fun teardown/1, [fun sunny_day/1,
                                            fun wait_for_100/1,
                                            fun wait_for_100_retransmit_inv/1]}.

setup() ->

    MeckModules = [meck_module, gossip_transport],
    lists:foreach(fun meck:new/1, MeckModules).

setup(Id, Stq, ConInfo, Opts) ->
    Self = self(),
    meck:expect(meck_module, invite, fun(MeckId, MeckStq, MeckConInfo) ->
                                             Self ! {MeckId, MeckStq, MeckConInfo}
                                     end),
    meck:expect(gossip_transport, send, fun(phony, MeckStq) ->
                                                Self ! MeckStq
                                        end),
    Res = (catch gossip_server_inv_fsm:start_link(Id, Stq, ConInfo, [meck_module], Opts)),
    ?assertMatch({ok, Pid} when is_pid(Pid), Res),
    Res.

teardown(_) ->
    io:format(user, "teardown", []),
    meck:unload().

sunny_day(_) ->
    Stq = stq:new(invite, <<"sip:bob@localhost.com">>, {2,0}),
    Stq200 = stq:new(200, <<"OK">>, {2,0}),
    
    {ok, Pid} = setup("sunny_day", Stq, phony, []),

    %% Check that invite is sent to application
    ?assertMatch({"sunny_day", Stq, phony}, recv()),

    gossip_server_inv_fsm:send(Pid, Stq200),

    ?assertMatch(Stq200, recv()),
    ?assertEqual(timeout, recv(1)),
    
    ok.

wait_for_100(_) ->
    
    Stq = stq:new(invite, <<"sip:bob@localhost.com">>, {2,0}),
    Stq200 = stq:new(200, <<"OK">>, {2,0}),
    
    {ok, Pid} = setup("sunny_day", Stq, phony, []),

    %% Check that invite is sent to application
    ?assertMatch({"sunny_day", Stq, phony}, recv()),

    Stq100 = recv(300),
    ?assertEqual(response, stq:type(Stq100)),
    ?assertEqual(100, stq:code(Stq100)),
    
    gossip_server_inv_fsm:send(Pid, Stq200),

    ?assertMatch(Stq200, recv()),
    ?assertEqual(timeout, recv(1)),
    
    ok.

wait_for_100_retransmit_inv(_) ->
    
    StqInv = stq:new(invite, <<"sip:bob@localhost.com">>, {2,0}),
    Stq200 = stq:new(200, <<"OK">>, {2,0}),
    
    {ok, Pid} = setup("sunny_day", StqInv, phony, []),

    %% Check that invite is sent to application
    ?assertMatch({"sunny_day", StqInv, phony}, recv()),

    Stq100 = recv(300),
    ?assertEqual(response, stq:type(Stq100)),
    ?assertEqual(100, stq:code(Stq100)),

    gossip_server_inv_fsm:recv(Pid, StqInv),

    Stq100Retrans = recv(),
    ?assertEqual(response, stq:type(Stq100Retrans)),
    ?assertEqual(100, stq:code(Stq100Retrans)),
    
    gossip_server_inv_fsm:send(Pid, Stq200),

    ?assertMatch(Stq200, recv()),
    ?assertEqual(timeout, recv(1)),
    
    ok.

recv() ->
    recv(200).
recv(TO) ->
    receive
        Msg ->
            Msg
    after TO ->
            timeout
    end.
