%% Riak EnterpriseDS
%% Copyright (c) 2013-2014 Basho Technologies, Inc. All Rights Reserved.
-module(riak_snmp_tests).
-compile(export_all).

-define(INTERVAL, 4).

-include_lib("eunit/include/eunit.hrl").

stat_poll_test_() ->
    {foreach,
     fun() ->
             ok = meck:new(snmp_generic),
             ok = meck:new(snmpa),
             ok = meck:new(snmpa_local_db),
             load_fake_riak_modules(),
             ok = meck:new(fake_riak_stats),
             application:load(riak_snmp),
             ok = application:set_env(riak_snmp, polling_interval, ?INTERVAL)
     end,
     fun(_) ->
             application:unload(riak_snmp),
             meck:unload(fake_riak_stats),
             code:purge(fake_riak_stats),
             code:purge(riak_repl_status),
             code:purge(riak),
             meck:unload(snmpa_local_db),
             meck:unload(snmpa),
             meck:unload(snmp_generic)
     end,
     [{"SNMP riak objects get set",
       fun riak_objects_are_set/0},
      {"SNMP riak traps",
       fun riak_traps/0},
      {"SNMP repl tables 1",
       fun repl_tables_1/0},
      {"SNMP repl tables 2",
       fun repl_tables_2/0},
      {"SNMP repl traps",
       fun repl_traps/0}]}.

%% This test just verifies that stat values are getting set into SNMP
%% objects via the snmp_generic:variable_set/2 call. Our mock of that
%% function just ensures that the stat passed in is a member of the list of
%% expected stats. The timer:sleep call is just a pause to ensure the
%% timeout in the riak_snmp_stat_poller gen_server fires, polls the stats,
%% and sets them into SNMP.
%%
riak_objects_are_set() ->
    Stat = node_get_fsm_time_mean,
    [{_, Vars0}] = get_stats(Stat, 0),
    {Vars,_} = lists:unzip(Vars0),
    meck:expect(snmpa, load_mibs, fun(_) -> ok end),
    meck:expect(fake_riak_stats, get_stats, fun(local) ->
                                                    get_stats(Stat, 0)
                                            end),
    meck:expect(snmp_generic, variable_set,
                fun({Var,volatile}, _) -> lists:member(Var, Vars) end),
    riak_snmp_stat_poller:start_link(),
    Loaded = application:loaded_applications(),
    ?assertMatch({value,{riak_snmp,_,_}}, lists:keysearch(riak_snmp, 1, Loaded)),
    timer:sleep(trunc(1.5*?INTERVAL)),
    riak_snmp_stat_poller:stop(),
    timer:sleep(2*?INTERVAL),
    ?assert(meck:validate(fake_riak_stats)),
    ?assert(meck:validate(snmpa)),
    ?assert(meck:called(snmp_generic,variable_set,
                        [{nodeGetTimeMean,volatile},0])),
    ok.

%% This test verifies that SNMP traps occur when expected. It sets the
%% node_get_fsm_time_mean threshold and then makes sure the
%% riak_snmp_stat_poller retrieves a value that on the first call is
%% greater than that threshold and on the second call is less than that
%% threshold. We expect to see the snmpa:send_notification/4 function
%% called twice, once for the rising trap and once for the falling trap.
%%
riak_traps() ->
    Stat = node_get_fsm_time_mean,
    Threshold = nodeGetTimeMeanThreshold,
    ThresholdVal = 300,
    DoubleThresh = 2*ThresholdVal,
    ok = application:set_env(riak_snmp, Threshold, ThresholdVal),
    meck:expect(snmpa, load_mibs, 1, ok),
    meck:expect(fake_riak_stats, get_stats,
                fun(local) -> get_stats(Stat, DoubleThresh) end),
    meck:expect(snmp_generic, variable_set,
                fun({_,volatile}, _) -> true end),
    riak_snmp_stat_poller:start_link(),
    ?assert(meck:validate(snmpa)),
    meck:expect(snmpa, send_notification,
                fun(snmp_master_agent, _, no_receiver,
                    [{_, Val}, {_, Thresh}]) ->
                        ?assertEqual(Val, DoubleThresh),
                        ?assertEqual(Thresh, ThresholdVal),
                        ok
                end),
    timer:sleep(trunc(5.5*?INTERVAL)),
    ?assert(meck:validate(snmpa)),
    ?assert(meck:called(snmpa, send_notification,
                        [snmp_master_agent,nodeGetTimeMeanAlarmRising,
                        no_receiver,[{nodeGetTimeMean,DoubleThresh},
                                     {nodeGetTimeMeanThreshold,ThresholdVal}]])),
    ?assert(meck:validate(snmp_generic)),
    ?assert(meck:validate(fake_riak_stats)),
    meck:expect(snmpa, send_notification,
                fun(snmp_master_agent, _, no_receiver,
                    [{_, 0}, {_, Thresh}]) ->
                        ?assertEqual(Thresh, ThresholdVal),
                        ok
                end),
    meck:expect(fake_riak_stats, get_stats,
                fun(local) -> get_stats(Stat, 0) end),
    timer:sleep(trunc(5.5*?INTERVAL)),
    riak_snmp_stat_poller:stop(),
    timer:sleep(2*?INTERVAL),
    ?assert(meck:validate(snmpa)),
    ?assert(meck:called(snmpa, send_notification,
                        [snmp_master_agent,nodeGetTimeMeanAlarmFalling,
                         no_receiver,
                         [{nodeGetTimeMean,0},
                          {nodeGetTimeMeanThreshold,ThresholdVal}]])),
    ?assert(meck:validate(fake_riak_stats)),
    ok.

%% This test sets one of the repl SNMP tables with a single element.
repl_tables_1() ->
    Stat = client_rx_kbps,
    StatVal = 16,
    ok = application:set_env(riak_snmp, repl_traps_enabled, true),
    meck:expect(snmpa, load_mibs, fun(_) -> ok end),
    meck:expect(fake_riak_stats, get_stats,
                fun(local) ->
                        get_stats(node_get_fsm_time_mean, 0)
                end),
    meck:expect(snmp_generic, variable_set,
                fun({_,volatile}, _) -> true end),
    ok = meck:new(riak_repl_console),
    meck:expect(riak_repl_console, status,
                fun(quiet) ->
                        [{Stat, [StatVal]}]
                end),
    meck:expect(snmp_generic, table_row_exists,
                fun(replClientRxRateTable,[0]) -> false end),
    meck:expect(snmpa_local_db, table_create_row,
                fun({replClientRxRateTable,volatile},[0],{0,0}) -> true end),
    meck:expect(snmp_generic, table_set_elements,
                fun(replClientRxRateTable,[0],[{1,0},{2,Val}]) ->
                        ?assertEqual(Val, StatVal),
                        true
                end),
    riak_snmp_stat_poller:start_link(),
    timer:sleep(trunc(5.5*?INTERVAL)),
    riak_snmp_stat_poller:stop(),
    timer:sleep(2*?INTERVAL),
    ?assert(meck:validate(snmpa)),
    ?assert(meck:validate(snmpa_local_db)),
    ?assert(meck:validate(snmp_generic)),
    ?assert(meck:validate(riak_repl_console)),
    ?assert(meck:called(snmp_generic, table_set_elements,
                        [replClientRxRateTable,[0],[{1,0},{2,StatVal}]])),
    meck:unload(riak_repl_console),
    ok.

%% This test sets one of the repl SNMP string-indexed tables with a single element.
-define(SINKNAME, "ClusterB").
repl_tables_2() ->
    Stat = realtime_enabled,
    StatVal = ?SINKNAME,
    ok = application:set_env(riak_snmp, repl_traps_enabled, true),
    meck:expect(snmpa, load_mibs, fun(_) -> ok end),
    meck:expect(fake_riak_stats, get_stats,
                fun(local) ->
                        get_stats(node_get_fsm_time_mean, 0)
                end),
    meck:expect(snmp_generic, variable_set,
                fun({_,volatile}, _) -> true end),
    ok = meck:new(riak_repl_console),
    meck:expect(riak_repl_console, status,
                fun(quiet) ->
                        [{Stat, StatVal}]
                end),
    meck:expect(snmp_generic, table_row_exists,
                fun(replRealtimeStatusTable,?SINKNAME) -> false end),
    meck:expect(snmpa_local_db, table_create_row,
                fun({replRealtimeStatusTable,volatile},?SINKNAME,{?SINKNAME,2,2}) ->
                        true
                end),
    meck:expect(snmpa_local_db, table_get,
                fun(replRealtimeStatusTable) -> [{?SINKNAME,{?SINKNAME,2,2}}] end),
    meck:expect(snmp_generic, table_set_elements,
                fun(replRealtimeStatusTable,Val,[{2,1},{1,Val}]) ->
                        ?assertEqual(Val, StatVal),
                        true
                end),
    riak_snmp_stat_poller:start_link(),
    timer:sleep(trunc(5.5*?INTERVAL)),
    riak_snmp_stat_poller:stop(),
    timer:sleep(2*?INTERVAL),
    ?assert(meck:validate(snmpa)),
    ?assert(meck:validate(snmpa_local_db)),
    ?assert(meck:validate(snmp_generic)),
    ?assert(meck:validate(riak_repl_console)),
    ?assert(meck:called(snmp_generic, table_set_elements,
                        [replRealtimeStatusTable,?SINKNAME,[{2,1},{1,?SINKNAME}]])),
    meck:unload(riak_repl_console),
    ok.

%% This test forces one of the repl traps to fire.
repl_traps() ->
    Stat = client_connect_errors,
    StatVal = 10,
    ok = application:set_env(riak_snmp, repl_traps_enabled, true),
    meck:expect(snmpa, load_mibs, fun(_) -> ok end),
    meck:expect(fake_riak_stats, get_stats,
                fun(local) ->
                        get_stats(node_get_fsm_time_mean, 0)
                end),
    meck:expect(snmp_generic, variable_set,
                fun({_,volatile}, _) -> true end),
    ok = meck:new(riak_repl_console),
    meck:expect(riak_repl_console, status,
                fun(quiet) ->
                        [{Stat, StatVal}]
                end),
    meck:expect(snmpa, send_notification,
                fun(snmp_master_agent, replClientConnectErrorAlarm, no_receiver,
                    [{replClientConnectErrors, Val}]) ->
                        ?assertEqual(Val, StatVal),
                        ok
                end),
    riak_snmp_stat_poller:start_link(),
    timer:sleep(trunc(5.5*?INTERVAL)),
    riak_snmp_stat_poller:stop(),
    timer:sleep(2*?INTERVAL),
    ?assert(meck:validate(snmpa)),
    ?assert(meck:validate(snmp_generic)),
    ?assert(meck:validate(riak_repl_console)),
    ?assert(meck:called(snmpa, send_notification,
                        [snmp_master_agent,replClientConnectErrorAlarm,
                         no_receiver,[{replClientConnectErrors,StatVal}]])),
    meck:unload(riak_repl_console),
    ok.

%% This function loads fake riak and riak_repl_console modules using the
%% Erlang Abstract Format.  We can't easily put the real modules in our
%% path, so we can't use meck to mock them. The two functions provided here
%% from the riak module are get_app_env/2, which just returns its second
%% argument, and local_client/0, which just returns another fake module
%% named fake_riak_stats, which provides the get_stats/1 function and which
%% the tests above mock with meck. For riak_repl_console we just supply the
%% status/1 function, which is how riak_snmp obtains repl stats.
load_fake_riak_modules() ->
    RiakForms = [{attribute,1,module,riak},
                 {attribute,2,compile,[export_all]},
                 {function,3,get_app_env,2,
                  [{clause,3,
                    [{atom,3,mib_dir},{var,3,'Default'}],
                    [],
                    [{var,4,'Default'}]}]},
                 {function,5,local_client,0,
                  [{clause,5,
                    [],
                    [],
                    [{tuple,6,[{atom,6,ok},{atom,6,fake_riak_stats}]}]}]}],
    {module, riak} = load_beam(RiakForms, riak),
    RiakReplForms = [{attribute,1,module,riak_repl_console},
                     {attribute,2,compile,[export_all]},
                     {function,3,status,1,
                      [{clause,3,
                        [{atom,3,quiet}],
                        [],
                        [{nil,4}]}]}],
    {module, riak_repl_console} = load_beam(RiakReplForms, riak_repl_console),
    FakeStats = [{attribute,1,module,fake_riak_stats},
                 {attribute,2,compile,[export_all]},
                 {function,3,get_stats,1,
                  [{clause,3,
                    [{atom,3,local}],
                    [],
                    [{atom,4,ok}]}]}],
    {module, fake_riak_stats} = load_beam(FakeStats, fake_riak_stats),
    ok.

load_beam(Forms, Module) ->
    code:purge(Module),
    {ok, Module, Beam, _} = compile:forms(Forms, [return]),
    File = atom_to_list(Module) ++ ".erl",
    {module, Module} = code:load_binary(Module, File, Beam).

get_stats(Stat, Value) ->
    [{'node@127.0.0.1', [{Stat,Value}]}].
