-module(gossip_lib).

-export([gen_response_from_request/3]).

gen_response_from_request(Code, Msg, _STQ) ->
    stq:new(Code, Msg, {2,0}).
