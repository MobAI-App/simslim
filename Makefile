.PHONY: app app-check format swift-lint swift-test verify-deps

app:
	./scripts/build-app.sh

# App sources and build script gate.
app-check:
	xcrun swift-format lint --strict --recursive gui
	zsh -n scripts/build-app.sh
	plutil -lint gui/Info.plist

format:
	xcrun swift-format format --in-place --recursive gui

swift-lint:
	xcrun swift-format lint --strict --recursive swift/Sources swift/Tests

swift-test:
	cd swift && swift test

# Manual dependency audit of the Swift port (not part of CI).
verify-deps:
	./scripts/verify-deps.sh
