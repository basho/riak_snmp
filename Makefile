

.PHONY: deps test

all: deps compile

deps:
	./rebar get-deps

compile:
	./rebar compile
	cp mibs/* priv/mibs/

clean:
	./rebar clean

test:
	./rebar eunit skip_deps=true

docs:
	./rebar doc

dialyzer: compile
	@dialyzer -Wno_return -c apps/riak_snmp/ebin
