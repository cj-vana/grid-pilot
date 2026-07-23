# Contributing to GridPilot

Thanks for looking. This project is small on purpose; keep it that way.

## Setup

```sh
git clone https://github.com/cj-vana/grid-pilot.git
cd grid-pilot
swift test          # 54 tests, no hardware needed
./scripts/make-app.sh
```

You don't need a Grid to work on most of the codebase. Everything hardware- or
permission-touching is behind injectable closures (`Executors`) or isolated
wrappers (`PrivateAPIs.swift`), and the tests use fakes.

## Ground rules

- **No third-party dependencies.** The entire point is a single small binary.
- **Test what's testable.** Logic (routing, validation, parsing, zone math)
  gets unit tests. Thin AppKit glue doesn't need them.
- **Private APIs stay quarantined.** dlopen/dlsym in `PrivateAPIs.swift` only,
  fail-soft, never let a broken symbol take down an unrelated feature.
- **Errors go to the log and the menu-bar badge**, never modal popups.
- **Match the code around you.** If your diff looks different in style from
  the file it's in, it isn't done.

## Adding a builtin action

1. Add an entry to `Builtins.all` (name, input kind, required params, one-line doc).
2. Add a case to `ActionRegistry.run`.
3. Add a routing test in `ActionTests.swift` with a spy executor.

The validator and the AI schema are generated from the catalog, so there is no
step 4.

## Supporting another controller

Controls are named CCs in the config; nothing hardcodes the PBF4 beyond the
default names P1-P4/F1-F4/B1-B4 and the learn-mode order. A PR adding another
module mostly means a new default control set and learn sequence.

## PRs

- Run `swift test` before pushing. CI runs it too and red CI doesn't merge.
- Keep PRs focused; one feature or fix each.
- Explain the why in the description, not just the what.
