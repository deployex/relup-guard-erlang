-module(relup_worker2).
-behaviour(gen_server).

%% Deliberately a new module with no corresponding apply instruction in
%% its appup - see the fail-on-relup-warnings self-test job in
%% .github/workflows/ci.yml for why this exists.
%%
%% Not wired into relup_demo_sup's own child list, unlike the Elixir
%% fixture's equivalent (RelupDemo.Worker2 there IS a supervisor child):
%% rebar3_appup_plugin's own automatic "did a supervisor's children
%% change" detection crashes outright on a plain init/1 child-spec list
%% (function_clause on {error, no_abstract_code}), so adding this as a
%% supervised child would make `rebar3 appup generate` itself fail
%% before relup-guard-erlang ever gets a chance to run. A standalone
%% module that nothing starts reaches the same gap this fixture needs -
%% new code added to the release with no apply instruction anywhere to
%% actually run it - without touching the supervisor at all.

-export([start_link/0, ping/0]).
-export([init/1, handle_call/3, handle_cast/2]).

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

ping() ->
    gen_server:call(?MODULE, ping).

init([]) ->
    {ok, []}.

handle_call(ping, _From, State) ->
    {reply, pong, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.
