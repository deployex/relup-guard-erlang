-module(relup_worker).
-behaviour(gen_server).

-export([start_link/0, counter/0, label/0]).
-export([init/1, handle_call/3, handle_cast/2, code_change/3]).

-record(state, {counter = 0, label = "v2"}).

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

counter() ->
    gen_server:call(?MODULE, counter).

label() ->
    gen_server:call(?MODULE, label).

init([]) ->
    {ok, #state{}}.

handle_call(counter, _From, State) ->
    {reply, State#state.counter, State};
handle_call(label, _From, State) ->
    {reply, State#state.label, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

code_change(_OldVsn, {state, Counter}, _Extra) ->
    {ok, #state{counter = Counter, label = "v2"}}.
