.PHONY: test test-unit test-integration lint usage check-usage site-assets site

test:
	zsh tests/run.sh

usage:
	zsh bin/gen-usage.sh

check-usage:
	zsh bin/gen-usage.sh
	@git add --intent-to-add docs/usage.md
	@git diff --exit-code docs/usage.md \
		|| { echo "docs/usage.md is stale — run 'make usage' and commit the result." >&2; exit 1; }

test-unit:
	zsh tests/run.sh --unit

test-integration:
	zsh tests/run.sh --integration

lint:
	zsh tests/run.sh --lint

# landing page (site/) — shared images live in assets/, copied in at build time
SITE_ASSETS = demo.gif frame-icon.png frame_social.png

site-assets:
	@mkdir -p site/assets
	@for f in $(SITE_ASSETS); do cp assets/$$f site/assets/$$f; done

site: site-assets
	python3 -m http.server -d site 8080
