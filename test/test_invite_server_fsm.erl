%% -*- tab-width: 4;erlang-indent-level: 4;indent-tabs-mode: nil -*-

-module(test_invite_server_fsm).

-compile(export_all).

-include_lib("eunit/include/eunit.hrl").

invite_test_() ->
    {setup, fun setup/0, fun teardown/1, [fun sunny_day/0,
                                          fun wait_for_100/0,
                                          fun wait_for_100_retransmit_inv/0]}.

setup() ->
    MeckModules = [meck_module, gossip_transport],
    lists:foreach(fun meck:new/1, MeckModules),
    MeckModules.

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
    {ok, Pid} = Res,
    unlink(Pid),
    Res.

teardown(_) ->
    meck:unload().

sunny_day() ->
    Stq = stq:new(invite, <<"sip:bob@localhost.com">>, {2,0}),
    Stq200 = stq:new(200, <<"OK">>, {2,0}),
    
    {ok, Pid} = setup("sunny_day", Stq, phony, []),

    %% Check that invite is sent to application
    ?assertMatch({"sunny_day", Stq, phony}, recv()),

    ?assertEqual(ok, gossip_server_inv_fsm:send(Pid, Stq200)),

    ?assertMatch(Stq200, recv()),
    erlang:monitor(process, Pid),
    ?assertMatch({'DOWN',_,_,_,_}, recv()),
    
    ok.

wait_for_100() ->
    
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

wait_for_100_retransmit_inv() ->
    
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
