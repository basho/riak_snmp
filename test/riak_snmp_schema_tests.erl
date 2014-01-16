-module(riak_snmp_schema_tests).

-include_lib("eunit/include/eunit.hrl").
-compile(export_all).

%% basic schema test will check to make sure that all defaults from
%% the schema make it into the generated app.config
basic_schema_test() ->
    %% The defaults are defined in ../priv/riak_snmp.schema.
    %% it is the file under test.
    Config = cuttlefish_unit:generate_templated_config(
        ["../priv/riak_snmp.schema"], [], context()),
    io:format("~p~n", [Config]),
    assert_snmp_defaults(Config),
    cuttlefish_unit:assert_config(Config, "snmp.agent.db_dir", "./snmp/db"),
    cuttlefish_unit:assert_config(Config, "snmp.agent.config.force_load", true),
    cuttlefish_unit:assert_config(Config, "riak_snmp.polling_interval", 60000),
    cuttlefish_unit:assert_config(Config, "riak_snmp.repl_traps_enabled", false),
    cuttlefish_unit:assert_config(Config, "riak_snmp.nodeGetTimeMeanThreshold", 0),
    cuttlefish_unit:assert_config(Config, "riak_snmp.nodeGetTimeMedianThreshold", 0),
    cuttlefish_unit:assert_config(Config, "riak_snmp.nodeGetTime95Threshold", 0),
    cuttlefish_unit:assert_config(Config, "riak_snmp.nodeGetTime99Threshold", 0),
    cuttlefish_unit:assert_config(Config, "riak_snmp.nodeGetTime100Threshold", 0),
    cuttlefish_unit:assert_config(Config, "riak_snmp.nodePutTimeMeanThreshold", 0),
    cuttlefish_unit:assert_config(Config, "riak_snmp.nodePutTimeMedianThreshold", 0),
    cuttlefish_unit:assert_config(Config, "riak_snmp.nodePutTime95Threshold", 0),
    cuttlefish_unit:assert_config(Config, "riak_snmp.nodePutTime99Threshold", 0),
    cuttlefish_unit:assert_config(Config, "riak_snmp.nodePutTime100Threshold", 0),
    ok.

override_schema_test() ->
    %% Conf represents the riak.conf file that would be read in by cuttlefish.
    %% this proplists is what would be output by the conf_parse module
    Conf = [
            {["snmp", "force_reload"], off},
            {["snmp", "database_dir"], "/crazy/snmp/db"},
            {["snmp", "refresh_frequency"], "1h"},
            {["snmp", "traps", "replication"], on},
            {["snmp", "nodeGetTimeMeanThreshold"], "10"},
            {["snmp", "nodeGetTimeMedianThreshold"], "20"},
            {["snmp", "nodeGetTime95Threshold"], "30"},
            {["snmp", "nodeGetTime99Threshold"], "40"},
            {["snmp", "nodeGetTime100Threshold"], "50"},
            {["snmp", "nodePutTimeMeanThreshold"], "60"},
            {["snmp", "nodePutTimeMedianThreshold"], "70"},
            {["snmp", "nodePutTime95Threshold"], "80"},
            {["snmp", "nodePutTime99Threshold"], "90"},
            {["snmp", "nodePutTime100Threshold"], "100"}
           ],

    %% The defaults are defined in ../priv/riak_snmp.schema.
    %% it is the file under test.
    Config = cuttlefish_unit:generate_templated_config(
        ["../priv/riak_snmp.schema"], Conf, context()),

    assert_snmp_defaults(Config),
    cuttlefish_unit:assert_config(Config, "snmp.agent.db_dir", "/crazy/snmp/db"),
    cuttlefish_unit:assert_config(Config, "snmp.agent.config.force_load", false),
    cuttlefish_unit:assert_config(Config, "riak_snmp.polling_interval", 3600000),
    cuttlefish_unit:assert_config(Config, "riak_snmp.repl_traps_enabled", true),
    cuttlefish_unit:assert_config(Config, "riak_snmp.nodeGetTimeMeanThreshold", 10),
    cuttlefish_unit:assert_config(Config, "riak_snmp.nodeGetTimeMedianThreshold", 20),
    cuttlefish_unit:assert_config(Config, "riak_snmp.nodeGetTime95Threshold", 30),
    cuttlefish_unit:assert_config(Config, "riak_snmp.nodeGetTime99Threshold", 40),
    cuttlefish_unit:assert_config(Config, "riak_snmp.nodeGetTime100Threshold", 50),
    cuttlefish_unit:assert_config(Config, "riak_snmp.nodePutTimeMeanThreshold", 60),
    cuttlefish_unit:assert_config(Config, "riak_snmp.nodePutTimeMedianThreshold", 70),
    cuttlefish_unit:assert_config(Config, "riak_snmp.nodePutTime95Threshold", 80),
    cuttlefish_unit:assert_config(Config, "riak_snmp.nodePutTime99Threshold", 90),
    cuttlefish_unit:assert_config(Config, "riak_snmp.nodePutTime100Threshold", 100),
    ok.

assert_snmp_defaults(Config) ->
    cuttlefish_unit:assert_config(Config, "snmp.agent.net_if", [{options, [{bind_to, true}]}]),
    cuttlefish_unit:assert_config(Config, "snmp.agent.db_init_error", create_db_and_dir),
    cuttlefish_unit:assert_config(Config, "snmp.agent.config.dir", "./snmp/agent"),
    ok.

%% this context() represents the substitution variables that rebar
%% will use during the build process.  riak_jmx's schema file is
%% written with some {{mustache_vars}} for substitution during
%% packaging cuttlefish doesn't have a great time parsing those, so we
%% perform the substitutions first, because that's how it would work
%% in real life.
context() ->
    [
        {snmp_agent_conf, "./snmp/agent"},
        {snmp_db_dir, "./snmp/db"}
    ].
