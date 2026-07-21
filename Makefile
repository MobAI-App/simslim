.PHONY: app cli check format test

VERSION ?= $(shell git describe --tags --always --dirty)

cli:
	go build -ldflags "-X main.version=$(VERSION)" -o simslim .

app:
	./scripts/build-app.sh

test:
	go test ./...

check: test
	go vet ./...
	xcrun swift-format lint --strict --recursive gui
	zsh -n scripts/build-app.sh
	plutil -lint gui/Info.plist

format:
	gofmt -w *.go
	xcrun swift-format format --in-place --recursive gui
