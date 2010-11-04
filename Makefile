all: deps compile doc

.PHONY: doc

deps: get-deps

compile doc clean eunit get-deps:
	rebar $@
