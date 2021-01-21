package main

import (
	"encoding/json"
	"fmt"
	"log"
)

func checkWith(err error, msg string) {
	if err != nil {
		log.Fatal(msg, " - ", err)
	}
}

func check(err error) {
	if err != nil {
		log.Fatal(err)
	}
}

func pp(data interface{}) {
	pretty, _ := json.MarshalIndent(data, "", " ")
	fmt.Println(string(pretty))
}
