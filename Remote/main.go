// peek-remote is a dependency-free sender and SSH stdio bridge for Peek.
package main

import (
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"strings"
	"syscall"
)

const version = "1.1.0"

type senderOptions struct {
	title        string
	conversation string
	source       string
	to           string
	listTargets  bool
	showVersion  bool
	showHelp     bool
	files        []string
}

func printSenderUsage(w io.Writer) {
	fmt.Fprintln(w, "Usage: peek [-t|--title title] [-c|--conversation name] [-s|--source source] [--to target] files…\n       peek --list-targets | --version | --help")
}

func parseSenderArgs(args []string) (senderOptions, error) {
	opts := senderOptions{
		conversation: os.Getenv("PEEK_CONVERSATION"),
		source:       os.Getenv("PEEK_SOURCE"),
		to:           os.Getenv("PEEK_TARGET"),
	}
	optionsDone := false
	for i := 0; i < len(args); i++ {
		a := args[i]
		if !optionsDone {
			if a == "--" {
				optionsDone = true
				continue
			}
			if strings.HasPrefix(a, "-") && len(a) > 1 {
				name, val, hasEq := strings.Cut(a, "=")
				nextVal := func() (string, error) {
					if hasEq {
						return val, nil
					}
					if i+1 >= len(args) {
						return "", fmt.Errorf("flag needs an argument: %s", name)
					}
					i++
					return args[i], nil
				}
				switch name {
				case "-h", "-help", "--help":
					opts.showHelp = true
					continue
				case "-v", "-version", "--version":
					opts.showVersion = true
					continue
				case "-list-targets", "--list-targets":
					opts.listTargets = true
					continue
				case "-t", "--t", "-title", "--title":
					v, err := nextVal()
					if err != nil {
						return opts, err
					}
					opts.title = v
					continue
				case "-c", "--c", "-conversation", "--conversation":
					v, err := nextVal()
					if err != nil {
						return opts, err
					}
					opts.conversation = v
					continue
				case "-s", "--s", "-source", "--source":
					v, err := nextVal()
					if err != nil {
						return opts, err
					}
					opts.source = v
					continue
				case "-to", "--to":
					v, err := nextVal()
					if err != nil {
						return opts, err
					}
					opts.to = v
					continue
				default:
					return opts, fmt.Errorf("unknown flag: %s", name)
				}
			}
		}
		opts.files = append(opts.files, a)
	}
	return opts, nil
}

func lookPathPeek() (string, error) { return exec.LookPath("peek") }
func defaultCommand(home string) string {
	launcher := filepath.Join(home, ".local/bin/peek")
	if launcherOwned(launcher) {
		return shellQuote(launcher)
	}
	return shellQuote(filepath.Join(home, ".local/share/peek/bin/peek-remote"))
}
func run(ctx context.Context, args []string, stdout, stderr io.Writer) error {
	home, err := os.UserHomeDir()
	if err != nil {
		return err
	}
	if len(args) > 0 && args[0] == "install" {
		if len(args) != 1 {
			return fmt.Errorf("install accepts no arguments")
		}
		exe, err := os.Executable()
		if err != nil {
			return err
		}
		command, err := install(home, exe)
		if err != nil {
			return err
		}
		return json.NewEncoder(stdout).Encode(map[string]string{"command": command})
	}
	if len(args) > 0 && args[0] == "bridge" {
		flags := flag.NewFlagSet("bridge", flag.ContinueOnError)
		flags.SetOutput(stderr)
		id := flags.String("target", "", "target UUID")
		name := flags.String("name", "", "target name")
		command := flags.String("command", defaultCommand(home), "sender command")
		if err := flags.Parse(args[1:]); err != nil {
			return err
		}
		if flags.NArg() != 0 {
			return fmt.Errorf("unexpected bridge arguments")
		}
		return bridge(ctx, home, *id, *name, *command, os.Stdin, stdout)
	}
	opts, err := parseSenderArgs(args)
	if err != nil {
		printSenderUsage(stderr)
		return err
	}
	if opts.showHelp {
		printSenderUsage(stderr)
		return nil
	}
	if opts.showVersion {
		fmt.Fprintf(stdout, "peek-remote %s (protocol 1)\n", version)
		return nil
	}
	if opts.listTargets {
		ts, err := discover(home)
		if err != nil {
			return err
		}
		for _, t := range ts {
			fmt.Fprintf(stdout, "%s\t%s\n", t.ID, t.Name)
		}
		return nil
	}
	if len(opts.files) == 0 {
		printSenderUsage(stderr)
		return fmt.Errorf("at least one file is required")
	}
	m, files, err := collect(opts.files, opts.title, opts.conversation, opts.source)
	if err != nil {
		return err
	}
	if err := send(ctx, home, opts.to, m, files); err != nil {
		return err
	}
	fmt.Fprintln(stdout, "Delivered to Peek")
	return nil
}
func main() {
	ctx, cancel := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer cancel()
	if err := run(ctx, os.Args[1:], os.Stdout, os.Stderr); err != nil {
		fmt.Fprintln(os.Stderr, "peek:", err)
		os.Exit(1)
	}
}
