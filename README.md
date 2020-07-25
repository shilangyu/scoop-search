# scoop-search

[![](https://goreportcard.com/badge/github.com/shilangyu/scoop-search)](https://goreportcard.com/report/github.com/shilangyu/scoop-search)
[![](https://github.com/shilangyu/scoop-search/workflows/ci/badge.svg)](https://github.com/shilangyu/scoop-search/actions)

Fast `scoop search` drop-in replacement 🚀

## Installation

With Go:

```sh
go get github.com/shilangyu/scoop-search
```

Or grab an executable from the [release page](https://github.com/shilangyu/scoop-search/releases) and add it to your `PATH`.

## Hook

Instead of using `scoop-search.exe <term>` you can setup a hook that will run `scoop-search.exe` whenever you use native `scoop search`

Add this to your Powershell profile (usually located at `$PROFILE`)

```ps1
Invoke-Expression (&scoop-search --hook)
```

## Features

Behaves just like `scoop search` and returns [<sub>almost</sub>](https://github.com/shilangyu/scoop-search/issues/3) identical output. If any differences are found please open an issue.

**Non-goal**: any additional features unavailable in scoop search

## Benchmarks

Done with [hyperfine](https://github.com/sharkdp/hyperfine). `scoop-search` is on average 30 times faster.

```sh
❯ hyperfine --warmup 1 'scoop-search google' 'scoop search google'
Benchmark #1: scoop-search google
  Time (mean ± σ):     124.9 ms ±   2.2 ms    [User: 2.6 ms, System: 2.8 ms]
  Range (min … max):   122.8 ms … 131.4 ms    23 runs

Benchmark #2: scoop search google
  Time (mean ± σ):      3.862 s ±  0.006 s    [User: 7.4 ms, System: 5.2 ms]
  Range (min … max):    3.852 s …  3.873 s    10 runs

Summary
  'scoop-search google' ran
   30.93 ± 0.55 times faster than 'scoop search google'
```

_ran on AMD Ryzen 5 3600 @ 3.6GHz_
