# make test                            every spec in tests/
# make test FILE=tests/notes_spec.lua  one spec
.PHONY: test
test:
	@tests/run.sh $(FILE)
