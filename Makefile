# vcsr — build / install / update the CLI.
#   make install            build + install vcsr to ~/.local/bin (override PREFIX=)
#   make update             git pull --ff-only, then reinstall
#   make build              build the binary into cmd/vcsr/vcsr
#   make test               regenerate *.gen.v, then run the native test suite
#   make examples           build every wasm example and check it in Chrome
#   make screenshots        same, refreshing each example's screenshot.png
PREFIX ?= $(HOME)/.local
BIN     := $(PREFIX)/bin/vcsr
V       ?= v

.PHONY: build install update test examples screenshots browser-deps clean help

# examples that build to wasm: those with a browser entry in src/
WASM_EXAMPLES := $(patsubst %/src/entry_d_wasm_browser.v,%,$(wildcard examples/*/src/entry_d_wasm_browser.v))
SMOKE := tools/browser-smoke

build: ## build the vcsr binary into cmd/vcsr/vcsr
	$(V) -prod -o cmd/vcsr/vcsr cmd/vcsr

install: build ## build, then install vcsr to $(BIN)
	install -d $(dir $(BIN))
	install -m755 cmd/vcsr/vcsr $(BIN)
	@echo "installed vcsr -> $(BIN)  ($$($(BIN) version))"

update: ## fast-forward to origin, then rebuild + install
	git pull --ff-only
	$(MAKE) install

test: build ## regenerate *.gen.v, then run the native test suite
	./cmd/vcsr/vcsr gen examples/counter/src
	$(V) -enable-globals test tests/ examples/counter/src/

browser-deps: $(SMOKE)/node_modules ## install Playwright (drives the installed Chrome)
$(SMOKE)/node_modules: $(SMOKE)/package-lock.json
	cd $(SMOKE) && PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1 npm ci --no-audit --no-fund
	@touch $@

examples: build browser-deps ## build every wasm example (needs wasi-sdk) and check it in Chrome
	@set -e; for ex in $(WASM_EXAMPLES); do ./cmd/vcsr/vcsr wasm $$ex/src; node $(SMOKE)/example.mjs $$ex --no-shot; done

screenshots: build browser-deps ## same as examples, refreshing each examples/*/screenshot.png
	@set -e; for ex in $(WASM_EXAMPLES); do ./cmd/vcsr/vcsr wasm $$ex/src; node $(SMOKE)/example.mjs $$ex; done

clean: ## remove build artifacts
	rm -f cmd/vcsr/vcsr cmd/vcsr/vcsr.new

help: ## list targets
	@grep -hE '^[a-z][a-z-]*:.*##' $(MAKEFILE_LIST) | sed -E 's/:.*## / - /' | sort
