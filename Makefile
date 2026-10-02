.PHONY: build test test-unit test-isolated-import
IMAGE ?= eliza-openai:trixie
build:
	docker build --target runtime -t $(IMAGE) .

test:
	bash tests/docker-e2e.sh

test-isolated-import:
	ELIZA_TEST_ISOLATED_IMPORT=1 bash tests/docker-e2e.sh

test-unit:
	prove -Ilib -v t
	python3 -m unittest discover -s tests -p test_image_delta.py -v
