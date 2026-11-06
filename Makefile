# make test                            every spec in tests/
# make test FILE=tests/notes_spec.lua  one spec
.PHONY: test
test:
	@tests/run.sh $(FILE)

# make gifs                            re-record docs/gifs/ (needs vhs: brew install vhs)
.PHONY: gifs
gifs:
	@for tape in docs/demo/*.tape; do vhs "$$tape"; done
