-module(relup_worker).
-behaviour(gen_server).

-export([start_link/0, counter/0]).
-export([init/1, handle_call/3, handle_cast/2]).

-record(state, {counter = 0}).

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

counter() ->
    gen_server:call(?MODULE, counter).

init([]) ->
    {ok, #state{}}.

handle_call(counter, _From, State) ->
    {reply, State#state.counter, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.
