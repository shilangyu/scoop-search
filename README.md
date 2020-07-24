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
Invoke-Expression (& { (scoop-search --hook) -join "`n" })
```

## Features

Behaves just like `scoop search`. If any differences are found please open an issue.

**Non-goal**: any additional features unavailable in scoop search
