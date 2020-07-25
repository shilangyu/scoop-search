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

Done with [hyperfine](https://github.com/sharkdp/hyperfine). `scoop-search` is on average 26 times faster.

```sh
❯ hyperfine --warmup 1 'scoop-search google' 'scoop search google'
Benchmark #1: scoop-search google
  Time (mean ± σ):     146.1 ms ±   3.1 ms    [User: 2.5 ms, System: 3.6 ms]
  Range (min … max):   143.5 ms … 155.1 ms    18 runs

Benchmark #2: scoop search google
  Time (mean ± σ):      4.028 s ±  0.222 s    [User: 1.5 ms, System: 10.4 ms]
  Range (min … max):    3.866 s …  4.564 s    10 runs

Summary
  'scoop-search google' ran
   27.57 ± 1.63 times faster than 'scoop search google'
```

_ran on AMD Ryzen 5 3600 @ 3.6GHz_
