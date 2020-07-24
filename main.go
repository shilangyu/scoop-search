package main

import (
	"encoding/json"
	"fmt"
	"io/ioutil"
	"log"
	"os"
	"reflect"
	"sort"
	"strings"
	"sync"
)

type match struct {
	name, version, bin string
}

type matchMap = map[string][]match

func main() {
	args := parseArgs()

	// print posh hook and exit if requested
	if args.hook {
		fmt.Println(poshHook)
		os.Exit(0)
	}

	// get buckets path
	homeDir, err := os.UserHomeDir()
	checkWith(err, "Could not determine home dir")
	bucketsPath := homeDir + "\\scoop\\buckets"

	// get specific buckets
	buckets, err := ioutil.ReadDir(bucketsPath)
	checkWith(err, "Scoop folder does not exist")

	// start workers that will find matching names
	matches := struct {
		sync.Mutex
		data matchMap
	}{}
	matches.data = make(matchMap)
	var wg sync.WaitGroup

	for _, bucket := range buckets {
		wg.Add(1)
		go func(file os.FileInfo) {
			matches.Lock()
			matches.data[file.Name()] = matchingManifests(bucketsPath+"\\"+file.Name()+"\\bucket", args.query)
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
	files, err := ioutil.ReadDir(path)
	check(err)

	jsonBuf := struct {
		Version string
		Bin     interface{} // can be: nil, string, []string
	}{}

	for _, file := range files {
		name := file.Name()

		// its not a manifest, skip
		if !strings.HasSuffix(name, ".json") {
			continue
		}
		raw, err := ioutil.ReadFile(path + "\\" + name)
		check(err)
		json.Unmarshal(raw, &jsonBuf)

		if strings.Contains(name, term) {
			res = append(res, match{name, jsonBuf.Version, ""})
		} else {
			var bins []string
			if jsonBuf.Bin == nil {
				continue
			} else if val, ok := jsonBuf.Bin.([]interface{}); ok {
				for _, bin := range val {
					if binStr, ok := bin.(string); ok {
						bins = append(bins, binStr)
					}
				}
			} else if val, ok := jsonBuf.Bin.(string); ok {
				bins = []string{val}
			} else {
				log.Fatalln("Cannot parse \"bin\" attribute in a manifest. This should not happen. Please open an issue about it. \nDump:", reflect.TypeOf(jsonBuf.Bin))
			}

			for _, bin := range bins {
				if strings.Contains(bin, term) {
					res = append(res, match{name, jsonBuf.Version, bin})
					break
				}
			}
		}
	}

	return
}

func printResults(data matchMap) (anyMatches bool) {

	sortedKeys := make([]string, 0, len(data))
	for k := range data {
		sortedKeys = append(sortedKeys, k)
	}
	sort.Strings(sortedKeys)

	for _, k := range sortedKeys {
		v := data[k]

		if len(v) > 0 {
			anyMatches = true
			fmt.Printf("'%s' bucket:\n", k)
			for _, m := range v {
				fmt.Printf("    %s (%s)", m.name, m.version)
				if m.bin != "" {
					fmt.Printf(` --> includes "%s"`, m.bin)
				}
				fmt.Println()
			}
			fmt.Println()
		}
	}

	if !anyMatches {
		fmt.Println("No matches found.")
	}

	return
}
