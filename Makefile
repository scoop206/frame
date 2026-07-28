.PHONY: test test-unit test-integration lint

test:
	zsh tests/run.sh

test-unit:
	zsh tests/run.sh --unit

test-integration:
	zsh tests/run.sh --integration

lint:
	zsh tests/run.sh --lint
