# Contributing to GitWolf

Thanks for helping out! This guide covers the basics.

## Getting started

1. Fork and clone the repository.
2. Follow the build steps in the [README](README.md#building-macos).
3. Run `swift test` from `apple/` before opening a pull request.

## Ground rules

- **Keep platform code in its platform folder.** Apple code goes in `apple/`. Anything a future
  port would need to know about (behaviour, git command formats) belongs in `docs/`.
- **Use the system `git` binary.** Do not add libgit2 or other Git implementations.
- **Read-only commands must pass `readOnly: true`** so background refreshes never take index locks.
- **Parse with `-z` / `--porcelain`.** Never parse human-oriented git output.
- **UI must not flicker.** Only assign state that actually changed; keep row heights fixed.
- **Add tests** for parsers, graph layout and git operations. UI-free logic lives in
  `GitWolfCore` so it can be tested.

## Pull requests

- Keep PRs focused; one change per PR.
- Describe what changed and why; include screenshots for UI changes.
- Make sure CI passes.
- Use clear, imperative commit messages ("Add stash pop to sidebar").

## Reporting bugs and requesting features

Use the issue templates. For bugs include your macOS version, Git version, and steps to reproduce.
