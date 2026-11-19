# Removing the Go stack

The macOS app and the release already use the Swift CLI alone (`make app` needs no Go; `release.yml`
ships only the Swift tarball). The Go tree is kept for two jobs only:

1. **Parity reference:** `scripts/parity.sh` builds the Go CLI and diffs it against the Swift one.
2. **Catalog source:** `swift/Tools/gen_catalog.py` reads `profiles.go`, `service_descriptions.go`,
   `features.go` and `profiles_test.go` as text to produce the files under `swift/**/Generated/`.

Remove Go when you no longer need either. This page is the checklist. Do it as one commit (or two:
tag, then delete) on its own branch, after a final green parity run.

## Before you delete anything

1. Run the last parity check, read-only and mutating, on a Mac that has Go:
   `scripts/parity.sh --mutating` (see [parity-check.md](parity-check.md)). Fix or accept every diff.
2. Tag the last commit that still has the Go tree, so the reference stays buildable:
   ```sh
   git tag go-reference-final            # on the last commit that contains the Go sources
   git push origin go-reference-final
   ```
3. Confirm the app and CLI work without Go: `VERSION=0.0.0 make app`, `make swift-test`,
   `make verify-deps`.

## What to delete

| Path | Why it can go |
|---|---|
| `*.go` at the repo root (library and tests), `cmd/` | The Go library and CLI. |
| `go.mod`, `go.sum` | No Go module left. |
| `packaging/homebrew/` | Template for the Go build's Homebrew formula; `release.yml` no longer uses it. |
| `swift/Tools/gen_catalog.py` | The generator reads Go sources; without them it has nothing to read. |

## What to edit

- **`swift/**/Generated/*.swift` (`CatalogData.swift`, `ForbiddenLabels.swift`, and any other file
  `gen_catalog.py` emitted):** these become ordinary hand-maintained source. Remove the "generated, do not
  edit" banner and the mention of the Go files, keep the copyright line. They start with
  `// swift-format-ignore-file`; keep it (the tables are long) or remove it and run `make format`.
- **`Makefile`:** delete the `cli`, `test`, `check`, `format` (the `gofmt` line), `swift-gen` and
  `swift-gen-check` targets and their `.PHONY` entries. Keep `app`, `app-check`, `swift-lint`,
  `swift-test`, `verify-deps`; make `format` run only `swift-format`.
- **`scripts/build-app.sh`:** remove the `SIMSLIM_CLI_IMPL` switch, the `go` branch of the CLI build, the
  `GO_ARCH` mapping and the Go-availability check. Keep the Swift branch unconditional.
- **`.github/workflows/ci.yml`:** delete the `go-reference` job and `make swift-gen-check` from the
  `swift` job.
- **`scripts/parity.sh`:** keep it only if you still want to compare against a Go build. Then it must build
  `GO_BIN` from the `go-reference-final` tag (`git worktree add ../simslim-go go-reference-final`) instead of
  `./cmd/simslim`; change the build step and its header comment accordingly. If you drop parity checks
  entirely, delete it, `scripts/parity-normalize.py` and `parity-check.md`.
- **`scripts/verify-deps.sh`:** nothing to change; its only Go reference is a comment noting the help credit
  line was copied from the Go CLI (reword it if you like).
- **`CLAUDE.md`:** rewrite the intro ("Go CLI plus SwiftUI app"), the Commands section, the Architecture and
  Conventions sections (they describe the Go packages, `urfave/cli`, `bubbletea`) and the safety-invariant
  references to `profiles_test.go`/`delta()` so they point at the Swift sources and tests. Remove the
  "keep both implementations in step" rule and the `make swift-gen` rule.
- **`CONTRIBUTING.md`:** remove the Go gate (`make check`, `make format` Go half) and the paragraph about
  keeping both implementations in step.
- **`README.md`:** remove the "Upstream Go version (MobAI)" install block and the Go library section, or
  turn them into a link to the upstream repository. Keep the credit to MobAI/Interlap, the license line and the
  copyright lines, and the Status paragraph (reword it to say parity was checked against the Go reference
  tagged `go-reference-final`).
- **`docs/swift-port-plan.md`:** mark the Go removal done; add the tag name.
- **Other docs** (`docs/category-memory.md`, `docs/disk-cleanup.md`): search them for `.go` file names and
  `go ` commands and point them at the Swift sources.

## After the change

```sh
git grep -n -i -E '\bgo (build|test|vet)|\.go\b|go\.mod|gen_catalog|SIMSLIM_CLI_IMPL|GO_BIN'
make app-check swift-lint swift-test verify-deps
VERSION=0.0.0 make app
```

The `git grep` should only match the places that deliberately mention the Go reference (README credit, the
parity docs, this page). Everything else is a leftover. Then run the app once (`open build/SimSlim.app`) and
confirm the CI `swift` job is green.

## Things to keep in mind

- **The catalog stops being checked against a source of truth.** Today a mistake in a daemon list fails
  `swift-gen-check`. After removal the Swift catalog tests (`ProfilesTests`, `FeaturesTests`, the forbidden
  labels test) are the only guard, so keep them.
- **Upstream changes no longer flow in for free.** To adopt a later upstream fix, diff against the
  `go-reference-final` tag or the upstream repository and port it by hand.
- **Rollback:** the tag keeps the whole Go tree recoverable (`git checkout go-reference-final -- <path>`).
  The app also still accepts `SIMSLIM_CLI=<path>` at runtime to run any other `simslim` binary.
