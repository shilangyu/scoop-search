package main

import (
	"fmt"
	"io/ioutil"
	"log"
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

	// start workers that will find matching manifests
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

	var parser fastjson.Parser

	for _, file := range files {
		name := file.Name()

		// its not a manifest, skip
		if !strings.HasSuffix(name, ".json") {
			continue
		}

		// parse relevant data from manifest
		raw, err := ioutil.ReadFile(path + "\\" + name)
		check(err)
		result, _ := parser.ParseBytes(raw)

		version := string(result.GetStringBytes("version"))

		if strings.Contains(name, term) {
			// the name matches
			res = append(res, match{name[:len(name)-5], version, ""})
		} else {
			// the name did not match, lets see if any binary files do
			var bins []string
			bin := result.Get("bin")

			if bin == nil {
				// no binaries
				continue
			}

			const badManifestErrMsg = `Cannot parse "bin" attribute in a manifest. This should not happen. Please open an issue about it with steps to reproduce`

			switch bin.Type() {
			case fastjson.TypeString:
				bins = append(bins, string(bin.GetStringBytes()))
			case fastjson.TypeArray:
				for _, stringOrArray := range bin.GetArray() {
					switch stringOrArray.Type() {
					case fastjson.TypeString:
						bins = append(bins, string(stringOrArray.GetStringBytes()))
					case fastjson.TypeArray:
						// unhandled
					default:
						log.Fatalln(badManifestErrMsg)
					}
				}
			default:
				log.Fatalln(badManifestErrMsg)
			}

			for _, bin := range bins {
				bin = filepath.Base(bin)
				if strings.Contains(strings.TrimSuffix(bin, filepath.Ext(bin)), term) {
					res = append(res, match{name[:len(name)-5], version, bin})
					break
				}
			}
		}
	}

	sort.SliceStable(res, func(i, j int) bool {
		return strings.ToLower(res[i].name) < strings.ToLower(res[j].name)
	})

	return
}

func printResults(data matchMap) (anyMatches bool) {

	// sort by bucket names
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
					fmt.Printf(" --> includes '%s'", m.bin)
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
