.PHONY: check fmt lint test
NVIM ?= nvim
check: fmt lint test
fmt:
	stylua --check lua tests
lint:
	selene lua tests
test:
	$(NVIM) --headless -u NONE -l tests/run.lua
