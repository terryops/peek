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
	"syscall"
)

const version = "1.0.0"

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
	flags := flag.NewFlagSet("peek", flag.ContinueOnError)
	flags.SetOutput(stderr)
	title := flags.String("t", "", "title")
	conversation := flags.String("c", os.Getenv("PEEK_CONVERSATION"), "conversation")
	source := flags.String("s", "project", "source")
	to := flags.String("to", os.Getenv("PEEK_TARGET"), "target UUID or unique name")
	list := flags.Bool("list-targets", false, "list online targets")
	showVersion := flags.Bool("version", false, "show version")
	flags.Usage = func() {
		fmt.Fprintln(stderr, "Usage: peek [-t title] [-c conversation] [-s source] [--to target] files…\n       peek --list-targets | --version | --help")
	}
	if err := flags.Parse(args); err != nil {
		if err == flag.ErrHelp {
			return nil
		}
		return err
	}
	if *showVersion {
		fmt.Fprintf(stdout, "peek-remote %s (protocol 1)\n", version)
		return nil
	}
	if *list {
		ts, err := discover(home)
		if err != nil {
			return err
		}
		for _, t := range ts {
			fmt.Fprintf(stdout, "%s\t%s\n", t.ID, t.Name)
		}
		return nil
	}
	if flags.NArg() == 0 {
		flags.Usage()
		return fmt.Errorf("at least one file is required")
	}
	m, files, err := collect(flags.Args(), *title, *conversation, *source)
	if err != nil {
		return err
	}
	if err := send(ctx, home, *to, m, files); err != nil {
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
