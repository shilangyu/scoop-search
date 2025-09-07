# scoop-search

[![](https://github.com/shilangyu/scoop-search/workflows/ci/badge.svg)](https://github.com/shilangyu/scoop-search/actions)

Fast `scoop search` drop-in replacement 🚀

## Installation

```sh
scoop install scoop-search
```

## PowerShell hook

Instead of using `scoop-search.exe <term>` you can create a hook that will run `scoop-search.exe` whenever you use native `scoop search`

Add this to your Powershell profile (usually located at `$PROFILE`)

```ps1
. ([ScriptBlock]::Create((& scoop-search --hook | Out-String)))
```

## CMD.exe wrapper

If you use `cmd.exe` you can use a wrapper script to do the same. Name this `scoop.cmd` and add it to
a directory in your `%PATH%`

```
@echo off

if "%1" == "search" (
    call :search_subroutine %*
) else (
    powershell scoop.ps1 %*
)
goto :eof

:search_subroutine
set "args=%*"
set "newargs=%args:* =%"
scoop-search.exe %newargs%
goto :eof
```

## Features

Behaves just like `scoop search` and returns identical output. If any differences are found please open an issue.

**Non-goal**: any additional features unavailable in scoop search

## Building

This project uses Zig. Building and running works on all platforms, not only Windows.

Build with (output is stored in `./zig-out/bin`):

```sh
zig build -Doptimize=ReleaseFast
```

Run debug with:

```sh
zig build run -- searchterm
```

## Benchmarks

Done with [hyperfine](https://github.com/sharkdp/hyperfine). `scoop-search` is on average 350 times faster.

```sh
❯ hyperfine --warmup 1 'scoop-search google' 'scoop search google'
Benchmark 1: scoop-search google
  Time (mean ± σ):      60.3 ms ±   3.5 ms    [User: 91.2 ms, System: 394.2 ms]
  Range (min … max):    55.1 ms …  73.8 ms    49 runs

Benchmark 2: scoop search google
  Time (mean ± σ):     21.275 s ±  2.657 s    [User: 9.604 s, System: 11.789 s]
  Range (min … max):   19.143 s … 27.035 s    10 runs

Summary
  scoop-search google ran
  352.74 ± 48.49 times faster than scoop search google
```

_ran on AMD Ryzen 5 3600 @ 3.6GHz_
