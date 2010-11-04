all: deps compile doc

.PHONY: doc test

test:
	rebar skip_deps=true eunit

deps: get-deps

doc:
	rebar skip_deps=true doc

compile clean eunit get-deps:
	rebar $@
