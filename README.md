# stringer

A fast, cross-platform string extractor written in Zig. Scans memory-mapped files for ASCII/UTF-8 (ASCII subset) and UTF-16 (LE/BE) strings with multi-threaded chunking and deterministic output.

--- 

## Why string extraction matters in RE

Strings are the lowest-effort, highest-signal artifact that can be pulled from a binary. A fast strings pass often tells us what the program does before we ever open a disassembler.

### What strings reveal

- Intent clues: error messages, feature names, log prefixes, usage/help text.
- IO targets: file paths, registry keys, service names, IPC channels, sockets/ports.
- Network intel: domains, URLs, API endpoints, user-agents.
- Crypto & packers: algorithm names (AES, RC4), library banners, packer tags.
- Locale & UX: supported languages, UI labels → hints at target platforms/users.
- Config & toggles: env var names, flags (--debug, --safe-mode, -k).

### Why it speeds up analysis

- Triage: decides if a sample is worth deeper work (malware family, tool category).
- Scoping: identifies subsystems to focus on.
- X-refs: takes a distinctive string, then cross-reference it in the disassembler to jump straight to relevant functions.
- De-obfuscation baseline: after unpacking or dumping process memory, compares string sets to confirm actually revealed new code/paths.

---

## Features (MVP)

ASCII/“UTF-8-lite” (printable bytes) detector

UTF-16LE (optional UTF-16BE) detector

Per-hit offset, type, and length

--min-len threshold (default 5)

Multi-threaded chunk scan with boundary overlap

---

## Text or JSON output

POSIX & Windows file mapping; - reads from stdin (no mmap)

---

## Install / Build
```
# Zig 0.15.x+ recommended
zig build -Drelease-fast
# binary at: zig-out/bin/stringer
```

## Quick start
```
# Basic ASCII + UTF-16LE scan
stringer ./a.out

# JSON output for pipelines
stringer --json ./a.out | jq

# Adjust minimum length
stringer --min-len 8 ./a.out

# Choose encodings (comma-separated)
stringer --enc ascii,utf16le ./a.out

# Use all cores
stringer --threads auto ./a.out

# Read from stdin
cat blob.bin | stringer -
```

## Example output

Text:

```
0001F3B0  ascii    len=12  "Invalid key"
0002A1D8  utf16le  len=10  "Hello, UI"
```

JSON:

```
{"offset":127536,"kind":"ascii","len":12,"text":"Invalid key"}
{"offset":172248,"kind":"utf16le","len":10,"text":"Hello, UI"}
```

CLI
```
stringer [options] <file|->

Options:
  --min-len N         Minimum characters per hit (default 5)
  --enc LIST          ascii,utf16le,utf16be,all  (default: ascii,utf16le)
  --threads N|auto    Worker threads (default: 1 or auto if set)
  --json              Emit JSON lines instead of text
  --offset            Always print file offset (on by default in text)
  --null-only         Require a terminator (\0 or 0x0000) before emit
  --cap-run-bytes N   Truncate very long runs (default 4096)
  --version           Print version and exit
  -h, --help          Show help
```

---

## How it works (short)

Two detectors:

ASCII: runs of 0x20..0x7E (+ \t \n \r if enabled).

UTF-16LE/BE: pairs with a zero high/low byte and printable ASCII in the other byte.

Chunking: file is split into N slices with overlap so strings crossing boundaries aren’t missed.

Overlap = minlen-1 bytes for ASCII, 2*(minlen-1) for UTF-16.

Offsets: hits report absolute file byte offsets.

## Limitations (MVP)

UTF-8 validation is off by default (ASCII subset only).

No section-aware fast mode (ELF/PE) yet.

Packed/obfuscated strings require dynamic memory dumps (out of scope for MVP).

---

## License

MIT (see LICENSE).  

---

## Credits

Built for fast, secure reverse-engineering workflows (and to spread the Zig language)   
Author: @skywolf-re  
Contributions welcome!