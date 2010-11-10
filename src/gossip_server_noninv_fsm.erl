%% @author Petter Sandholdt <petter@sandholdt.se>
%% @copyright 2010
%% @doc NON-INVITE Server transaction FSM

%%                                   |Request received
%%                                   |pass to TU
%%                                   V
%%                             +-----------+
%%                             |           |
%%                             | Trying    |-------------+
%%                             |           |             |
%%                             +-----------+             |200-699 from TU
%%                                   |                   |send response
%%                                   |1xx from TU        |
%%                                   |send response      |
%%                                   |                   |
%%                Request            V      1xx from TU  |
%%                send response+-----------+send response|
%%                    +--------|           |--------+    |
%%                    |        | Proceeding|        |    |
%%                    +------->|           |<-------+    |
%%             +<--------------|           |             |
%%             |Trnsprt Err    +-----------+             |
%%             |Inform TU            |                   |
%%             |                     |                   |
%%             |                     |200-699 from TU    |
%%             |                     |send response      |
%%             |  Request            V                   |
%%             |  send response+-----------+             |
%%             |      +--------|           |             |
%%             |      |        | Completed |<------------+
%%             |      +------->|           |
%%             +<--------------|           |
%%             |Trnsprt Err    +-----------+
%%             |Inform TU            |
%%             |                     |Timer J fires
%%             |                     |-
%%             |                     |
%%             |                     V
%%             |               +-----------+
%%             |               |           |
%%             +-------------->| Terminated|
%%                             |           |
%%                             +-----------+
%%
%%                 Figure 8: non-INVITE server transaction
-module(gossip_server_noninv_fsm).

-behaviour(gen_fsm).
-include_lib("gossip.hrl").
-include_lib("gossip_internal.hrl").
-include_lib("esessin/src/stq.hrl").

%% API
-export([start_link/5, send/2, recv/2, transport_error/2]).

%% gen_fsm callbacks
-export([init/1, trying/2, proceeding/2, completed/2, handle_event/3,
	 handle_sync_event/4, handle_info/3, terminate/3, code_change/4]).

-record(state, { id :: transaction_id(), 
		 con :: connection_info(), 
		 resp_stq :: stq_opaque() | undefined,
		 callback_modules = [] :: list(atom()),
		 timer1 :: integer()}).

%%====================================================================
%% API
%%====================================================================
%% @doc Start an FSM for this transaction
-spec start_link(transaction_id(), stq_opaque(), 
		 connection_info(), list(atom()), Opts :: term()) -> 
    {ok, pid()} | ignore | {error, Reason :: term()}.
start_link(Id, STQ, Con, CallBackMods, Opts) ->
    gen_fsm:start_link(?MODULE, {Id, STQ, Con, CallBackMods, Opts}, []).

%% @doc Send an STQ to the network
-spec send(pid(), stq_opaque()) -> ok.
send(Pid, STQ) -> 
    gen_fsm:send_event(Pid, {send, STQ}).
    
%% @doc Receive an STQ from the network
-spec recv(pid(), stq_opaque()) -> ok.
recv(Pid, STQ) -> 
    gen_fsm:send_event(Pid, {recv, STQ}).

%% @doc Receive an transport error from the network
-spec transport_error(pid(), Reason :: term()) -> ok.
transport_error(Pid, Reason) -> 
    gen_fsm:send_all_state_event(Pid, {transport_error, Reason}).

%%====================================================================
%% gen_fsm callbacks
%%====================================================================
%% @doc Initial state, sends INVITE to user and moves to Proceeding state
-spec init({transaction_id(), stq_opaque(), 
	    connection_info(),list(atom()), Opts :: term()}) -> 
    {ok, StateName :: atom(), State :: #state{}}.
init({Id, STQ, Con, CallBackMods, Opts}) ->
    Method = stq:method(STQ),
    call(CallBackMods, Method, [Id, STQ, Con]),
    T1 = proplists:get_value(t1, Opts, ?Timer1_default),
    {ok, trying, #state{id = Id, con = Con, 
			callback_modules = CallBackMods,
			timer1 = T1}}.

%% @doc Trying state, waiting for TU to send response to network, 
%%      and move to Proceeding state
-spec trying(Event :: term(), State :: #state{}) -> 
    {next_state, NextStateName :: atom(), NextState :: #state{}}.
trying({recv, _STQ}, State) ->
    %% Ignore other messages receivied
    {next_state, trying, State};
trying({send, STQ}, State = #state{con = Con, timer1 = T1}) ->
    %% TU sending an response to network, send it
    gossip_transport:send(Con, STQ),
    case stq:code(STQ) of
	Code when Code >= 100, Code =< 199 -> 
	    %% Provisional response, store and keep state
	    {next_state, proceeding, State#state{resp_stq=STQ}};
	Code when Code >= 200, Code =< 699 -> 
	    %% Final response
	    TJ = case reliable_transport(Con) of
			 true -> 0;
			 false -> 64 * T1
		     end,
	    gen_fsm:start_timer(TJ, timerJ),
	    {next_state, completed, State#state{resp_stq=STQ}}
    end.

%% @doc Proceeding state, waiting for final response from TU
%%      and move to Completed state
-spec proceeding(Event :: term(), State :: #state{}) -> 
    {next_state, NextStateName :: atom(), NextState :: #state{}}.
proceeding({recv, _STQ}, State = #state{con = Con, resp_stq = RespSTQ}) ->
    %% ReReceived request, resend last provisional response
    gossip_transport:send(Con, RespSTQ),
    {next_state, proceeding, State};
proceeding({send, STQ}, State = #state{con = Con, timer1 = T1}) ->
    %% TU sending an response to network, send it
    gossip_transport:send(Con, STQ),
    case stq:code(STQ) of
	Code when Code >= 100, Code =< 199 -> 
	    %% Provisional response, store and keep state
	    {next_state, proceeding, State#state{resp_stq=STQ}};
	Code when Code >= 200, Code =< 699 -> 
	    TJ = case reliable_transport(Con) of
			 true -> 0;
			 false -> 64 * T1
		     end,
	    gen_fsm:start_timer(TJ, timerJ),
	    {next_state, completed, State#state{resp_stq=STQ}}
    end.

%% @doc Completed state, waiting timerJ to terminate
-spec completed(Event :: term(), State :: #state{}) -> 
    {next_state, NextStateName :: atom(), NextState :: #state{}} |         
	{stop, Reason :: term(), NewState :: atom()}.
completed({timeout, _Ref, timerJ}, State) ->
    %% Terminate
    {stop, normal, State};
completed({recv, _STQ}, State = #state{con = Con, resp_stq = RespSTQ}) ->
    %% ReReceived request, resend last response
    gossip_transport:send(Con, RespSTQ),
    {next_state, completed, State}.

%%--------------------------------------------------------------------
%% Function: 
%% handle_event(Event, StateName, State) -> {next_state, NextStateName, 
%%						  NextState} |
%%                                          {next_state, NextStateName, 
%%					          NextState, Timeout} |
%%                                          {stop, Reason, NewState}
%% Description: Whenever a gen_fsm receives an event sent using
%% gen_fsm:send_all_state_event/2, this function is called to handle
%% the event.
%%--------------------------------------------------------------------
handle_event({transport_error, Reason}, _StateName, 
	     State = #state{id = Id, con=Con, 
			    callback_modules = CallBackMods}) ->
    %% TODO: Implement 3263 handling for retry sending to other server
    %% Transport error from network, send to user
    call(CallBackMods, transport_error, [Id, Reason, Con]),
    {stop, normal, State}.

%%--------------------------------------------------------------------
%% Function: 
%% handle_sync_event(Event, From, StateName, 
%%                   State) -> {next_state, NextStateName, NextState} |
%%                             {next_state, NextStateName, NextState, 
%%                              Timeout} |
%%                             {reply, Reply, NextStateName, NextState}|
%%                             {reply, Reply, NextStateName, NextState, 
%%                              Timeout} |
%%                             {stop, Reason, NewState} |
%%                             {stop, Reason, Reply, NewState}
%% Description: Whenever a gen_fsm receives an event sent using
%% gen_fsm:sync_send_all_state_event/2,3, this function is called to handle
%% the event.
%%--------------------------------------------------------------------
handle_sync_event(_Event, _From, StateName, State) ->
    Reply = ok,
    {reply, Reply, StateName, State}.

%%--------------------------------------------------------------------
%% Function: 
%% handle_info(Info,StateName,State)-> {next_state, NextStateName, NextState}|
%%                                     {next_state, NextStateName, NextState, 
%%                                       Timeout} |
%%                                     {stop, Reason, NewState}
%% Description: This function is called by a gen_fsm when it receives any
%% other message than a synchronous or asynchronous event
%% (or a system message).
%%--------------------------------------------------------------------
handle_info(_Info, StateName, State) ->
    {next_state, StateName, State}.

%%--------------------------------------------------------------------
%% Function: terminate(Reason, StateName, State) -> void()
%% Description:This function is called by a gen_fsm when it is about
%% to terminate. It should be the opposite of Module:init/1 and do any
%% necessary cleaning up. When it returns, the gen_fsm terminates with
%% Reason. The return value is ignored.
%%--------------------------------------------------------------------
terminate(_Reason, _StateName, _State) ->
    ok.

%%--------------------------------------------------------------------
%% Function:
%% code_change(OldVsn, StateName, State, Extra) -> {ok, StateName, NewState}
%% Description: Convert process state when code is changed
%%--------------------------------------------------------------------
code_change(_OldVsn, StateName, State, _Extra) ->
    {ok, StateName, State}.

%%--------------------------------------------------------------------
%%% Internal functions
%%--------------------------------------------------------------------
call([], _Fun, _Args) ->
    ok;
call([Mod | T], Fun, Args) ->
    apply(Mod, Fun, Args),
    call(T, Fun, Args).

reliable_transport(Con) ->
    case gossip_transport:type(Con) of
	tcp ->
	    true;
	_ ->
	    false
    end.
