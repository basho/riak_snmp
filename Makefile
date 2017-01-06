

.PHONY: deps test

all: deps compile

deps:
	./rebar get-deps

compile:
	./rebar compile

clean:
	./rebar clean

DIALYZER_APPS = kernel stdlib erts sasl eunit

include tools.mk
