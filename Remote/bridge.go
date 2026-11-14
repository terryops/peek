package main

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"syscall"
	"time"
)

const transferTimeout = 2 * time.Minute

type Target struct {
	ID        string `json:"id"`
	Name      string `json:"name"`
	Socket    string `json:"socket"`
	Instance  string `json:"instance"`
	CreatedAt int64  `json:"createdAt"`
}
type incoming struct {
	m   Message
	err error
}

func privateDir(dir string) error {
	if err := os.MkdirAll(dir, 0700); err != nil {
		return err
	}
	st, err := os.Lstat(dir)
	if err != nil {
		return err
	}
	sys, ok := st.Sys().(*syscall.Stat_t)
	if !st.IsDir() || st.Mode()&os.ModeSymlink != 0 || !ok || int(sys.Uid) != os.Getuid() || st.Mode().Perm()&0077 != 0 {
		return fmt.Errorf("unsafe private directory: %s", dir)
	}
	return nil
}

// Home-managed state must not escape through a pre-existing directory symlink.
// Parent directories may be readable, but must remain owned and non-writable by others.
func privateHomeDir(home, relative string) error {
	realHome, err := filepath.EvalSymlinks(home)
	if err != nil {
		return err
	}
	current := realHome
	parts := strings.Split(filepath.ToSlash(relative), "/")
	for i, part := range parts {
		current = filepath.Join(current, part)
		if err := os.Mkdir(current, 0700); err != nil && !os.IsExist(err) {
			return err
		}
		st, err := os.Lstat(current)
		if err != nil {
			return err
		}
		sys, ok := st.Sys().(*syscall.Stat_t)
		if !ok || !st.IsDir() || st.Mode()&os.ModeSymlink != 0 || int(sys.Uid) != os.Getuid() || st.Mode().Perm()&0022 != 0 {
			return fmt.Errorf("unsafe Peek directory: %s", current)
		}
		if i == len(parts)-1 && st.Mode().Perm()&0077 != 0 {
			return fmt.Errorf("Peek directory must be private: %s", current)
		}
	}
	return nil
}
func targetDir(home string) (string, error) {
	dir := filepath.Join(home, ".local/share/peek/targets")
	return dir, privateHomeDir(home, ".local/share/peek/targets")
}
func runtimeDir() (string, error) {
	dir := filepath.Join("/tmp", fmt.Sprintf("peek-%d", os.Getuid()))
	return dir, privateDir(dir)
}
func socketPath(home, id, instance string) (string, error) {
	dir, err := runtimeDir()
	if err != nil {
		return "", err
	}
	hash := sha256.Sum256([]byte(home + "\x00" + id))
	return filepath.Join(dir, hex.EncodeToString(hash[:8])+"-"+strings.ReplaceAll(instance, "-", "")[:16]+".sock"), nil
}
func privateFile(path string) bool {
	st, err := os.Lstat(path)
	if err != nil {
		return false
	}
	sys, ok := st.Sys().(*syscall.Stat_t)
	return ok && int(sys.Uid) == os.Getuid() && st.Mode().IsRegular() && st.Mode().Perm()&0077 == 0
}
func discover(home string) ([]Target, error) {
	dir, err := targetDir(home)
	if err != nil {
		return nil, err
	}
	entries, err := os.ReadDir(dir)
	if err != nil {
		return nil, err
	}
	latest := map[string]Target{}
	var targets []Target
	for _, entry := range entries {
		p := filepath.Join(dir, entry.Name())
		if !strings.HasSuffix(entry.Name(), ".json") || !privateFile(p) {
			continue
		}
		f, err := os.Open(p)
		if err != nil {
			continue
		}
		data, err := io.ReadAll(io.LimitReader(f, 8193))
		f.Close()
		if err != nil || len(data) > 8192 {
			continue
		}
		var target Target
		if json.Unmarshal(data, &target) != nil || !uuidPattern.MatchString(target.ID) || !uuidPattern.MatchString(target.Instance) || entry.Name() != target.ID+"-"+target.Instance+".json" {
			continue
		}
		expected, err := socketPath(home, target.ID, target.Instance)
		if err != nil || expected != target.Socket {
			continue
		}
		st, err := os.Lstat(target.Socket)
		if err != nil || st.Mode()&os.ModeSocket == 0 || st.Mode().Perm()&0077 != 0 {
			continue
		}
		conn, err := net.DialTimeout("unix", target.Socket, 150*time.Millisecond)
		if err != nil {
			continue
		}
		conn.Close()
		key := strings.ToLower(target.ID)
		if previous, ok := latest[key]; !ok || target.CreatedAt > previous.CreatedAt || (target.CreatedAt == previous.CreatedAt && target.Instance > previous.Instance) {
			latest[key] = target
		}
	}
	for _, target := range latest {
		targets = append(targets, target)
	}
	sort.Slice(targets, func(i, j int) bool { return targets[i].ID < targets[j].ID })
	return targets, nil
}
func selectTarget(targets []Target, selector string) (Target, error) {
	if selector == "" && len(targets) == 1 {
		return targets[0], nil
	}
	var matches []Target
	for _, t := range targets {
		if selector != "" && (t.ID == selector || t.Name == selector) {
			matches = append(matches, t)
		}
	}
	if len(matches) == 1 {
		return matches[0], nil
	}
	var choices []string
	for _, t := range targets {
		choices = append(choices, fmt.Sprintf("%s (%s)", t.Name, t.ID))
	}
	if len(targets) == 0 {
		return Target{}, errors.New("no connected Peek targets")
	}
	return Target{}, fmt.Errorf("select a unique target with --to or PEEK_TARGET: %s", strings.Join(choices, ", "))
}
func bridge(ctx context.Context, home, id, name, command string, input io.Reader, output io.Writer) error {
	if !uuidPattern.MatchString(id) {
		return errors.New("invalid target UUID")
	}
	if len(name) > 1024 || len(command) > 4096 {
		return errors.New("target metadata too long")
	}
	dir, err := targetDir(home)
	if err != nil {
		return err
	}
	instance, err := newUUID()
	if err != nil {
		return err
	}
	socket, err := socketPath(home, id, instance)
	if err != nil {
		return err
	}
	// Every SSH bridge owns a unique endpoint, allowing overlapping reconnects.
	listener, err := net.Listen("unix", socket)
	if err != nil {
		return fmt.Errorf("target already connected or socket unavailable: %w", err)
	}
	defer listener.Close()
	if err := os.Chmod(socket, 0600); err != nil {
		return err
	}
	target := Target{ID: id, Name: name, Socket: socket, Instance: instance, CreatedAt: time.Now().UnixNano()}
	data, _ := json.Marshal(target)
	descriptor := filepath.Join(dir, id+"-"+instance+".json")
	tmp, err := os.CreateTemp(dir, ".target-")
	if err != nil {
		return err
	}
	tmpName := tmp.Name()
	defer os.Remove(tmpName)
	if err = tmp.Chmod(0600); err == nil {
		_, err = tmp.Write(data)
	}
	closeErr := tmp.Close()
	if err == nil {
		err = closeErr
	}
	if err != nil {
		return err
	}
	if err = os.Rename(tmpName, descriptor); err != nil {
		return err
	}
	defer os.Remove(descriptor)
	bridgeCtx, cancel := context.WithCancel(ctx)
	defer cancel()
	go func() {
		<-bridgeCtx.Done()
		listener.Close()
		if c, ok := input.(io.Closer); ok {
			c.Close()
		}
		if c, ok := output.(io.Closer); ok {
			c.Close()
		}
	}()
	readyDone := make(chan error, 1)
	go func() {
		readyDone <- writeFrame(output, Message{Version: 1, Kind: "ready", TargetID: id, TargetName: name, Command: command})
	}()
	readyTimer := time.NewTimer(transferTimeout)
	defer readyTimer.Stop()
	select {
	case err := <-readyDone:
		if err != nil {
			return err
		}
	case <-ctx.Done():
		return ctx.Err()
	case <-readyTimer.C:
		return errors.New("ready frame timed out")
	}
	// Read independently so idle SSH EOF tears down a stale target immediately.
	acks := make(chan incoming, 1)
	go func() {
		for {
			var m Message
			err := readFrame(input, &m)
			select {
			case acks <- incoming{m, err}:
			case <-bridgeCtx.Done():
				return
			}
			if err != nil {
				return
			}
		}
	}()
	accepted := make(chan net.Conn)
	go func() {
		defer close(accepted)
		for {
			conn, err := listener.Accept()
			if err != nil {
				return
			}
			select {
			case accepted <- conn:
			case <-bridgeCtx.Done():
				conn.Close()
				return
			}
		}
	}()
	for {
		select {
		case <-ctx.Done():
			return ctx.Err()
		case a := <-acks:
			if a.err != nil {
				return fmt.Errorf("receiver disconnected: %w", a.err)
			}
			return errors.New("unexpected receiver acknowledgement")
		case conn, ok := <-accepted:
			if !ok {
				return errors.New("socket listener stopped")
			}
			err := relay(bridgeCtx, conn, output, acks)
			conn.Close()
			if err != nil {
				return err
			}
		}
	}
}
func relay(ctx context.Context, conn net.Conn, output io.Writer, acks <-chan incoming) error {
	// Closing the listener cannot interrupt an already accepted connection.
	// Watch this connection for the complete relay lifetime, including reads of
	// partial headers/bodies and writes of acknowledgements or error responses.
	finished := make(chan struct{})
	defer close(finished)
	go func() {
		select {
		case <-ctx.Done():
			conn.Close()
		case <-finished:
		}
	}()
	_ = conn.SetDeadline(time.Now().Add(transferTimeout))
	var m Message
	if err := readFrame(conn, &m); err != nil {
		if errors.Is(err, io.EOF) {
			return nil
		}
		_ = writeFrame(conn, negative(m.RequestID, err))
		return nil
	}
	if err := validatePush(m); err != nil {
		_ = writeFrame(conn, negative(m.RequestID, err))
		return nil
	}
	done := make(chan error, 1)
	go func() {
		if err := writeFrame(output, m); err != nil {
			done <- err
			return
		}
		for _, f := range m.Files {
			hash := sha256.New()
			if _, err := io.CopyN(io.MultiWriter(output, hash), conn, f.Size); err != nil {
				done <- err
				return
			}
			if hex.EncodeToString(hash.Sum(nil)) != f.SHA256 {
				done <- errors.New("body SHA256 mismatch")
				return
			}
		}
		done <- nil
	}()
	timer := time.NewTimer(transferTimeout)
	defer timer.Stop()
	fail := func(err error) error {
		_ = writeFrame(conn, negative(m.RequestID, err))
		if c, ok := output.(io.Closer); ok {
			c.Close()
		}
		return err
	}
	select {
	case err := <-done:
		if err != nil {
			return fail(err)
		}
	case <-ctx.Done():
		return fail(ctx.Err())
	case <-timer.C:
		return fail(errors.New("transfer timed out"))
	}
	select {
	case a := <-acks:
		if a.err != nil {
			return fail(fmt.Errorf("receiver disconnected: %w", a.err))
		}
		if a.m.Version != 1 || a.m.Kind != "ack" || a.m.RequestID != m.RequestID || len(a.m.Error) > maxError {
			return fail(errors.New("invalid receiver acknowledgement"))
		}
		return writeFrame(conn, a.m)
	case <-ctx.Done():
		return fail(ctx.Err())
	case <-timer.C:
		return fail(errors.New("receiver acknowledgement timed out"))
	}
}
func negative(id string, err error) Message {
	s := err.Error()
	if len(s) > maxError {
		s = s[:maxError]
	}
	return Message{Version: 1, Kind: "ack", RequestID: id, Error: s}
}
func send(ctx context.Context, home, selector string, m Message, files []localFile) error {
	if err := validatePush(m); err != nil {
		return err
	}
	if len(files) != len(m.Files) {
		return errors.New("manifest/file count mismatch")
	}
	targets, err := discover(home)
	if err != nil {
		return err
	}
	target, err := selectTarget(targets, selector)
	if err != nil {
		return err
	}
	conn, err := (&net.Dialer{Timeout: 5 * time.Second}).DialContext(ctx, "unix", target.Socket)
	if err != nil {
		return err
	}
	defer conn.Close()
	_ = conn.SetDeadline(time.Now().Add(transferTimeout))
	finished := make(chan struct{})
	defer close(finished)
	go func() {
		select {
		case <-ctx.Done():
			conn.Close()
		case <-finished:
		}
	}()
	if err := writeFrame(conn, m); err != nil {
		return err
	}
	for i, lf := range files {
		file, err := lf.open()
		if err != nil {
			return err
		}
		hash := sha256.New()
		n, copyErr := io.CopyN(io.MultiWriter(conn, hash), file, m.Files[i].Size)
		var extra [1]byte
		more, _ := file.Read(extra[:])
		file.Close()
		if copyErr != nil {
			return copyErr
		}
		if n != m.Files[i].Size || more != 0 || hex.EncodeToString(hash.Sum(nil)) != m.Files[i].SHA256 {
			return errors.New("source file changed during transfer")
		}
	}
	var ack Message
	if err := readFrame(conn, &ack); err != nil {
		return fmt.Errorf("delivery not acknowledged: %w", err)
	}
	return validateAck(ack, m.RequestID)
}
