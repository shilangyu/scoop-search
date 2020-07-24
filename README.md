# scoop-search

Drop-in replacement for `scoop search <term>`.

## Installation

With Go:

```sh
go get github.com/shilangyu/scoop-search
```

Or grab an excecutable from the [release page](https://github.com/shilangyu/scoop-search/releases) and add it to PATH.

## Hook

Instead of using `scoop-search.exe <term>` you can setup a hook that will run `scoop-search.exe` whenever you use native `scoop search`.

```sh
scoop-search --hook >> $PROFILE
```

## Features
