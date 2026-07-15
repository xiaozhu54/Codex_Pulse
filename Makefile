.PHONY: test build

test:
	./Scripts/run-tests.sh

build: test
	./Scripts/build-app.sh
