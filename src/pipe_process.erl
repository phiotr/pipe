%%
%%   Copyright (c) 2012 - 2013, Dmitry Kolesnikov
%%   Copyright (c) 2012 - 2013, Mario Cardona
%%   All Rights Reserved.
%%
%%   Licensed under the Apache License, Version 2.0 (the "License");
%%   you may not use this file except in compliance with the License.
%%   You may obtain a copy of the License at
%%
%%       http://www.apache.org/licenses/LICENSE-2.0
%%
%%   Unless required by applicable law or agreed to in writing, software
%%   distributed under the License is distributed on an "AS IS" BASIS,
%%   WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%%   See the License for the specific language governing permissions and
%%   limitations under the License.
%%
%% @description
%%    pipe process container
-module(pipe_process).
-behaviour(gen_server).
-include("pipe.hrl").

-export([
   init/1, 
   terminate/2,
   handle_call/3,
   handle_cast/2,
   handle_info/2,
   code_change/3
]).

%% internal state
-record(machine, {
   mod   = undefined :: atom()  %% FSM implementation
  ,sid   = undefined :: atom()  %% FSM state (transition function)
  ,state = undefined :: any()   %% FSM internal data structure
  ,a     = undefined :: pid()   %% pipe side (a) // source
  ,b     = undefined :: pid()   %% pipe side (b) // sink

  ,rate    = undefined :: integer() %% max execution rate 
  ,period  = undefined :: integer() %% period
  ,tick    = undefined :: integer() %% current execution 
  ,time    = undefined :: any()     %% deadline for current period  
}).

%%%----------------------------------------------------------------------------   
%%%
%%% Factory
%%%
%%%----------------------------------------------------------------------------   

init([Mod, Args, Opts]) ->
   case lists:keyfind(rate, 1, Opts) of
      false ->
         init(Mod:init(Args), #machine{mod=Mod});
      {_, {Rate, Period}} ->
         init(Mod:init(Args),
            #machine{
               mod    = Mod
              ,rate   = Rate
              ,period = Period
              ,tick   = 0
              ,time   = next_period(Period)
            }
         )
   end.

init({ok, Sid, State}, S) ->
   {ok, S#machine{sid=Sid, state=State}};
init({error,  Reason}, _) ->
   {stop, Reason}.   

terminate(Reason, #machine{mod=Mod}=S) ->
   Mod:free(Reason, S#machine.state).   

%%%----------------------------------------------------------------------------   
%%%
%%% gen_server
%%%
%%%----------------------------------------------------------------------------   

%%
%%
handle_call(Msg, Tx, #machine{}=S) ->
   % synchronous out-of-bound call to machine   
   ?DEBUG("pipe call ~p: tx ~p, msg ~p~n", [self(), Tx, Msg]),
   run(Msg, make_pipe(Tx, S#machine.a, S#machine.b), S).

%%
%%
handle_cast(_, S) ->
   {noreply, S}.

%%
%%
handle_info({'$pipe', Tx, {ioctl, a, Pid}}, S) ->
   ?DEBUG("pipe ~p: bind a to ~p", [self(), Pid]),
   pipe:ack(Tx, {ok, S#machine.a}),
   {noreply, S#machine{a=Pid}};
handle_info({'$pipe', Tx, {ioctl, a}}, S) ->
   pipe:ack(Tx, {ok, S#machine.a}),
   {noreply, S};

handle_info({'$pipe', Tx, {ioctl, b, Pid}}, S) ->
   ?DEBUG("pipe ~p: bind b to ~p", [self(), Pid]),
   pipe:ack(Tx, {ok, S#machine.b}),
   {noreply, S#machine{b=Pid}};
handle_info({'$pipe', Tx, {ioctl, b}}, S) ->
   pipe:ack(Tx, {ok, S#machine.b}),
   {noreply, S};

handle_info({'$pipe', Tx, {ioctl, rate, {Rate, Period}}}, S) ->
   ?DEBUG("pipe ~p: execution rate ~p", [self(), Rate]),
   pipe:ack(Tx, ok),
   {noreply, 
      S#machine{
         rate   = Rate
        ,period = Period
        ,tick   = 0
        ,time   = next_period(Period)
      }
   };


handle_info({'$pipe', Tx, {ioctl, Req, Val}}, #machine{mod=Mod}=S) ->
   % ioctl set request
   ?DEBUG("pipe ioctl ~p: req ~p, val ~p~n", [self(), Req, Val]),
   try
      pipe:ack(Tx, ok),
      {noreply, S#machine{state = Mod:ioctl({Req, Val}, S#machine.state)}}
   catch _:_ ->
      pipe:ack(Tx, ok),
      {noreply, S}
   end;

handle_info({'$pipe', Tx, {ioctl, Req}}, #machine{mod=Mod}=S) ->
   % ioctl get request
   ?DEBUG("pipe ioctl ~p: req ~p~n", [self(), Req]),
   try
      pipe:ack(Tx, Mod:ioctl(Req, S#machine.state)),
      {noreply, S}
   catch _:_ ->
      pipe:ack(Tx, undefined),
      {noreply, S}
   end;

handle_info({'$pipe', _Pid, '$free'}, S) ->
   ?DEBUG("pipe ~p: free", [self()]),
   {stop, normal, S};

handle_info({'$flow', Pid, D}, S) ->
   ?FLOW_CTL(Pid, ?DEFAULT_CREDIT_A, C,
      erlang:min(?DEFAULT_CREDIT_A, C + D)
   ),
   {noreply, S};

handle_info({'$pipe', Tx, Msg}, #machine{}=S) ->   
   %% in-bound call to FSM
   ?DEBUG("pipe recv ~p: tx ~p, msg ~p~n", [self(), Tx, Msg]),
   run(Msg, make_pipe(Tx, S#machine.a, S#machine.b), S);

handle_info(Msg, #machine{}=S) ->
   %% out-of-bound message
   ?DEBUG("pipe recv ~p: msg ~p~n", [self(), Msg]),
   run(Msg, {pipe, S#machine.a, S#machine.b}, S).

%%
%%
code_change(_Vsn, S, _) ->
   {ok, S}.

%%%----------------------------------------------------------------------------   
%%%
%%% private
%%%
%%%----------------------------------------------------------------------------   

%%
%% make pipe definition
make_pipe(Tx, A, B)
 when Tx =:= A ->
   {pipe, A, B};
make_pipe(Tx, A, B)
 when Tx =:= B ->
   {pipe, B, A};
make_pipe(Tx, undefined, B) ->
   {pipe, Tx, B};
make_pipe(Tx, A, _B) ->
   {pipe, Tx, A}.


next_period(T) ->
   {A0, B0, C0} = os:timestamp(),
   {C1, Q0} = add_time(C0, T),
   {B1, Q1} = add_time(B0, Q0),
   {A1,  _} = add_time(A0, Q1),
   {A1, B1, C1}.
 
add_time(X, Y) ->
   T = X + Y,
   {T rem 1000000, T div 1000000}.

%%
%% run state machine
run(Msg, Pipe, #machine{rate=undefined, mod=Mod, sid=Sid0}=S) ->
   case Mod:Sid0(Msg, Pipe, S#machine.state) of
      {next_state, Sid, State} ->
         {noreply, S#machine{sid=Sid, state=State}};
      {next_state, Sid, State, TorH} ->
         {noreply, S#machine{sid=Sid, state=State}, TorH};
      {stop, Reason, State} ->
         {stop, Reason, S#machine{state=State}}
   end;

run(Msg, Pipe, #machine{mod=Mod, sid=Sid0, tick=Tick}=S)
 when Tick < S#machine.rate ->
   case Mod:Sid0(Msg, Pipe, S#machine.state) of
      {next_state, Sid, State} ->
         {noreply, S#machine{sid=Sid, state=State, tick=Tick + 1}};
      {next_state, Sid, State, TorH} ->
         {noreply, S#machine{sid=Sid, state=State, tick=Tick + 1}, TorH};
      {stop, Reason, State} ->
         {stop, Reason, S#machine{state=State}}
   end;

run(Msg, Pipe, #machine{time=Time}=S) ->
   case os:timestamp() of
      %% execution rate quota is exceeded
      X when X < Time ->
         timer:sleep(timer:now_diff(X, Time) div 1000),
         run(Msg, Pipe, S#machine{tick=0, time=next_period(S#machine.period)});
      %% 
      _ ->
         run(Msg, Pipe, S#machine{tick=0, time=next_period(S#machine.period)})
   end.



