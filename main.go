package main

import (
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"sync"

	"github.com/valyala/fastjson"
)

type match struct {
	name, version, bin string
}

type matchMap = map[string][]match

// resolves the path to scoop folder
func scoopHome() (res string) {
	if value, ok := os.LookupEnv("SCOOP"); ok {
		res = value
	} else {
		var configHome string

		home, err := os.UserHomeDir()
		checkWith(err, "Could not determine home dir")

		if value, ok = os.LookupEnv("XDG_CONFIG_HOME"); ok {
			configHome = value
		} else {
			configHome = home + "\\.config"
		}

		configPath := configHome + "\\scoop\\config.json"
		if content, err := os.ReadFile(configPath); err == nil {
			var parser fastjson.Parser
			config, _ := parser.ParseBytes(content)
			res = string(config.GetStringBytes("root_path"))
		}

		// installing with default directory doesn't have `SCOOP`
		// and `root_path` either
		if res == "" {
			res = home + "\\scoop"
		}
	}

	return
}

func main() {
	args := parseArgs()

	// print posh hook and exit if requested
	if args.hook {
		fmt.Println(poshHook)
		os.Exit(0)
	}

	// get buckets path
	bucketsPath := scoopHome() + "\\buckets"

	// get specific buckets
	buckets, err := os.ReadDir(bucketsPath)
	checkWith(err, "Scoop folder does not exist")

	// start workers that will find matching manifests
	matches := struct {
		sync.Mutex
		data matchMap
	}{}
	matches.data = make(matchMap)
	var wg sync.WaitGroup

	for _, bucket := range buckets {
		if !bucket.IsDir() {
			continue
		}

		wg.Add(1)
		go func(file os.DirEntry) {
			// check if $bucketName/bucket exists, if not use $bucketName
			bucketPath := bucketsPath + "\\" + file.Name()
			if f, err := os.Stat(bucketPath + "\\bucket"); !os.IsNotExist(err) && f.IsDir() {
				bucketPath += "\\bucket"
			}

			res := matchingManifests(bucketPath, args.query)
			matches.Lock()
			matches.data[file.Name()] = res
			matches.Unlock()
			wg.Done()
		}(bucket)
	}
	wg.Wait()

	// print results and exit with status code
	if !printResults(matches.data) {
		os.Exit(1)
	}
}

func matchingManifests(path string, term string) (res []match) {
	term = strings.ToLower(term)
	files, err := os.ReadDir(path)
	check(err)

	var parser fastjson.Parser

	for _, file := range files {
		name := file.Name()

		// its not a manifest, skip
		if !strings.HasSuffix(name, ".json") {
			continue
		}

		// parse relevant data from manifest
		raw, err := os.ReadFile(path + "\\" + name)
		check(err)
		result, _ := parser.ParseBytes(raw)

		version := string(result.GetStringBytes("version"))

		stem := name[:len(name)-5]

		if strings.Contains(strings.ToLower(stem), term) {
			// the name matches
			res = append(res, match{stem, version, ""})
		} else {
			// the name did not match, lets see if any binary files do
			var bins []string
			bin := result.Get("bin") // can be: nil, string, [](string | []string)

			if bin == nil {
				// no binaries
				continue
			}

			switch bin.Type() {
			case fastjson.TypeString:
				bins = append(bins, string(bin.GetStringBytes()))
			case fastjson.TypeArray:
				for _, stringOrArray := range bin.GetArray() {
					switch stringOrArray.Type() {
					case fastjson.TypeString:
						bins = append(bins, string(stringOrArray.GetStringBytes()))
					case fastjson.TypeArray:
						// check only first two, the rest are command flags
						stringArray := stringOrArray.GetArray()
						bins = append(bins, string(stringArray[0].GetStringBytes()))
						if len(stringArray) > 1 {
							bins = append(bins, string(stringArray[1].GetStringBytes()))
						}
					}
				}
			}

			for _, bin := range bins {
				bin = filepath.Base(bin)
				if strings.Contains(strings.ToLower(strings.TrimSuffix(bin, filepath.Ext(bin))), term) {
					res = append(res, match{stem, version, bin})
					break
				}
			}
		}
	}

	sort.SliceStable(res, func(i, j int) bool {
		// case insensitive comparison where hyphens are ignored
		return strings.ToLower(strings.ReplaceAll(res[i].name, "-", "")) <= strings.ToLower(strings.ReplaceAll(res[j].name, "-", ""))
	})

	return
}

func printResults(data matchMap) (anyMatches bool) {
	// sort by bucket names
	entries := 0
	sortedKeys := make([]string, 0, len(data))
	for k := range data {
		entries += len(data[k])
		sortedKeys = append(sortedKeys, k)
	}
	sort.Strings(sortedKeys)

	// reserve additional space assuming each variable string has length 1. Will save time on initial allocations
	var display strings.Builder
	display.Grow((len(sortedKeys)*12 + entries*11))

	for _, k := range sortedKeys {
		v := data[k]

		if len(v) > 0 {
			anyMatches = true
			display.WriteString("'")
			display.WriteString(k)
			display.WriteString("' bucket:\n")
			for _, m := range v {
				display.WriteString("    ")
				display.WriteString(m.name)
				display.WriteString(" (")
				display.WriteString(m.version)
				display.WriteString(")")
				if m.bin != "" {
					display.WriteString(" --> includes '")
					display.WriteString(m.bin)
					display.WriteString("'")
				}
				display.WriteString("\n")
			}
			display.WriteString("\n")
		}
	}

	if !anyMatches {
		display.WriteString("No matches found.")
	}

	os.Stdout.WriteString(display.String())
	return
}
