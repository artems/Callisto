CABAL=cabal --sandbox-config-file=.cabal.sandbox.config

.PHONY: test
test:
	@$(CABAL) test --test-option=--hide-successes

.PHONY: deps
deps:
	@$(CABAL) install --only-dependencies --force-reinstalls

.PHONY: conf
conf:
	@$(CABAL) sandbox init
	@$(CABAL) configure

.PHONY: build
build:
	@$(CABAL) build
