# Makefile — Convenience tasks for localization workflows
# Location: bitchatUITests/Localization/Scripts
#
# Usage examples:
#   make help
#   make audit
#   make export LOCALES=es,fr OUT=localization_exports
#   make import CSV=localization_exports/es.csv LOCALE=es
#   make sync
#   make reset LOCALES=es,fr
#   make update KEY=accessibility.add_favorite LOCALE=es VALUE="Añadir a favoritos"
#   make check-required
#   make ui-test SCHEME="bitchat (iOS)" DEST="platform=iOS Simulator,name=iPhone 15,OS=latest"
#   make sim-get
#   make sim-set TAG=es_ES

.PHONY: help audit export import sync reset update check-required ui-test sim-get sim-set
.DEFAULT_GOAL := help

# Defaults (can be overridden via env/CLI)
XCSTR ?= bitchat/Localization/Localizable.xcstrings
OUT   ?= localization_exports
LOCALES ?=
CSV ?=
LOCALE ?=
KEY ?=
VALUE ?=

# Simulator testing
SCHEME ?= bitchat (iOS)
DEST   ?= platform=iOS Simulator,name=iPhone 15,OS=latest
UDID   ?=
TAG    ?=

help:
	@echo "Localization helper commands:"
	@echo "  make audit                                 # Heuristic audit of the catalog"
	@echo "  make export [LOCALES=a,b] [OUT=dir]       # Export CSVs for locales (or all)"
	@echo "  make import CSV=path LOCALE=xx            # Import a locale CSV"
	@echo "  make sync                                  # Fill missing/empty values with English"
	@echo "  make reset [LOCALES=a,b]                   # Reset locales to English"
	@echo "  make update KEY=... LOCALE=.. VALUE=..     # Update a single value"
	@echo "  make check-required                        # Required-locales completeness check"
	@echo "  make ui-test [SCHEME][DEST][UDID]          # Run iOS UI tests on simulator"
	@echo "  make sim-get [UDID]                        # Print booted simulator locale"
	@echo "  make sim-set TAG=xx_XX [UDID]              # Set simulator locale"
	@echo ""
	@echo "Vars: XCSTR=$(XCSTR) OUT=$(OUT) LOCALES=$(LOCALES)"

audit:
	python3 audit_xcstrings.py $(XCSTR)

export:
	@if [ -n "$(LOCALES)" ]; then 		python3 export_xcstrings_csv.py $(XCSTR) $(OUT) --locales $(LOCALES); 	else 		python3 export_xcstrings_csv.py $(XCSTR) $(OUT); 	fi

import:
	@if [ -z "$(CSV)" ] || [ -z "$(LOCALE)" ]; then 		echo "Usage: make import CSV=path LOCALE=xx" >&2; exit 2; 	fi
	python3 import_xcstrings_csv.py $(XCSTR) $(CSV) $(LOCALE)

sync:
	python3 sync_xcstrings.py $(XCSTR)

reset:
	@if [ -n "$(LOCALES)" ]; then 		python3 reset_xcstrings_to_en.py $(XCSTR) --locales $(LOCALES); 	else 		python3 reset_xcstrings_to_en.py $(XCSTR); 	fi

update:
	@if [ -z "$(KEY)" ] || [ -z "$(LOCALE)" ] || [ -z "$(VALUE)" ]; then 		echo "Usage: make update KEY=... LOCALE=.. VALUE=.." >&2; exit 2; 	fi
	python3 update_xcstrings_value.py $(XCSTR) $(KEY) $(LOCALE) $(VALUE)

check-required:
	./check-translations.sh --file $(XCSTR)

ui-test:
	./test-sim-locale.sh --test 		--scheme "$(SCHEME)" 		--dest "$(DEST)" 		$(if $(UDID),--id $(UDID))

sim-get:
	./test-sim-locale.sh --get $(if $(UDID),--id $(UDID))

sim-set:
	@if [ -z "$(TAG)" ]; then echo "Usage: make sim-set TAG=xx_XX [UDID]" >&2; exit 2; fi
	./test-sim-locale.sh --set --locale $(TAG) $(if $(UDID),--id $(UDID))
