CABAL=cabal

.PHONY: test
test:
	@$(CABAL) test --test-option=--hide-successes

deps:
	@$(CABAL) install --only-dependencies
