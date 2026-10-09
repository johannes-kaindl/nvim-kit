.PHONY: check fmt lint test
check: fmt lint test
fmt:
	stylua --check lua tests
lint:
	selene lua tests
test:
	nvim --headless -u NONE -l tests/run.lua
