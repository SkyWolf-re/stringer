# Contributing to stringer

This file tells you the minimum you need to land a change without drama.

## Scope

CLI string extractor in Zig **0.15.1**. Fast, stable text/JSON output. Lives under the **REVenge** umbrella.  
This repo stores core logic only, no TUIs or SDKs.  

## How to contribute

1. Fork → small branch → PR to `main`.
2. One change per PR.
3. Explain *what* and *why*. Add a quick example of workflow.

## Setup

```
zig version   # must be 0.15.1
zig build     # debug build
zig build -Doptimize=ReleaseFast -Dstrip=true -Dcpu=baseline 
```

Binary lives in `zig-out/bin/stringer`.

## Style

* Run `zig fmt --check .` before committing.
* Clear functions; explicit error handling.
* Public flags/outputs must be documented in `README.md`.

## Tests

* `zig build check` & `zig build it-cli` must pass.
* Keep fixtures tiny and license‑clean. No malware/copyrighted blobs.

## Commits

Write whatever you want as long as it's coherent.

```
feat: add --min-len
fixed utf16 off-by-one
fewer allocs in scan because of bla bla bla
```

## CI basics (what your PR must satisfy)

* `zig fmt --check .`
* `zig build check`
* `zig build it-cli`
* Builds on Linux/macOS (matrix handled by repo CI)

## Security

Found a security issue? Contact me directly: `contact-baltoor@proton.me`. Don’t open a public issue.

## Licensing

By contributing you agree your code is under this repo’s LICENSE.

```
Signed-off-by: SkyWolf-re
```

## Release notes

Maintainers curate the changelog. If your change is user‑visible, propose a one‑liner under **Unreleased** in `CHANGELOG.md`.

Thanks for keeping it lightweight and sharp.
