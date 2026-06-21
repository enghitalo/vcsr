# vcsr — build / install / update the CLI.
#   make install            build + install vcsr to ~/.local/bin (override PREFIX=)
#   make update             git pull --ff-only, then reinstall
#   make build              build the binary into cmd/vcsr/vcsr
#   make test               run the native test suite
PREFIX ?= $(HOME)/.local
BIN     := $(PREFIX)/bin/vcsr
V       ?= v

.PHONY: build install update test clean help

build: ## build the vcsr binary into cmd/vcsr/vcsr
	$(V) -prod -o cmd/vcsr/vcsr cmd/vcsr

install: build ## build, then install vcsr to $(BIN)
	install -d $(dir $(BIN))
	install -m755 cmd/vcsr/vcsr $(BIN)
	@echo "installed vcsr -> $(BIN)  ($$($(BIN) version))"

update: ## fast-forward to origin, then rebuild + install
	git pull --ff-only
	$(MAKE) install

test: ## run the native test suite
	$(V) -enable-globals test tests/ examples/counter/src/

clean: ## remove build artifacts
	rm -f cmd/vcsr/vcsr cmd/vcsr/vcsr.new

help: ## list targets
	@grep -hE '^[a-z][a-z-]*:.*##' $(MAKEFILE_LIST) | sed -E 's/:.*## / - /' | sort
