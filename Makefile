

.PHONY: deps

all: compile

compile:
	./rebar compile

clean:
	./rebar clean

test:
	./rebar eunit

docs:
	./rebar doc

dialyzer: compile
	@dialyzer -Wno_return -c apps/riak_snmp/ebin


