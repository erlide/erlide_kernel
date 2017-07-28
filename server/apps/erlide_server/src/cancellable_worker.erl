%%% Implements a worker process that can be canceled and return a partial answers. 

-module(cancellable_worker).

-behaviour(gen_server).

-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

%% ====================================================================
%% API functions
%% ====================================================================

-export([
		 start/2,
		 start/4,
		 cancel/1,
		 get_current_results/1
		]).

%% Start the worker.
%% * WorkerFun computes whatever values are required and reports the results back (using the 
%% given function parameter).
%%  * {chunk, V} reports a partial result (added to the list of previous chunks)
%%  * {value, V} reports the whole result; don't report anything more after this.
%% * Reporter sends the formatted result (can send as message, store in database, etc) as a 
%% tuple {Status, Value}, where Status may be 'done' or 'canceled', in case the client has use
%% for that information; and Value is returned from WorkerFun.
start(WorkerFun, Reporter) ->
	gen_server:start(?MODULE, [WorkerFun, Reporter], []).

start(Module, Function, Args, Reporter) ->
	start(fun() -> apply(Module, Function, Args) end, Reporter).

%% Return the results computed until the current time. Worker proceeds.
get_current_results(Pid) when is_pid(Pid) ->
	gen_server:call(Pid, get_current_results).

%% Cancels the worker. The current results are reported as usual.
cancel(Pid) when is_pid(Pid) ->
	gen_server:cast(Pid, cancel).

%% ====================================================================
%% Behavioural functions
%% ====================================================================
-record(state, {
				slave = undefined,
				results = nothing,
				reporter
			}).

init([WorkerFun, Reporter]) ->
	Parent = self(),
	SlaveReporter = fun(V) ->
			gen_server:cast(Parent, {work, V})
		end,
	{Slave, _Ref} = spawn_monitor(fun() ->
								    WorkerFun(SlaveReporter)
							    end),
	State = #state{slave=Slave, reporter=Reporter},
	{ok, State}.

handle_call(get_current_results, _From, State=#state{results={partial, _Results}=Results}) ->
	{reply, {ok, prepare(Results)}, State};
handle_call(get_current_results, _From, State=#state{results={value, _Results}=Results}) ->
	{reply, {ok, Results}, State};
handle_call(get_current_results, _From, State=#state{results=nothing}) ->
	{reply, {ok, nothing}, State};
handle_call(Request, _From, State) ->
	io:format("Unexpected call in cancelable_worker: ~p~n", [Request]),
	Reply = {error, {unknown, Request}},
	{reply, Reply, State}.

handle_cast(cancel, State=#state{slave=Pid}) when is_pid(Pid) ->
	exit(Pid, kill),
	{noreply, State};
handle_cast({work, {chunk, V}}, State=#state{results=nothing}) ->
	{noreply, State#state{results={partial, [V]}}};
handle_cast({work, {chunk, V}}, State=#state{results={partial, Results}}) when is_list(Results) ->
	{noreply, State#state{results={partial, [V|Results]}}};
handle_cast({work, {value, V}}, State) ->
	{noreply, State#state{results={value, V}}};
handle_cast(_Msg, State) ->
	io:format("Unexpected cast in cancelable_worker: ~p~n", [_Msg]),
	{noreply, State}.

handle_info({'DOWN', _, process, Pid, Reason},
						State=#state{slave=Pid, results=nothing, 
						reporter=Reporter}) ->
	Status = case Reason of normal -> done; killed -> canceled end,
	Reporter({Status, nothing}),
	{stop, normal, State#state{slave=undefined}};
handle_info({'DOWN', _, process, Pid, Reason},
						State=#state{slave=Pid, results=Results, 
						reporter=Reporter}) ->
	Status = case Reason of normal -> done; killed -> canceled end,
	Reporter({Status, prepare(Results)}),
	{stop, normal, State#state{slave=undefined}};
handle_info(_Info, State) ->
	io:format("Unexpected message in cancelable_worker: ~p~n~p~n", [_Info, State]),
	{noreply, State}.

terminate(_Reason, _State) ->
	ok.

code_change(_OldVsn, State, _Extra) ->
	{ok, State}.

%% ====================================================================
%% Internal functions
%% ====================================================================

prepare({partial, V}) ->
	lists:reverse(V);
prepare({value, V}) ->
	V;
prepare(V) ->
	V.
