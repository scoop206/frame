.PHONY: test test-unit test-integration lint usage check-usage

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
