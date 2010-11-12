%% @author Petter Sandholdt <petter@sandholdt.se>
%% @copyright 2010
%% @doc Transaction finder and creator module
%%
%% This module contains functionality for the fransport to find an
%% transaction FSM or if it does not exist to create one.
%%
%% The way to match an transaction is according to RFC 3216 17.2.3.

-module(gossip_transaction).
-include_lib("gossip.hrl").
-include_lib("esessin/src/stq.hrl").

-export([get_transaction_id/1]).

%% @doc Get a transaction id from an STQ
-spec get_transaction_id(stq_opaque()) -> transaction_id().
get_transaction_id(STQ) ->
    case stq:header('Via', STQ) of
	[{TopVia, _}|_] ->
	    case param(<<"branch">>, TopVia) of
		<<"z9hG4bK",_Rest/binary>> = Branch ->
		    %% Compliant with RFC 3216
		    SentBy = param(sent_by, TopVia),
		    Method = case stq:method(STQ) of
				 ack -> invite;
				 M -> M
			     end,
		    {Branch, SentBy, Method};
		Branch ->
		    %% Not compliant 
		    %% TODO: fallback to RFC 2543 
		    {error, {non_compliant_branch, Branch}}
	    end;
	_ ->
	    %% Missing Via header
	    %% TODO: fallback to RFC 2543 
	    {error, missing_via_header}
    end.

param(sent_by, Header) ->
    {SentBy, _Params}=Header,
    SentBy;
param(Param, Header) ->
    {_SentBy, Params}=Header,
    proplists:get_value(Param, Params).
