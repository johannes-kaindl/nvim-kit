.PHONY: check fmt lint test vendor-check live
NVIM ?= nvim
check: fmt lint test vendor-check
fmt:
	stylua --check lua tests
lint:
	selene lua tests
test:
	$(NVIM) --headless -u NONE -l tests/run.lua
# vendor-check needs the nvim-plugins Dach one level up (../tools). A clone of this repo alone
# skips it loudly instead of failing with "can't open file".
DACH := ..
vendor-check:
	@if [ -f $(DACH)/tools/kit/vendor.py ]; then PYTHONDONTWRITEBYTECODE=1 python3 $(DACH)/tools/kit/vendor.py check .; \
	else echo "vendor-check: SKIPPED — no nvim-plugins Dach at $(DACH)/tools (it checks the vendored copies against their sources)"; fi
# Live run against a real model server (Ollama, LM Studio); not part of check. Exit 2: nothing measured.
live:
	$(NVIM) --headless -u NONE -l tests/live.lua
