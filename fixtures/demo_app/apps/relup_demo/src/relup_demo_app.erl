%%%-------------------------------------------------------------------
%% @doc relup_demo public API
%% @end
%%%-------------------------------------------------------------------

-module(relup_demo_app).

-behaviour(application).

-export([start/2, stop/1]).

start(_StartType, _StartArgs) ->
    relup_demo_sup:start_link().

stop(_State) ->
    ok.

%% internal functions
