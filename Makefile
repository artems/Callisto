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

.PHONY: clean
clean:
	@$(CABAL) clean


.PHONY: run
run:
	@$(CABAL) run -- tests/_data/ubuntu-13.10-server-amd64.iso.torrent
