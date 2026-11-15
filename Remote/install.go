package main

import (
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
)

const launcherMark = "# Peek remote launcher v1"

func shellQuote(s string) string { return "'" + strings.ReplaceAll(s, "'", "'\\''") + "'" }
func atomicCopy(source, destination string) error {
	in, err := os.Open(source)
	if err != nil {
		return err
	}
	defer in.Close()
	st, err := in.Stat()
	if err != nil {
		return err
	}
	if !st.Mode().IsRegular() {
		return errors.New("helper is not a regular file")
	}
	tmp, err := os.CreateTemp(filepath.Dir(destination), ".peek-remote-")
	if err != nil {
		return err
	}
	defer os.Remove(tmp.Name())
	if err = tmp.Chmod(0700); err == nil {
		_, err = io.Copy(tmp, in)
	}
	if err == nil {
		err = tmp.Sync()
	}
	closeErr := tmp.Close()
	if err == nil {
		err = closeErr
	}
	if err != nil {
		return err
	}
	return os.Rename(tmp.Name(), destination)
}
func launcherOwned(path string) bool {
	st, err := os.Lstat(path)
	if err != nil || !st.Mode().IsRegular() {
		return false
	}
	f, err := os.Open(path)
	if err != nil {
		return false
	}
	defer f.Close()
	data, err := io.ReadAll(io.LimitReader(f, 8193))
	return err == nil && len(data) <= 8192 && strings.HasPrefix(string(data), "#!/bin/sh\n"+launcherMark+"\n")
}
func sameRegularFile(a, b string) bool {
	sa, errA := os.Stat(a)
	sb, errB := os.Lstat(b)
	return errA == nil && errB == nil && sb.Mode().IsRegular() && os.SameFile(sa, sb) && privateFile(b)
}
func install(home, exe string) (string, error) {
	binDir := filepath.Join(home, ".local/share/peek/bin")
	if err := privateHomeDir(home, ".local/share/peek/bin"); err != nil {
		return "", err
	}
	fallback := filepath.Join(binDir, "peek-remote")
	if !sameRegularFile(exe, fallback) {
		if err := atomicCopy(exe, fallback); err != nil {
			return "", err
		}
	}
	launcherDir := filepath.Join(home, ".local/bin")
	if err := os.MkdirAll(launcherDir, 0755); err != nil {
		return shellQuote(fallback), nil
	}
	// Do not write through a .local/bin symlink or replace a command found earlier
	// on PATH, even when ~/.local/bin/peek itself is absent.
	resolved, err := filepath.EvalSymlinks(launcherDir)
	realHome, homeErr := filepath.EvalSymlinks(home)
	if err != nil || homeErr != nil || resolved != filepath.Join(realHome, ".local/bin") {
		return shellQuote(fallback), nil
	}
	launcher := filepath.Join(launcherDir, "peek")
	if _, err := os.Lstat(launcher); err == nil && !launcherOwned(launcher) {
		return shellQuote(fallback), nil
	} else if err != nil && !os.IsNotExist(err) {
		return shellQuote(fallback), nil
	}
	if existing, err := lookPathPeek(); err == nil && filepath.Clean(existing) != launcher && !launcherOwned(existing) {
		return shellQuote(fallback), nil
	}
	body := []byte(fmt.Sprintf("#!/bin/sh\n%s\nexec %s \"$@\"\n", launcherMark, shellQuote(fallback)))
	// Link a fully written temporary launcher into an absent path atomically;
	// this cannot overwrite a command installed by someone else concurrently.
	tmp, err := os.CreateTemp(launcherDir, ".peek-launcher-")
	if err != nil {
		return shellQuote(fallback), nil
	}
	defer os.Remove(tmp.Name())
	if err = tmp.Chmod(0700); err == nil {
		_, err = tmp.Write(body)
	}
	closeErr := tmp.Close()
	if err == nil {
		err = closeErr
	}
	if err != nil {
		return shellQuote(fallback), nil
	}
	if launcherOwned(launcher) {
		// Our stable launcher already forwards to the atomically updated fallback.
		return shellQuote(launcher), nil
	}
	if err := os.Link(tmp.Name(), launcher); err != nil {
		if os.IsExist(err) {
			return shellQuote(fallback), nil
		}
		return shellQuote(fallback), nil
	}
	return shellQuote(launcher), nil
}
