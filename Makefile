

.PHONY: deps test

all: deps compile

deps:
	./rebar get-deps

compile:
	./rebar compile
	cp mibs/* priv/mibs/

clean:
	./rebar clean
	rm -f include/RIAK.hrl priv/mibs/*

DIALYZER_APPS = kernel stdlib erts sasl eunit

include tools.mk
