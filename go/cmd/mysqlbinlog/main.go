package main

import (
	"fmt"
	"os"

	"github.com/edidada/mysql-binlog-lib/go/binlog"
)

func usage() {
	fmt.Fprintf(os.Stderr, "Usage: %s --file <path> [--format jsonl]\n", os.Args[0])
}

func main() {
	var file string
	format := "jsonl"
	args := os.Args[1:]
	for i := 0; i < len(args); i++ {
		switch args[i] {
		case "--help":
			usage()
			return
		case "--file":
			if i+1 >= len(args) {
				usage()
				os.Exit(2)
			}
			file = args[i+1]
			i++
		case "--format":
			if i+1 >= len(args) {
				usage()
				os.Exit(2)
			}
			format = args[i+1]
			i++
		default:
			fmt.Fprintf(os.Stderr, "unknown argument: %s\n", args[i])
			usage()
			os.Exit(2)
		}
	}
	if file == "" {
		usage()
		os.Exit(2)
	}
	if format != "jsonl" {
		fmt.Fprintln(os.Stderr, "only --format jsonl is supported")
		os.Exit(2)
	}
	data, err := os.ReadFile(file)
	if err != nil {
		fmt.Fprintf(os.Stderr, "cannot open file: %s: %v\n", file, err)
		os.Exit(2)
	}
	if err := binlog.ParseBuffer(data, os.Stdout); err != nil {
		fmt.Fprintf(os.Stderr, "parse failed: %v\n", err)
		os.Exit(1)
	}
}
