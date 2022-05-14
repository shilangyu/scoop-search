package main

import (
	"fmt"
	"io/ioutil"
	"log"
	"net/http"
	"os"
	"path/filepath"
	"regexp"
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
		var err error
		res, err = os.UserHomeDir()
		checkWith(err, "Could not determine home dir")

		res += "\\scoop"
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
	var hasResult bool
	hasResult = printResults(matches.data, false)
	if !hasResult && !githubRatelimitReached() {
		hasResult = printResults(searchRemoteAll(args.query), true)
	}

	if !hasResult {
		fmt.Println("No matches found.")
		os.Exit(1)
	}
}

func githubRatelimitReached() bool {
	var parser fastjson.Parser

	response, err := http.Get("https://api.github.com/rate_limit")
	check(err)

	raw, err := ioutil.ReadAll(response.Body)
	check(err)

	parse, _ := parser.ParseBytes(raw)
	json, _ := parse.Object()

	return json.Get("resources").Get("core").GetInt("limit") == 0
}

func searchRemoteAll(term string) matchMap {
	var parser fastjson.Parser

	raw, err := os.ReadFile(scoopHome() + "\\apps\\scoop\\current\\buckets.json")
	check(err)

	result, _ := parser.ParseBytes(raw)
	object, _ := result.Object()
	var buckets []string
	object.Visit(func(k []byte, v *fastjson.Value) {
		_, err := os.Stat(scoopHome() + "\\buckets\\" + string(k))
		if os.IsNotExist(err) {
			buckets = append(buckets, string(k))
		}
	})

	matches := struct {
		sync.Mutex
		data matchMap
	}{}
	matches.data = make(matchMap)
	var wg sync.WaitGroup
	for _, bucket := range buckets {
		wg.Add(1)
		go func(b string) {
			res := searchRemote(b, term)
			matches.Lock()
			matches.data[b] = res
			matches.Unlock()
			wg.Done()
		}(bucket)
	}
	wg.Wait()
	return matches.data
}

func searchRemote(bucket string, term string) []match {
	var parser fastjson.Parser

	raw, err := os.ReadFile(scoopHome() + "\\apps\\scoop\\current\\buckets.json")
	check(err)

	result, _ := parser.ParseBytes(raw)
	bucketURL := string(result.GetStringBytes(bucket))
	bucketSplit := strings.Split(bucketURL, "/")
	apiLink := "https://api.github.com/repos/" + bucketSplit[len(bucketSplit)-2] + "/" + bucketSplit[len(bucketSplit)-1] + "/git/trees/HEAD?recursive=1"

	response, err := http.Get(apiLink)
	check(err)

	raw, err = ioutil.ReadAll(response.Body)
	check(err)

	json, _ := parser.ParseBytes(raw)
	fileTree := json.GetArray("tree")

	regex := regexp.MustCompile("(?i)^(?:bucket/)?(.*" + term + ".*)\\.json$")

	matches := struct {
		sync.Mutex
		data []match
	}{}
	var wg sync.WaitGroup

	for _, file := range fileTree {
		wg.Add(1)
		go func(path []byte) {
			matching := regex.FindSubmatch(path)
			if len(matching) > 1 {
				matches.Lock()
				matches.data = append(matches.data, match{name: string(matching[1]), version: "", bin: ""})
				matches.Unlock()
			}
			wg.Done()
		}(file.GetStringBytes("path"))
	}
	wg.Wait()
	return matches.data
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
						// check only first two, the rest are command flags
						stringArray := stringOrArray.GetArray()
						bins = append(bins, string(stringArray[0].GetStringBytes()))
						if len(stringArray) > 1 {
							bins = append(bins, string(stringArray[1].GetStringBytes()))
						}
					default:
						log.Fatalln(badManifestErrMsg)
					}
				}
			default:
				log.Fatalln(badManifestErrMsg)
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

func printResults(data matchMap, fromKnownBucket bool) (anyMatches bool) {
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
		}
	}

	if fromKnownBucket && anyMatches {
		fmt.Println("Results from other known buckets...")
		fmt.Println("(add them using 'scoop bucket add <name>')")
		fmt.Println()
	}

	for _, k := range sortedKeys {
		v := data[k]

		if len(v) > 0 {
			display.WriteString("'")
			display.WriteString(k)
			display.WriteString("' bucket")
			if fromKnownBucket {
				display.WriteString(" (install using 'scoop install ")
				display.WriteString(k)
				display.WriteString("/<app>'):\n")
			} else {
				display.WriteString(":\n")
			}
			for _, m := range v {
				display.WriteString("    ")
				display.WriteString(m.name)
				if !fromKnownBucket {
					display.WriteString(" (")
					display.WriteString(m.version)
					display.WriteString(")")
				}
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

	os.Stdout.WriteString(display.String())
	return
}
