package main

import "os"

type parsedArgs struct {
	query string
	hook  bool
	all   bool
}

func parseArgs() parsedArgs {
	var all, hook bool
	var query string

	if len(os.Args) == 1 {
		all = true
	} else if os.Args[1] == "--hook" {
		hook = true
	} else {
		query = os.Args[1]
	}

	return parsedArgs{query, hook, all}
}

const poshHook = `function scoop { if ($args[0] -eq "search") { scoop-search.exe @($args | Select-Object -Skip 1) } else { scoop.ps1 @args } }`
