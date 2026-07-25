.DEFAULT_GOAL := help
.PHONY: help build test lint app run clean check

help: ## Show available targets
	@grep -E '^[a-z-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[1m%-8s\033[0m %s\n", $$1, $$2}'

build: ## Compile every target
	swift build

test: ## Run the LggrKit test suite (use this, not `swift test` — see Scripts/test.sh)
	@./Scripts/test.sh

lint: ## Check module boundaries (no Xcode-only macros outside LggrPersistence)
	@./Scripts/check-layering.sh

app: ## Assemble and sign build/Lggr.app
	@./Scripts/make-app.sh release

run: app ## Assemble the app and launch it
	@open build/Lggr.app

check: lint build test ## Enforce boundaries, build everything, run the suite

clean: ## Remove build artefacts
	swift package clean
	rm -rf .build build
