

.PHONY: deps test

MIBS=RIAK.mib

all: deps mib compile

deps:
	./rebar get-deps

mib : priv/mibs/$(MIB)

priv/mibs/$(MIB): mibs/$(MIB)
	cp mibs/$(MIB) priv/mibs/$(MIB)

compile:
	./rebar compile

clean:
	./rebar clean
	rm -f include/RIAK.hrl priv/mibs/*

DIALYZER_APPS = kernel stdlib erts sasl eunit

include tools.mk
