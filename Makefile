.PHONY: app cli check format test swift-test swift-gen swift-gen-check verify-deps

VERSION ?= $(shell git describe --tags --always --dirty)

cli:
	go build -ldflags "-X main.version=$(VERSION)" -o simslim ./cmd/simslim

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

swift-test:
	cd swift && swift test

# Regenerate (or check) swift/.../Generated from the Go catalog. Needs python3; transition-period tool.
swift-gen:
	python3 swift/Tools/gen_catalog.py

swift-gen-check:
	python3 swift/Tools/gen_catalog.py --check

# Manual dependency audit of the Swift port (not part of `check`).
verify-deps:
	./scripts/verify-deps.sh
