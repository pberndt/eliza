.PHONY: build test test-unit
IMAGE ?= eliza-openai:local
build:
	docker build --target runtime -t $(IMAGE) .

test:
	bash tests/docker-e2e.sh

test-unit:
	prove -Ilib -v t
