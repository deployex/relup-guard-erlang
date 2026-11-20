-module(relup_stuck_worker).
-behaviour(gen_server).

%% Deliberately gets stuck forever inside handle_cast, right after boot -
%% see the upgrade-timeout-seconds self-test job in
%% .github/workflows/ci.yml for why this exists, and why it lives on the
%% fixtures/stuck-worker branch rather than main.
%%
%% gen_server only answers :sys system messages (like the suspend request
%% release_handler sends before a code_change) between callback
%% invocations, not while one is still running. A plain receive with no
%% matching clause, inside a callback that never returns, blocks that
%% forever: the suspend request just sits in this process's mailbox,
%% unanswered, since control never goes back to gen_server's own loop to
%% notice it.
%%
%% A supervised child, not started any other way: release_handler only
%% attempts to suspend processes it can discover by walking the
%% supervision tree, so a process started any other way (a plain spawn,
%% or linked straight from the application callback outside any
%% supervisor) is never targeted by an {update, Mod, ...} instruction at
%% all, and install_release succeeds trivially instead of ever
%% attempting - let alone failing - to suspend it. Kept supervised
%% identically across both versions of this fixture, so relup_demo_sup's
%% own module never changes between them: rebar3_appup_plugin's own
%% supervisor-child-diffing crashes on any CHANGED module tagged
%% -behaviour(supervisor), not specifically on added or removed
%% children, so a supervisor whose own file is byte-for-byte identical
%% between old-ref and new-ref never reaches that code path at all.

-export([start_link/0]).
-export([init/1, handle_call/3, handle_cast/2, code_change/3]).

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

init([]) ->
    gen_server:cast(self(), get_stuck),
    {ok, []}.

handle_call(_Msg, _From, State) ->
    {reply, ok, State}.

handle_cast(get_stuck, State) ->
    receive
    after infinity -> ok
    end,
    {noreply, State}.

%% Elixir's `use GenServer` macro injects a default code_change/3 for
%% every GenServer module whether the author writes one or not; plain
%% Erlang gen_server has no such injection. Without this function,
%% rebar3_appup_plugin's own is_code_change/1 check finds no code_change
%% export and emits a plain {load_module, ...} instead of {update, Mod,
%% {advanced, []}, ...} - a load_module never suspends anything at all,
%% so the upgrade would "succeed" instantly rather than ever attempting
%% the suspend this fixture exists to block.
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.
