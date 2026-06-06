# Convenience targets for developing/testing the-middleman.
#
# Tests run inside Kong's official test runner, Pongo, which spins up a Kong
# container plus the Redis/Postgres dependencies declared in .pongo/pongorc.
# Requires Docker. The first run downloads images and can take a few minutes.

PONGO_VERSION ?= master
PONGO_DIR     ?= .pongo/kong-pongo
PONGO         := $(PONGO_DIR)/pongo.sh

KONG_VERSION  ?= 3.9.2

.PHONY: help pongo lint unit integration test clean

help:
	@echo "Targets:"
	@echo "  make lint         - run luacheck inside Pongo"
	@echo "  make unit         - run spec/01-unit (mocked, fast)"
	@echo "  make integration  - run spec/02-integration (full Kong)"
	@echo "  make test         - run the whole suite + luacheck"
	@echo "  make clean        - tear down Pongo containers/volumes"
	@echo ""
	@echo "Override the Kong version with: make test KONG_VERSION=3.6"

# Vendor Pongo locally so contributors don't need it on their PATH.
pongo: $(PONGO)
$(PONGO):
	git clone --depth 1 -b $(PONGO_VERSION) https://github.com/Kong/kong-pongo.git $(PONGO_DIR)

lint: pongo
	@KONG_VERSION=$(KONG_VERSION) $(PONGO) lint

unit: pongo
	@KONG_VERSION=$(KONG_VERSION) $(PONGO) run -- --run=unit

integration: pongo
	@KONG_VERSION=$(KONG_VERSION) $(PONGO) run -- --run=integration

test: pongo
	@KONG_VERSION=$(KONG_VERSION) $(PONGO) lint
	@KONG_VERSION=$(KONG_VERSION) $(PONGO) run

clean: pongo
	@$(PONGO) down
