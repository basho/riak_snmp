%% Riak EnterpriseDS
%% Copyright (c) 2007-2014 Basho Technologies, Inc. All Rights Reserved.
-module(riak_snmp_stat_poller).
-behaviour(gen_server).

-include("RIAK.hrl").

%% API
-export([start_link/0, stop/0]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

%% Currently, stats that are monitored for SNMP traps are limited to
%% those below, and all have values in microseconds.
-type trap_stat() :: node_get_fsm_time_mean | node_get_fsm_time_median |
                     node_get_fsm_time_95 | node_get_fsm_time_99 |
                     node_get_fsm_time_100 |
                     node_put_fsm_time_mean | node_put_fsm_time_median |
                     node_put_fsm_time_95 | node_put_fsm_time_99 |
                     node_put_fsm_time_100 |
                     client_connect_errors | server_connect_errors |
                     objects_dropped_no_clients | objects_dropped_no_leader |
                     rt_sink_errors | rt_source_errors.

%% trap_stat_var() specifies the names of the SNMP object types that match
%% the stats. These must match those defined in mibs/RIAK.mib.
-type trap_stat_var() :: nodeGetTimeMean | nodeGetTimeMedian |
                         nodeGetTime95 | nodeGetTime99 | nodeGetTime100 |
                         nodePutTimeMean | nodePutTimeMedian |
                         nodePutTime95 | nodePutTime99 | nodePutTime100 |
                         replClientConnectErrors | replServerConnectErrors |
                         replObjectsDroppedNoClients |
                         replObjectsDroppedNoLeader |
                         replRtSinkErrors | replRtSourceErrors.

%% trap_stat_threshold() names the SNMP threshold object types for each
%% monitored stat. The names here must match those defined in mibs/RIAK.mib
%% and listed in riak_ee/rel/files/app.config.
-type trap_stat_threshold() :: nodeGetTimeMeanThreshold |
                               nodeGetTimeMedianThreshold |
                               nodeGetTime95Threshold |
                               nodeGetTime99Threshold |
                               nodeGetTime100Threshold |
                               nodePutTimeMeanThreshold |
                               nodePutTimeMedianThreshold |
                               nodePutTime95Threshold |
                               nodePutTime99Threshold |
                               nodePutTime100Threshold.

%% trap_stat_rising() and trap_stat_falling() are the alarm trap types
%% defined in mibs/RIAK.mib.
-type trap_stat_rising() :: nodeGetTimeMeanAlarmRising |
                            nodeGetTimeMedianAlarmRising |
                            nodeGetTime95AlarmRising |
                            nodeGetTime99AlarmRising |
                            nodeGetTime100AlarmRising |
                            nodePutTimeMeanAlarmRising |
                            nodePutTimeMedianAlarmRising |
                            nodePutTime95AlarmRising |
                            nodePutTime99AlarmRising |
                            nodePutTime100AlarmRising.
-type trap_stat_falling() :: nodeGetTimeMeanAlarmFalling |
                             nodeGetTimeMedianAlarmFalling |
                             nodeGetTime95AlarmFalling |
                             nodeGetTime99AlarmFalling |
                             nodeGetTime100AlarmFalling |
                             nodePutTimeMeanAlarmFalling |
                             nodePutTimeMedianAlarmFalling |
                             nodePutTime95AlarmFalling |
                             nodePutTime99AlarmFalling |
                             nodePutTime100AlarmFalling.

%% The tvalue field of the threshold_trap record type below is constrained
%% to pos_integer() because all the stats currently being monitored for
%% SNMP traps based on thresholds are all measured in microseconds. The
%% value 0 is used to indicate that traps are disabled for that stat. See
%% the default values in riak_ee/rel/files/app.config. The alarm_on field
%% of threshold_trap, if true, indicates that the stat is currently above
%% its threshold and a rising alarm has been sent.
-record(threshold_trap, {
          threshold :: trap_stat_threshold(),
          rising :: trap_stat_rising(),
          falling :: trap_stat_falling(),
          tvalue = 0 :: pos_integer(),
          alarm_on = false :: boolean()
         }).

-type counter_alarm() :: replClientConnectErrorAlarm |
                         replServerConnectErrorAlarm |
                         replObjectsDroppedNoClientsAlarm |
                         replObjectsDroppedNoLeaderAlarm |
                         replRtSinkErrorAlarm | replRtSourceErrorAlarm.

-record(counter_trap, {
          last_count = 0 :: pos_integer(),
          alarm :: counter_alarm()
         }).

-record(trap_state, {
          stat :: trap_stat(),
          var :: trap_stat_var(),
          trap :: #threshold_trap{} | #counter_trap{}
         }).
-type trap_states() :: [#trap_state{}].

-define(POLLING_DEFAULT, 60000).

-record(state, {
          trap_states :: trap_states()
         }).

%%====================================================================
%% API
%%====================================================================

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

stop() ->
    gen_server:cast(?MODULE, stop).

%%====================================================================
%% gen_server callbacks
%%====================================================================

init([]) ->
    prepare_mibs(),
    Polling = get_polling_interval(),
    TrapStates = init_trap_states(),
    {ok, #state{trap_states=TrapStates}, Polling}.

handle_call(_Request, _From, State) ->
    Reply = ok,
    {reply, Reply, State, get_polling_interval()}.

handle_cast(stop, State) ->
    {stop, normal, State};
handle_cast(_Msg, State) ->
    {noreply, State, get_polling_interval()}.

handle_info(timeout, State) ->
    NewTrapStates = try
                        poll_stats(State#state.trap_states)
                    catch X:Y ->
                            error_logger:error_msg("poll_stats: ~p ~p @ ~p\n",
                                                   [X, Y, erlang:get_stacktrace()]),
                            State#state.trap_states
                    end,
    {noreply, State#state{trap_states=NewTrapStates}, get_polling_interval()};
handle_info(_Info, State) ->
    {noreply, State, get_polling_interval()}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%--------------------------------------------------------------------
%% Internal functions
%%--------------------------------------------------------------------

get_polling_interval() ->
    case application:get_env(riak_snmp, polling_interval) of
        undefined ->
            ?POLLING_DEFAULT;
        {ok, Interval} when is_integer(Interval), Interval > 0 ->
            Interval;
        _ ->
            ?POLLING_DEFAULT
    end.

prepare_mibs() ->
    PrivDir = case code:priv_dir(riak_snmp) of
                  {error, bad_name} ->
                      Ebin = filename:dirname(code:which(?MODULE)),
                      filename:join(filename:dirname(Ebin), "priv");
                  PD ->
                      PD
              end,
    DefaultMibDir = filename:join(PrivDir, "mibs"),
    MibDir = case application:get_env(riak_snmp, mib_dir) of
                 undefined ->
                     DefaultMibDir;
                 {ok, MDir} ->
                     MDir
             end,
    snmpa:load_mibs(filelib:wildcard(filename:join(MibDir, "*.bin"))).

poll_stats(TrapStates) ->
    TS0 = poll_riak_stats(TrapStates),
    poll_repl_stats(TS0).

poll_riak_stats(TrapStates) ->
    {ok, C} = riak:local_client(),
    FullStats = [{_Node, LocalStats}] = C:get_stats(local),
    lists:foreach(
      fun({N, Stats}) when is_list(Stats) ->
              insert_riak_stats(N, Stats);
         ({N, Error}) ->
              error_logger:info_msg(
                "Unable to get stats for ~p: ~p", [N, Error])
      end,
      FullStats),
    FilteredStats = lists:filter(fun({Stat,_}) ->
                                         lists:keysearch(Stat, #trap_state.stat,
                                                         TrapStates) /= false
                                 end, LocalStats),
    trap_if_needed(FilteredStats, TrapStates).

insert_riak_stats(_Node, Stats) ->
    [ snmp_generic:variable_set(
        {SnmpKey, volatile},
        gauge_coerce(proplists:get_value(StatKey, Stats)))
      || {StatKey, SnmpKey} <- [{vnode_gets_total, vnodeGets},
                                {vnode_puts_total, vnodePuts},
                                {node_gets_total, nodeGets},
                                {node_puts_total, nodePuts}] ++
             [{Stat, Var} || #trap_state{stat=Stat, var=Var} <- traps()] ].

poll_repl_stats(TrapStates) ->
    Traps = lists:filter(fun({Stat,_}=StatVal) ->
                                 set_repl_var(StatVal),
                                 case lists:keyfind(Stat,#trap_state.stat,
                                                    TrapStates) of
                                     false ->
                                         false;
                                     _ ->
                                         true
                                 end
                         end, riak_repl_console:status(quiet)),
    trap_if_needed(Traps, TrapStates).

gauge_coerce(undefined)            -> 0;
gauge_coerce(unavailable)          -> 0;
gauge_coerce(I) when is_integer(I) -> I;
gauge_coerce(N) when is_number(N)  -> trunc(N).

traps() ->
    [#trap_state{stat=node_get_fsm_time_mean,
                 var=nodeGetTimeMean,
                 trap=#threshold_trap{
                         threshold=nodeGetTimeMeanThreshold,
                         rising=nodeGetTimeMeanAlarmRising,
                         falling=nodeGetTimeMeanAlarmFalling}},
     #trap_state{stat=node_get_fsm_time_median,
                 var=nodeGetTimeMedian,
                 trap=#threshold_trap{
                         threshold=nodeGetTimeMedianThreshold,
                         rising=nodeGetTimeMedianAlarmRising,
                         falling=nodeGetTimeMedianAlarmFalling}},
     #trap_state{stat=node_get_fsm_time_95,
                 var=nodeGetTime95,
                 trap=#threshold_trap{
                         threshold=nodeGetTime95Threshold,
                         rising=nodeGetTime95AlarmRising,
                         falling=nodeGetTime95AlarmFalling}},
     #trap_state{stat=node_get_fsm_time_99,
                 var=nodeGetTime99,
                 trap=#threshold_trap{
                         threshold=nodeGetTime99Threshold,
                         rising=nodeGetTime99AlarmRising,
                         falling=nodeGetTime99AlarmFalling}},
     #trap_state{stat=node_get_fsm_time_100,
                 var=nodeGetTime100,
                 trap=#threshold_trap{
                         threshold=nodeGetTime100Threshold,
                         rising=nodeGetTime100AlarmRising,
                         falling=nodeGetTime100Alarmfalling}},
     #trap_state{stat=node_put_fsm_time_mean,
                 var=nodePutTimeMean,
                 trap=#threshold_trap{
                         threshold=nodePutTimeMeanThreshold,
                         rising=nodePutTimeMeanAlarmRising,
                         falling=nodePutTimeMeanAlarmFalling}},
     #trap_state{stat=node_put_fsm_time_median,
                 var=nodePutTimeMedian,
                 trap=#threshold_trap{
                         threshold=nodePutTimeMedianThreshold,
                         rising=nodePutTimeMedianAlarmRising,
                         falling=nodePutTimeMedianAlarmFalling}},
     #trap_state{stat=node_put_fsm_time_95,
                 var=nodePutTime95,
                 trap=#threshold_trap{
                         threshold=nodePutTime95Threshold,
                         rising=nodePutTime95AlarmRising,
                         falling=nodePutTime95AlarmFalling}},
     #trap_state{stat=node_put_fsm_time_99,
                 var=nodePutTime99,
                 trap=#threshold_trap{
                         threshold=nodePutTime99Threshold,
                         rising=nodePutTime99AlarmRising,
                         falling=nodePutTime99AlarmFalling}},
     #trap_state{stat=node_put_fsm_time_100,
                 var=nodePutTime100,
                 trap=#threshold_trap{
                         threshold=nodePutTime100Threshold,
                         rising=nodePutTime100AlarmRising,
                         falling=nodePutTime100AlarmFalling}},
     #trap_state{stat=client_connect_errors,
                 var=replClientConnectErrors,
                 trap=#counter_trap{alarm=replClientConnectErrorAlarm}},
     #trap_state{stat=server_connect_errors,
                 var=replServerConnectErrors,
                 trap=#counter_trap{alarm=replServerConnectErrorAlarm}},
     #trap_state{stat=objects_dropped_no_clients,
                 var=replObjectsDroppedNoClients,
                 trap=#counter_trap{alarm=replObjectsDroppedNoClientsAlarm}},
     #trap_state{stat=objects_dropped_no_leader,
                 var=replObjectsDroppedNoLeader,
                 trap=#counter_trap{alarm=replObjectsDroppedNoLeaderAlarm}},
     #trap_state{stat=rt_sink_errors,
                 var=replRtSinkErrors,
                 trap=#counter_trap{alarm=replRtSinkErrorAlarm}},
     #trap_state{stat=rt_source_errors,
                 var=replRtSourceErrors,
                 trap=#counter_trap{alarm=replRtSourceErrorAlarm}}].

init_trap_states() ->
    lists:map(fun(#trap_state{trap=Trap}=TS)
                    when is_record(Trap, threshold_trap)->
                      #threshold_trap{threshold=Threshold} = Trap,
                      case application:get_env(riak_snmp, Threshold) of
                          undefined ->
                              TS;
                          {ok, Val} when is_integer(Val) ->
                              NTrap = Trap#threshold_trap{tvalue=Val},
                              TS#trap_state{trap=NTrap};
                          {ok, _} ->
                              TS
                      end;
                 (TS) ->
                      TS
              end, traps()).

%% Currently thresholds can be changed only via application:set_env/3, but
%% we also store the threshold values in the volatile SNMP database and in
%% the trap_states field of the state record. Below we check the env for
%% the value and if it differs from what's in TrapStates, we write the new
%% value to the SNMP database and also store the new value in the returned
%% TrapStates value. Since the SNMP writes are volatile, the threshold
%% values stored in app.config are the only persistent ones.
%%
trap_if_needed([{Stat,_}|_]=Stats, TrapStates) ->
    {value, TS} = lists:keysearch(Stat, #trap_state.stat, TrapStates),
    trap_if_needed(Stats, TrapStates, TS, TS#trap_state.trap);
trap_if_needed([], TrapStates) ->
    TrapStates.

trap_if_needed([{Stat,StatVal}|Stats], TrapStates, TS0, #threshold_trap{}=TT) ->
    #threshold_trap{threshold=ThresholdName, alarm_on=AlarmOn} = TT,
    case application:get_env(riak_snmp, ThresholdName) of
        undefined ->
            trap_if_needed(Stats, TrapStates);
        {ok, 0} ->
            NTrapStates = maybe_store_new_threshold(TT, 0, TS0, TrapStates),
            trap_if_needed(Stats, NTrapStates);
        {ok, Threshold} ->
            NTrapStates = maybe_store_new_threshold(TT, Threshold,
                                                    TS0, TrapStates),
            {value, TS} = lists:keysearch(Stat, #trap_state.stat, NTrapStates),
            {Cmp, AlarmFun} = case AlarmOn of
                                  false ->
                                      {fun erlang:'>'/2, fun alarm_rising/2};
                                  true ->
                                      {fun erlang:'<'/2, fun alarm_falling/2}
                              end,
            case Cmp(StatVal, Threshold) of
                true ->
                    AlarmFun(TS, StatVal),
                    NewTT = TT#threshold_trap{alarm_on=not AlarmOn},
                    NewTS = TS#trap_state{trap=NewTT},
                    NTrapStates2 = lists:keyreplace(Stat,
                                                    #trap_state.stat,
                                                    NTrapStates,
                                                    NewTS),
                    trap_if_needed(Stats, NTrapStates2);
                false ->
                    trap_if_needed(Stats, NTrapStates)
            end
    end;
trap_if_needed(Stats, TrapStates, TS, #counter_trap{}=CT) ->
    ReplTrapsEnabled = application:get_env(riak_snmp, repl_traps_enabled),
    trap_if_needed(Stats, TrapStates, TS, CT, ReplTrapsEnabled).
trap_if_needed([{Stat,StatVal}|Stats], TrapStates, TS, CT, {ok,true}) ->
    #counter_trap{last_count=Count, alarm=Alarm} = CT,
    case StatVal > Count of
        true ->
            snmpa:send_notification(snmp_master_agent, Alarm, no_receiver,
                                    [{TS#trap_state.var, StatVal}]),
            NewCT = CT#counter_trap{last_count=StatVal},
            NewTS = TS#trap_state{trap=NewCT},
            NTrapStates = lists:keyreplace(Stat, #trap_state.stat,
                                           TrapStates, NewTS),
            trap_if_needed(Stats, NTrapStates);
        false ->
            trap_if_needed(Stats, TrapStates)
    end;
trap_if_needed([_|Stats], TrapStates, _TS, _CT, _) ->
    trap_if_needed(Stats, TrapStates).

maybe_store_new_threshold(#threshold_trap{tvalue=TH}, TH, _, TrapStates) ->
    TrapStates;
maybe_store_new_threshold(#threshold_trap{threshold=TK}=TT,TH,TS,TrapStates) ->
    %% store into SNMP so external tools can examine current values
    NewTH = gauge_coerce(TH),
    snmp_generic:variable_set({TK,volatile}, NewTH),
    NewTT = TT#threshold_trap{tvalue=NewTH},
    lists:keyreplace(TS#trap_state.stat, #trap_state.stat, TrapStates,
                     TS#trap_state{trap=NewTT}).

alarm_rising(#trap_state{var=VarKey,trap=TT}, StatValue) ->
    #threshold_trap{threshold=ThreshKey,tvalue=Threshold,rising=Rising} = TT,
    snmpa:send_notification(snmp_master_agent, Rising, no_receiver,
                            [{VarKey, StatValue}, {ThreshKey, Threshold}]).

alarm_falling(#trap_state{var=VarKey,trap=TT}, StatValue) ->
    #threshold_trap{threshold=ThreshKey,tvalue=Threshold,falling=Falling} = TT,
    snmpa:send_notification(snmp_master_agent, Falling, no_receiver,
                            [{VarKey, StatValue}, {ThreshKey, Threshold}]).

%% for tables, need to clear rows that are no longer valid and add rows if
%% not present
set_repl_var({realtime_enabled,[]}) ->
    set_rows(replRealtimeStatusTable, all, [{?replRealtimeEnabled,2}]);
set_repl_var({realtime_enabled,SinkStr}) ->
    Sinks = string:tokens(SinkStr, ", "),
    set_rows(replRealtimeStatusTable, Sinks,
             [{?replRealtimeEnabled,1}], ?replRealtimeSinkName);
set_repl_var({realtime_started,[]}) ->
    set_rows(replRealtimeStatusTable, all, [{?replRealtimeStarted,2}]);
set_repl_var({realtime_started,SinkStr}) ->
    Sinks = string:tokens(SinkStr, ", "),
    set_rows(replRealtimeStatusTable, Sinks,
             [{?replRealtimeStarted,1}], ?replRealtimeSinkName);
set_repl_var({fullsync_enabled,[]}) ->
    set_rows(replFullsyncStatusTable, all, [{?replFullsyncEnabled,2}]);
set_repl_var({fullsync_enabled,SinkStr}) ->
    Sinks = string:tokens(SinkStr, ", "),
    set_rows(replFullsyncStatusTable, Sinks,
             [{?replFullsyncEnabled,1}], ?replFullsyncSinkName);
set_repl_var({fullsync_running,[]}) ->
    set_rows(replFullsyncStatusTable, all, [{?replFullsyncRunning,2}]);
set_repl_var({fullsync_running,SinkStr}) ->
    Sinks = string:tokens(SinkStr, ", "),
    set_rows(replFullsyncStatusTable, Sinks,
             [{?replFullsyncRunning,1}], ?replFullsyncSinkName);
set_repl_var({client_bytes_recv,Val}) ->
    snmp_generic:variable_set({replClientBytesRecv, volatile}, Val);
set_repl_var({client_bytes_sent,Val}) ->
    snmp_generic:variable_set({replClientBytesSent, volatile}, Val);
set_repl_var({client_connect_errors,Val}) ->
    snmp_generic:variable_set({replClientConnectErrors, volatile}, Val);
set_repl_var({client_connects,Val}) ->
    snmp_generic:variable_set({replClientConnects, volatile}, Val);
set_repl_var({client_redirect,Val}) ->
    snmp_generic:variable_set({replClientRedirect, volatile}, Val);
set_repl_var({client_rx_kbps,Vals}) when is_list(Vals) ->
    Indexes = lists:seq(0,length(Vals)-1),
    lists:all(fun({I,V}) ->
                      Cols = [{?replClientRxIndex,I},{?replClientRxRate,V}],
                      set_rows(replClientRxRateTable, [[I]], Cols)
              end, lists:zip(Indexes, Vals));
set_repl_var({client_tx_kbps,Vals}) when is_list(Vals) ->
    Indexes = lists:seq(0,length(Vals)-1),
    lists:all(fun({I,V}) ->
                      Cols = [{?replClientTxIndex,I},{?replClientTxRate,V}],
                      set_rows(replClientTxRateTable, [[I]], Cols)
              end, lists:zip(Indexes, Vals));
set_repl_var({server_rx_kbps,Vals}) when is_list(Vals) ->
    Indexes = lists:seq(0,length(Vals)-1),
    lists:all(fun({I,V}) ->
                      Cols = [{?replServerRxIndex,I},{?replServerRxRate,V}],
                      set_rows(replServerRxRateTable, [[I]], Cols)
              end, lists:zip(Indexes, Vals));
set_repl_var({server_tx_kbps,Vals}) when is_list(Vals) ->
    Indexes = lists:seq(0,length(Vals)-1),
    lists:all(fun({I,V}) ->
                      Cols = [{?replServerTxIndex,I},{?replServerTxRate,V}],
                      set_rows(replServerTxRateTable, [[I]], Cols)
              end, lists:zip(Indexes, Vals));
set_repl_var({objects_dropped_no_clients,Val}) ->
    snmp_generic:variable_set({replObjectsDroppedNoClients, volatile}, Val);
set_repl_var({objects_dropped_no_leader,Val}) ->
    snmp_generic:variable_set({replObjectsDroppedNoLeader, volatile}, Val);
set_repl_var({objects_forwarded,Val}) ->
    snmp_generic:variable_set({replObjectsForwarded, volatile}, Val);
set_repl_var({objects_sent,Val}) ->
    snmp_generic:variable_set({replObjectsSent, volatile}, Val);
set_repl_var({server_bytes_recv,Val}) ->
    snmp_generic:variable_set({replServerBytesRecv, volatile}, Val);
set_repl_var({server_bytes_sent,Val}) ->
    snmp_generic:variable_set({replServerBytesSent, volatile}, Val);
set_repl_var({server_connect_errors,Val}) ->
    snmp_generic:variable_set({replServerConnectErrors, volatile}, Val);
set_repl_var({server_connects,Val}) ->
    snmp_generic:variable_set({replServerConnects, volatile}, Val);
set_repl_var({server_fullsyncs,Val}) ->
    snmp_generic:variable_set({replServerFullsyncs, volatile}, Val);
set_repl_var({rt_dirty,Val}) ->
    snmp_generic:variable_set({replRtDirty, volatile}, Val);
set_repl_var({rt_sink_errors,Val}) ->
    snmp_generic:variable_set({replRtSinkErrors, volatile}, Val);
set_repl_var({rt_source_errors,Val}) ->
    snmp_generic:variable_set({replRtSourceErrors, volatile}, Val);
set_repl_var({cluster_leader,Val}) ->
    ValStr = atom_to_list(Val),
    snmp_generic:variable_set({replClusterLeaderNode, volatile}, ValStr);
set_repl_var(_) ->
    false.

get_sorted_rows(Table, SortFun) ->
    lists:sort(SortFun, snmpa_local_db:table_get(Table)).

set_rows(Table, all, Cols) ->
    Rows = get_indexes(Table),
    set_rows(Table, Rows, Cols);
set_rows(Table, [RowIndex|Rows], Cols) ->
    case snmp_generic:table_row_exists(Table, RowIndex) of
        false ->
            true = create_row(Table, RowIndex);
        true ->
            ok
    end,
    true = snmp_generic:table_set_elements(Table, RowIndex, Cols),
    set_rows(Table, Rows, Cols);
set_rows(_, [], _) ->
    true.
set_rows(Table, Indexes, Cols, IndexCol)
  when Table =:= replRealtimeStatusTable; Table =:= replFullsyncStatusTable ->
    NameSortFun = fun({Nm1,_},{Nm2,_}) -> Nm1 < Nm2 end,
    Rows = case get_sorted_rows(Table, NameSortFun) of
               [] ->
                   SortedIndexes = lists:sort(NameSortFun, Indexes),
                   true = lists:all(fun(Idx) -> create_row(Table, Idx) end,
                                    SortedIndexes),
                   get_sorted_rows(Table, NameSortFun);
               R ->
                   R
           end,
    set_rows(Table, Rows, Indexes, Cols, IndexCol, []).
set_rows(Table, Rows, [Index|Indexes], Cols, IndexCol, Acc) ->
    ColsWithIndex = lists:keystore(IndexCol,1,Cols,{IndexCol,Index}),
    Row = [Row || {_,{Nm,_,_}}=Row <- Rows, Nm == Index],
    {NewRows, IndexArg} = case Row of
                              [] ->
                                  [{[LastIndex],_}|_] = lists:reverse(Rows),
                                  NextIndex = LastIndex+1,
                                  {Rows ++ [{[NextIndex],ColsWithIndex}],
                                   [[NextIndex]]};
                              [{RowIndex,_}] ->
                                  {Rows, [RowIndex]}
                          end,
    Result = set_rows(Table, IndexArg, ColsWithIndex),
    set_rows(Table, NewRows, Indexes, Cols, IndexCol, [Result|Acc]);
set_rows(_, _, [], _, _, Acc) ->
    lists:all(fun(T) -> T end, Acc).

create_row(replRealtimeStatusTable=Table, SinkName) ->
    snmpa_local_db:table_create_row({Table, volatile}, SinkName, {SinkName, 2, 2});
create_row(replFullsyncStatusTable=Table, SinkName) ->
    snmpa_local_db:table_create_row({Table, volatile}, SinkName, {SinkName, 2, 2});
create_row(replClientRxRateTable=Table, [C]=RowIndex) ->
    snmpa_local_db:table_create_row({Table, volatile}, RowIndex, {C, 0});
create_row(replClientTxRateTable=Table, [C]=RowIndex) ->
    snmpa_local_db:table_create_row({Table, volatile}, RowIndex, {C, 0});
create_row(replServerRxRateTable=Table, [C]=RowIndex) ->
    snmpa_local_db:table_create_row({Table, volatile}, RowIndex, {C, 0});
create_row(replServerTxRateTable=Table, [C]=RowIndex) ->
    snmpa_local_db:table_create_row({Table, volatile}, RowIndex, {C, 0}).

get_indexes(Table) ->
    get_indexes(Table, snmp_generic:table_next(Table, []), []).
get_indexes(_, endOfTable, Acc) ->
    lists:reverse(Acc);
get_indexes(Table, RowIndex, Acc) ->
    NewAcc = [RowIndex|Acc],
    get_indexes(Table, snmp_generic:table_next(Table, RowIndex), NewAcc).
