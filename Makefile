.PHONY: test build

test:
	bash Scripts/run-tests.sh

build: test
	bash Scripts/build-app.sh
