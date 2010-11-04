%% @author Petter Sandholdt <petter@sandholdt.se>
%% @copyright 2010
%% 
%%   INVITE Server transaction FSM
%%
%%                                |INVITE
%%                                |pass INV to TU
%%             INVITE             V send 100 if TU won't in 200ms
%%             send response+-----------+
%%                 +--------|           |--------+101-199 from TU
%%                 |        | Proceeding|        |send response
%%                 +------->|           |<-------+
%%                          |           |          Transport Err.
%%                          |           |          Inform TU
%%                          |           |--------------->+
%%                          +-----------+                |
%%             300-699 from TU |     |2xx from TU        |
%%             send response   |     |send response      |
%%                             |     +------------------>+
%%                             |                         |
%%             INVITE          V          Timer G fires  |
%%             send response+-----------+ send response  |
%%                 +--------|           |--------+       |
%%                 |        | Completed |        |       |
%%                 +------->|           |<-------+       |
%%                          +-----------+                |
%%                             |     |                   |
%%                         ACK |     |                   |
%%                         -   |     +------------------>+
%%                             |        Timer H fires    |
%%                             V        or Transport Err.|
%%                          +-----------+  Inform TU     |
%%                          |           |                |
%%                          | Confirmed |                |
%%                          |           |                |
%%                          +-----------+                |
%%                                |                      |
%%                                |Timer I fires         |
%%                                |-                     |
%%                                |                      |
%%                                V                      |
%%                          +-----------+                |
%%                          |           |                |
%%                          | Terminated|<---------------+
%%                          |           |
%%                          +-----------+
%%
%%               Figure 7: INVITE server transaction
%%
-module(gossip_server_inv_fsm).

-behaviour(gen_fsm).
-include_lib("gossip.hrl").
-include_lib("esessin/src/stq.hrl").

%% API
-export([start_link/5, send/2, recv/2, transport_error/2]).

%% gen_fsm callbacks
-export([init/1, proceeding/2, completed/2, confirmed/2, handle_event/3,
	 handle_sync_event/4, handle_info/3, terminate/3, code_change/4]).

-record(state, { id :: transaction_id(), 
		 con :: connection_info(), 
		 resp_stq :: stq_opaque() | undefined,
		 callback_modules = [] :: list(atom())}).

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
    gen_fsm:send_event(Pid, {transport_error, Reason}).

%%====================================================================
%% gen_fsm callbacks
%%====================================================================
%% @doc Initial state, sends INVITE to user and moves to Proceeding state
-spec init({transaction_id(), stq_opaque(), 
	    connection_info(), Opts :: term()}) -> 
    {ok, StateName :: atom(), State :: #state{}} |
	{ok, StateName :: atom(), State :: #state{}, Timeout :: integer()} |
	ignore | {stop, StopReason :: term()}.
init({Id, STQ, Con, CallBackMods, _Opts}) ->
    call(CallBackMods, invite, [Id, STQ, Con]),
    {ok, proceeding, #state{id = Id, con = Con, 
			    callback_modules = CallBackMods}, 200}.

%% @doc Proceeding state, waiting for user to send response to network, 
%%      and move to Completed state
-spec proceeding(Event :: term(), State :: #state{}) -> 
    {next_state, NextStateName :: atom(), NextState :: #state{}} |
	{next_state, NextStateName :: atom(), NextState :: #state{},
	 Timeout :: integer()} |
	{stop, Reason :: term(), NewState :: atom()}.
proceeding(timeout, State = #state{con = Con}) ->
    %% Nothing sent from user in 200 ms, send a 100 Trying to network
    TryingSTQ = stq:new(100,<<"Trying">>, {2,0}),
    gossip_transport:send(Con, TryingSTQ),
    {next_state, proceeding, State#state{resp_stq = TryingSTQ}};
proceeding({recv, STQ}, State = #state{con = Con, resp_stq = RespSTQ}) 
  when RespSTQ =/= undefined->
    case stq:method(STQ) of
	invite ->
	    %% ReReceived an INVITE, resend last provisional response
	    gossip_transport:send(Con, RespSTQ),
	    {next_state, proceeding, State};
	_ ->
	    %% Ignore other messages receivied
	    {next_state, proceeding, State}
    end;
proceeding({send, STQ}, State = #state{con = Con}) ->
    %% User sending an response to network, send it
    gossip_transport:send(Con, STQ),
    case stq:code(STQ) of
	Code when Code >= 101, Code =< 199 -> 
	    %% Provisional response, store and keep state
	    {next_state, proceeding, State#state{resp_stq=STQ}};
	Code when Code >= 300, Code =< 699 -> 
	    %% Final response which we will recieve ACK for
	    %% TODO: Start Timer G
	    {next_state, completed, State#state{resp_stq=STQ}};
	Code when Code >= 200, Code =< 299 -> 
	    %% Final ok response, shut down
	    {stop, normal, State}
    end;
proceeding({transport_error, Reason}, 
	   State = #state{id = Id, con=Con, callback_modules = CallBackMods}) ->
    %% Transport error from network, send to user
    call(CallBackMods, transport_error, [Id, Reason, Con]),
    {stop, Reason, State}.

%% @doc Completed state, waiting for ACK from network to move to Confirmed state
-spec completed(Event :: term(), State :: #state{}) -> 
    {next_state, NextStateName :: atom(), NextState :: #state{}} |         
	{next_state,NextStateName :: atom(),NextState :: #state{},
	 Timeout::integer()} |
	{stop, Reason :: term(), NewState :: atom()}.
completed({timeout, timerG}, State) ->
    %% resend last resp_stq
    %% restart timerG
    {next_state, completed, State};
completed({timeout, timerH}, State) ->
    %% resend last resp_stq
    {stop, normal, State};
completed({recv, STQ}, State = #state{id = Id, con = Con, 
				      resp_stq = RespSTQ,
				      callback_modules=CallBackMods}) ->
    %% Received message from network
    case stq:method(STQ) of
	ack ->
	    %% Send ACK to user
	    call(CallBackMods, ack, [Id, STQ, Con]),
	    {next_state, confirmed, State};
	invite ->
	    %% ReReceived an INVITE, resend last response
	    gossip_transport:send(Con, RespSTQ),
	    {next_state, completed, State};
	_ ->
	    %% Other messages are ignored
	    {next_state, completed, State}
    end;
completed({transport_error, Reason}, 
	  State = #state{id = Id, con=Con, callback_modules = CallBackMods}) ->
    %% Transport error from network, send to user
    call(CallBackMods, transport_error, [Id, Reason, Con]),
    {stop, Reason, State}.

%% @doc Confirmed state, waiting timerI and shutdown
-spec confirmed(Event :: term(), State::#state{}) -> 
    {next_state, NextStateName :: atom(), NextState :: #state{}} |         
	{next_state,NextStateName :: atom(),NextState :: #state{},
	 Timeout::integer()} |
	{stop, Reason :: term(), NewState :: atom()}.
confirmed({timeout, timerI}, State) ->
    {stop, normal, State}.

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
handle_event(_Event, StateName, State) ->
    {next_state, StateName, State}.

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
