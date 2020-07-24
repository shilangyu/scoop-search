# scoop-search

Fast `scoop search` drop-in replacement 🚀

## Installation

With Go:

```sh
go get github.com/shilangyu/scoop-search
```

Or grab an executable from the [release page](https://github.com/shilangyu/scoop-search/releases) and add it to PATH.

## Hook

Instead of using `scoop-search.exe <term>` you can setup a hook that will run `scoop-search.exe` whenever you use native `scoop search`.

Add this to your Powershell profile (usually located at `$PROFILE`)

```ps1
Invoke-Expression (&scoop-search --hook)
```

## Features

Behaves just like `scoop search`. If any differences are found please open an issue.

**Non-goal**: any additional features unavailable in scoop search
