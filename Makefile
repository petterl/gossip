all: deps compile doc

.PHONY: doc test

test:
	rebar skip_deps=true eunit

deps: get-deps

compile doc clean eunit get-deps:
	rebar $@
