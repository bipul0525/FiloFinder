# Contributing to FiloFinder

Thanks for helping! Bug reports, ideas and pull requests are all welcome.

## Build
See [Build from source](README.md#build-from-source). In short:

```sh
scripts/build.sh --debug --run
cd core && cargo test
```

## Guidelines
- All filesystem changes go through the Rust core (`core/`); the Swift UI never deletes or moves files itself.
- Keep it fast: no blocking work on the main thread.
- Match Finder's behaviour and shortcuts unless there's a good reason not to.
- Run `cargo test` and try the change in light and dark mode before opening a PR.
