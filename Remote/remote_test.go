package main

import (
	"bytes"
	"context"
	"encoding/binary"
	"fmt"
	"io"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"syscall"
	"testing"
	"time"
)

const testID = "12345678-1234-4234-8234-123456789abc"

func fixture(t *testing.T, path, data string) string {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte(data), 0600); err != nil {
		t.Fatal(err)
	}
	return path
}
func TestFrameFragmentationAndLimits(t *testing.T) {
	var b bytes.Buffer
	if err := writeFrame(&b, Message{Version: 1, Kind: "ack", RequestID: testID, OK: true}); err != nil {
		t.Fatal(err)
	}
	r, w := io.Pipe()
	go func() {
		defer w.Close()
		for _, v := range b.Bytes() {
			_, _ = w.Write([]byte{v})
		}
	}()
	var m Message
	if err := readFrame(r, &m); err != nil || !m.OK {
		t.Fatalf("fragmented frame: %+v %v", m, err)
	}
	for _, n := range []uint32{0, 1048577} {
		var h [4]byte
		binary.BigEndian.PutUint32(h[:], n)
		if readFrame(bytes.NewReader(h[:]), &m) == nil {
			t.Fatalf("accepted frame length %d", n)
		}
	}
	if writeFrame(io.Discard, Message{Version: 1, Kind: "ack", Error: strings.Repeat("x", 1048576)}) == nil {
		t.Fatal("accepted oversized write")
	}
}
func TestManifestRejectsUnsafeRequests(t *testing.T) {
	p := Message{Version: 1, Kind: "push", RequestID: testID, Files: []File{{Path: "0/a", Name: "a", Original: "/tmp/a", Size: 0, SHA256: strings.Repeat("a", 64), Primary: true}}}
	if err := validatePush(p); err != nil {
		t.Fatal(err)
	}
	for _, path := range []string{"/a", "a//b", "a/../b", "a/./b", "a\\b", "a\x00b", ""} {
		q := p
		q.Files = append([]File(nil), p.Files...)
		q.Files[0].Path = path
		if validatePush(q) == nil {
			t.Errorf("accepted path %q", path)
		}
	}
	cases := []Message{p, p, p, p, p, p, p, p, p}
	cases[0].Version = 2
	cases[1].Kind = "ready"
	cases[2].RequestID = "bad"
	cases[3].Files = nil
	for i := 4; i < len(cases); i++ {
		cases[i].Files = append([]File(nil), p.Files...)
	}
	cases[4].Files[0].Size = -1
	cases[5].Files[0].Size = 64*1024*1024 + 1
	cases[6].Files[0].Primary = false
	cases[7].Files[0].SHA256 = strings.Repeat("A", 64)
	cases[8].Files = append(cases[8].Files, cases[8].Files[0])
	for i, q := range cases {
		if validatePush(q) == nil {
			t.Errorf("accepted invalid manifest %d", i)
		}
	}
	q := p
	q.Files = make([]File, 301)
	if validatePush(q) == nil {
		t.Fatal("accepted 301 files")
	}
}
func TestCollectAssetsAndDuplicateBasenames(t *testing.T) {
	root := t.TempDir()
	outside := fixture(t, filepath.Join(root, "secret.txt"), "secret")
	a := fixture(t, filepath.Join(root, "one/report.html"), `<img src="assets/a.png"><link href="style.css"><img src="leak"><img src="https://example.com/x">`)
	fixture(t, filepath.Join(root, "one/assets/a.png"), "image")
	fixture(t, filepath.Join(root, "one/style.css"), `body{background:url('assets/b.png')}`)
	fixture(t, filepath.Join(root, "one/assets/b.png"), "background")
	if err := os.Symlink(outside, filepath.Join(root, "one/leak")); err != nil {
		t.Fatal(err)
	}
	b := fixture(t, filepath.Join(root, "two/report.html"), `<img src="assets/a.png">`)
	fixture(t, filepath.Join(root, "two/assets/a.png"), "other")
	p, paths, err := collect([]string{a, b}, "title", "conversation", "project")
	if err != nil {
		t.Fatal(err)
	}
	if len(p.Files) != 6 || len(paths) != 6 {
		t.Fatalf("want two primaries plus four assets, got %+v", p.Files)
	}
	seen := map[string]bool{}
	for _, f := range p.Files {
		if strings.Contains(f.Original, "secret") || strings.HasSuffix(f.Path, "leak") {
			t.Fatalf("symlink leaked: %+v", f)
		}
		seen[f.Path] = true
	}
	for _, s := range []string{"0/report.html", "0/assets/a.png", "0/style.css", "0/assets/b.png", "1/report.html", "1/assets/a.png"} {
		if !seen[s] {
			t.Errorf("missing %s", s)
		}
	}
}

func TestCollectLocallySupportedDocumentFormats(t *testing.T) {
	for _, tc := range []struct {
		ext, document, asset, content, hash string
	}{
		{"xhtml", `<img src="xhtml-image.png"/><link href="style.css"/>`, "xhtml-image.png", "xhtml-image", "921419e28f7c3162fa1d3ddb53452d87e74a4427981804664cfe26509452a3e5"},
		{"mdown", `![inline image](mdown-image.png)`, "mdown-image.png", "mdown-image", "cd298c04e24025fdca0151730e16a4fd1bdf104fcbb776177872ef66959bad74"},
		{"mkd", "![reference image][pic]\n\n[pic]: mkd-image.png", "mkd-image.png", "mkd-image", "dc5f1dde14fd853adcfbd059225926fac2a64f4d2d82bbc9aeebb518a1c84747"},
	} {
		t.Run(tc.ext, func(t *testing.T) {
			root := t.TempDir()
			doc := fixture(t, filepath.Join(root, "report."+tc.ext), tc.document)
			fixture(t, filepath.Join(root, tc.asset), tc.content)
			fixture(t, filepath.Join(root, "style.css"), `body{background:url("xhtml-background.png")}`)
			fixture(t, filepath.Join(root, "xhtml-background.png"), "xhtml-background")
			manifest, locals, err := collect([]string{doc}, "", "", "project")
			if err != nil {
				t.Fatal(err)
			}
			wantCount := 2
			if tc.ext == "xhtml" {
				wantCount = 4
			}
			if len(manifest.Files) != wantCount || len(locals) != wantCount {
				t.Fatalf("want %d files with local resources, got %+v", wantCount, manifest.Files)
			}
			byPath := map[string]File{}
			for _, f := range manifest.Files {
				byPath[f.Path] = f
			}
			if !byPath["0/report."+tc.ext].Primary {
				t.Fatal("document must remain primary")
			}
			asset := byPath["0/"+tc.asset]
			if asset.SHA256 != tc.hash || asset.Size != int64(len(tc.content)) || asset.Primary {
				t.Fatalf("missing or corrupt referenced asset: %+v", asset)
			}
			if tc.ext == "xhtml" {
				if _, ok := byPath["0/style.css"]; !ok {
					t.Fatal("stylesheet omitted")
				}
				if byPath["0/xhtml-background.png"].SHA256 != "e0625577739cbbbecd28a172ee1ba883ee221c8d2fb763b268544e297b62b4ff" {
					t.Fatal("CSS recursion omitted or corrupted its image")
				}
			}
		})
	}
}

type bridgeFixture struct {
	home   string
	output *io.PipeReader
	ack    *io.PipeWriter
	cancel context.CancelFunc
	done   chan error
}

func startBridge(t *testing.T, home, id, name string) bridgeFixture {
	t.Helper()
	input, ack := io.Pipe()
	outputReader, output := io.Pipe()
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan error, 1)
	go func() {
		defer close(done)
		defer output.Close()
		done <- bridge(ctx, home, id, name, "peek", input, output)
	}()
	var ready Message
	if err := readFrame(outputReader, &ready); err != nil {
		t.Fatalf("ready: %v", err)
	}
	if ready.Kind != "ready" || ready.TargetID != id {
		t.Fatalf("bad ready %+v", ready)
	}
	t.Cleanup(func() {
		cancel()
		ack.Close()
		outputReader.Close()
		select {
		case <-done:
		case <-time.After(3 * time.Second):
			t.Error("bridge did not stop")
		}
	})
	return bridgeFixture{home, outputReader, ack, cancel, done}
}
func TestBridgeWaitsForReceiverAcknowledgement(t *testing.T) {
	h := t.TempDir()
	b := startBridge(t, h, testID, "Laptop")
	p, paths, err := collect([]string{fixture(t, filepath.Join(h, "report.txt"), "hello")}, "", "", "project")
	if err != nil {
		t.Fatal(err)
	}
	done := make(chan error, 1)
	go func() { done <- send(context.Background(), h, "", p, paths) }()
	var got Message
	if err := readFrame(b.output, &got); err != nil {
		t.Fatal(err)
	}
	body := make([]byte, 5)
	if _, err := io.ReadFull(b.output, body); err != nil || string(body) != "hello" {
		t.Fatalf("body: %q %v", body, err)
	}
	select {
	case err := <-done:
		t.Fatalf("returned before ack: %v", err)
	case <-time.After(80 * time.Millisecond):
	}
	if err := writeFrame(b.ack, Message{Version: 1, Kind: "ack", RequestID: got.RequestID, OK: true, CardID: "card"}); err != nil {
		t.Fatal(err)
	}
	select {
	case err := <-done:
		if err != nil {
			t.Fatal(err)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("sender did not receive ack")
	}
}
func TestBridgeNegativeAckAndInterruptedReceiver(t *testing.T) {
	for _, interrupt := range []bool{false, true} {
		t.Run(map[bool]string{false: "negative", true: "interrupted"}[interrupt], func(t *testing.T) {
			h := t.TempDir()
			b := startBridge(t, h, testID, "Mac")
			p, paths, _ := collect([]string{fixture(t, filepath.Join(h, "a"), "a")}, "", "", "project")
			done := make(chan error, 1)
			go func() { done <- send(context.Background(), h, "", p, paths) }()
			var got Message
			if err := readFrame(b.output, &got); err != nil {
				t.Fatal(err)
			}
			_, _ = io.CopyN(io.Discard, b.output, 1)
			if interrupt {
				b.ack.Close()
			} else {
				_ = writeFrame(b.ack, Message{Version: 1, Kind: "ack", RequestID: got.RequestID, Error: "receiver rejected"})
			}
			select {
			case err := <-done:
				if err == nil {
					t.Fatal("claimed delivery without positive ack")
				}
			case <-time.After(2 * time.Second):
				t.Fatal("sender hung")
			}
		})
	}
}
func TestMultipleTargetsRequireExplicitSelection(t *testing.T) {
	h := t.TempDir()
	_ = startBridge(t, h, testID, "Mac")
	_ = startBridge(t, h, "87654321-4321-4321-8321-cba987654321", "Mac")
	ts, err := discover(h)
	if err != nil || len(ts) != 2 {
		t.Fatalf("targets: %+v %v", ts, err)
	}
	if _, err := selectTarget(ts, ""); err == nil {
		t.Fatal("silently selected one of two targets")
	}
	if _, err := selectTarget(ts, "Mac"); err == nil {
		t.Fatal("accepted ambiguous name")
	}
	if got, err := selectTarget(ts, testID); err != nil || got.ID != testID {
		t.Fatalf("explicit UUID: %+v %v", got, err)
	}
}
func TestInstallPreservesUnrelatedLauncher(t *testing.T) {
	h := t.TempDir()
	t.Setenv("PATH", filepath.Join(h, "empty-path"))
	exe := fixture(t, filepath.Join(h, "uploaded"), "binary")
	existing := fixture(t, filepath.Join(h, ".local/bin/peek"), "#!/bin/sh\necho other\n")
	command, err := install(h, exe)
	if err != nil {
		t.Fatal(err)
	}
	data, _ := os.ReadFile(existing)
	if string(data) != "#!/bin/sh\necho other\n" {
		t.Fatal("overwrote unrelated command")
	}
	if command != "'"+filepath.Join(h, ".local/share/peek/bin/peek-remote")+"'" {
		t.Fatalf("bad fallback %s", command)
	}
	h2 := t.TempDir()
	command, err = install(h2, exe)
	if err != nil || command != "'"+filepath.Join(h2, ".local/bin/peek")+"'" {
		t.Fatalf("fresh install: %s %v", command, err)
	}
}

func TestAckAlwaysContainsExplicitBoolean(t *testing.T) {
	var b bytes.Buffer
	if err := writeFrame(&b, Message{Version: 1, Kind: "ack", RequestID: testID, Error: "rejected"}); err != nil {
		t.Fatal(err)
	}
	if !bytes.Contains(b.Bytes()[4:], []byte(`"ok":false`)) {
		t.Fatalf("negative ack lacks explicit false: %s", b.Bytes()[4:])
	}
}
func TestOverlappingBridgeReconnectKeepsNewestTarget(t *testing.T) {
	h := t.TempDir()
	first := startBridge(t, h, testID, "Old")
	second := startBridge(t, h, testID, "New")
	ts, err := discover(h)
	if err != nil || len(ts) != 1 || ts[0].Name != "New" {
		t.Fatalf("new bridge must supersede old: %+v %v", ts, err)
	}
	first.cancel()
	first.ack.Close()
	select {
	case <-first.done:
	case <-time.After(2 * time.Second):
		t.Fatal("old bridge did not stop")
	}
	deadline := time.Now().Add(2 * time.Second)
	for time.Now().Before(deadline) {
		ts, err = discover(h)
		if err == nil && len(ts) == 1 && ts[0].Name == "New" {
			break
		}
		time.Sleep(5 * time.Millisecond)
	}
	if len(ts) != 1 || ts[0].Name != "New" {
		t.Fatalf("old cleanup removed new target: %+v %v", ts, err)
	}
	p, files, err := collect([]string{fixture(t, filepath.Join(h, "a"), "b")}, "", "", "project")
	if err != nil {
		t.Fatal(err)
	}
	done := make(chan error, 1)
	go func() { done <- send(context.Background(), h, "", p, files) }()
	var got Message
	if err := readFrame(second.output, &got); err != nil {
		t.Fatal(err)
	}
	_, _ = io.CopyN(io.Discard, second.output, 1)
	_ = writeFrame(second.ack, Message{Version: 1, Kind: "ack", RequestID: got.RequestID, OK: true, CardID: "new"})
	select {
	case err := <-done:
		if err != nil {
			t.Fatal(err)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("new bridge did not deliver")
	}
}
func TestSenderCancellationCannotReportSuccess(t *testing.T) {
	h := t.TempDir()
	b := startBridge(t, h, testID, "Mac")
	p, files, err := collect([]string{fixture(t, filepath.Join(h, "a"), "a")}, "", "", "project")
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan error, 1)
	go func() { done <- send(ctx, h, "", p, files) }()
	var got Message
	if err := readFrame(b.output, &got); err != nil {
		t.Fatal(err)
	}
	_, _ = io.CopyN(io.Discard, b.output, 1)
	cancel()
	select {
	case err := <-done:
		if err == nil {
			t.Fatal("cancelled send succeeded")
		}
	case <-time.After(2 * time.Second):
		t.Fatal("cancelled send hung")
	}
}

func TestAssetRootRejectsAncestorSymlinksAndDirectories(t *testing.T) {
	root := t.TempDir()
	outside := t.TempDir()
	fixture(t, filepath.Join(outside, "private.png"), "secret")
	doc := fixture(t, filepath.Join(root, "report.md"), "![x](escape/private.png)\n![x](folder)\n![ok](inside.png)\n")
	fixture(t, filepath.Join(root, "inside.png"), "safe")
	if err := os.Mkdir(filepath.Join(root, "folder"), 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(outside, filepath.Join(root, "escape")); err != nil {
		t.Fatal(err)
	}
	m, _, err := collect([]string{doc}, "", "", "project")
	if err != nil {
		t.Fatal(err)
	}
	if len(m.Files) != 2 || m.Files[1].Path != "0/inside.png" {
		t.Fatalf("unsafe assets collected: %+v", m.Files)
	}
	if _, _, err := collect([]string{root}, "", "", "project"); err == nil {
		t.Fatal("accepted directory primary")
	}
}
func TestFrameRejectsUnsupportedMessagesAndInvalidUTF8(t *testing.T) {
	for _, body := range [][]byte{[]byte(`{"version":2,"kind":"ack"}`), []byte(`{"version":1,"kind":"unknown"}`), {0xff}} {
		var b bytes.Buffer
		var header [4]byte
		binary.BigEndian.PutUint32(header[:], uint32(len(body)))
		b.Write(header[:])
		b.Write(body)
		var m Message
		if readFrame(&b, &m) == nil {
			t.Fatalf("accepted invalid frame %q", body)
		}
	}
}
func TestManifestTotalSizeBoundary(t *testing.T) {
	p := Message{Version: 1, Kind: "push", RequestID: testID, Files: []File{{Path: "0/a", Size: 32 * 1024 * 1024, SHA256: strings.Repeat("a", 64), Primary: true}, {Path: "0/b", Size: 32 * 1024 * 1024, SHA256: strings.Repeat("b", 64)}}}
	if err := validatePush(p); err != nil {
		t.Fatal(err)
	}
	p.Files[1].Size++
	if validatePush(p) == nil {
		t.Fatal("accepted combined body over 64 MiB")
	}
}

func TestBridgeCancellationWhileReadyIsUnread(t *testing.T) {
	input, ack := io.Pipe()
	defer ack.Close()
	reader, output := io.Pipe()
	defer reader.Close()
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan error, 1)
	go func() { done <- bridge(ctx, t.TempDir(), testID, "Mac", "peek", input, output) }()
	time.Sleep(20 * time.Millisecond)
	cancel()
	select {
	case <-done:
	case <-time.After(300 * time.Millisecond):
		t.Fatal("bridge stuck writing ready after cancellation")
	}
}
func TestFrameDoesNotReuseMissingFields(t *testing.T) {
	var m Message
	var data bytes.Buffer
	for _, body := range []string{`{"version":1,"kind":"ack","ok":true}`, `{"kind":"ack","ok":true}`} {
		var h [4]byte
		binary.BigEndian.PutUint32(h[:], uint32(len(body)))
		data.Write(h[:])
		data.WriteString(body)
	}
	if err := readFrame(&data, &m); err != nil {
		t.Fatal(err)
	}
	if readFrame(&data, &m) == nil {
		t.Fatal("missing version inherited previous frame version")
	}
}
func TestOriginUsesExistingRexEnvironment(t *testing.T) {
	t.Setenv("REX_SESSION", "session")
	t.Setenv("REX_BLOCK", "block")
	p, _, err := collect([]string{fixture(t, filepath.Join(t.TempDir(), "a"), "a")}, "", "", "project")
	if err != nil {
		t.Fatal(err)
	}
	if p.Origin == nil || p.Origin.RexSession != "session" || p.Origin.RexBlock != "block" {
		t.Fatalf("missing Rex origin: %+v", p.Origin)
	}
}
func TestInstallRejectsProductDirectorySymlink(t *testing.T) {
	h := t.TempDir()
	outside := t.TempDir()
	exe := fixture(t, filepath.Join(h, "uploaded"), "binary")
	if err := os.MkdirAll(filepath.Join(h, ".local/share"), 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(outside, filepath.Join(h, ".local/share/peek")); err != nil {
		t.Fatal(err)
	}
	if _, err := install(h, exe); err == nil {
		t.Fatal("installed helper outside user's home through a symlink")
	}
	if _, err := os.Stat(filepath.Join(outside, "bin/peek-remote")); !os.IsNotExist(err) {
		t.Fatal("modified symlink destination")
	}
}
func TestAckRejectsSuccessWithoutCardID(t *testing.T) {
	if validateAck(Message{Version: 1, Kind: "ack", RequestID: testID, OK: true}, testID) == nil {
		t.Fatal("accepted malformed success acknowledgement without card ID")
	}
}

func TestNonRegularAssetCannotBlockCollection(t *testing.T) {
	root := t.TempDir()
	fifo := filepath.Join(root, "pipe")
	if err := syscall.Mkfifo(fifo, 0600); err != nil {
		t.Fatal(err)
	}
	doc := fixture(t, filepath.Join(root, "a.html"), `<img src="pipe">`)
	done := make(chan error, 1)
	go func() {
		m, _, err := collect([]string{doc}, "", "", "project")
		if err == nil && len(m.Files) != 1 {
			err = fmt.Errorf("included non-regular asset: %+v", m.Files)
		}
		done <- err
	}()
	select {
	case err := <-done:
		if err != nil {
			t.Fatal(err)
		}
	case <-time.After(200 * time.Millisecond):
		unblock, _ := os.OpenFile(fifo, os.O_RDWR|syscall.O_NONBLOCK, 0)
		if unblock != nil {
			defer unblock.Close()
		}
		t.Fatal("asset FIFO blocked collection")
	}
}

func TestTargetDiscoveryIndependentOfShellTMPDIR(t *testing.T) {
	h := t.TempDir()
	_ = startBridge(t, h, testID, "Mac")
	t.Setenv("TMPDIR", t.TempDir())
	targets, err := discover(h)
	if err != nil || len(targets) != 1 {
		t.Fatalf("interactive shell TMPDIR hides SSH target: %+v %v", targets, err)
	}
}

func TestBridgeCancellationClosesActiveSender(t *testing.T) {
	for _, phase := range []string{"partial-header", "incomplete-body"} {
		t.Run(phase, func(t *testing.T) {
			h := t.TempDir()
			b := startBridge(t, h, testID, "Mac")
			targets, err := discover(h)
			if err != nil || len(targets) != 1 {
				t.Fatalf("discover: %+v %v", targets, err)
			}
			socket := targets[0].Socket
			conn, err := net.Dial("unix", socket)
			if err != nil {
				t.Fatal(err)
			}
			defer conn.Close()
			if phase == "partial-header" {
				if _, err := conn.Write([]byte{0, 0}); err != nil {
					t.Fatal(err)
				}
				// Let the serialized bridge accept this connection and block in ReadFull.
				time.Sleep(30 * time.Millisecond)
			} else {
				p, _, err := collect([]string{fixture(t, filepath.Join(h, "a"), "hello")}, "", "", "project")
				if err != nil {
					t.Fatal(err)
				}
				if err := writeFrame(conn, p); err != nil {
					t.Fatal(err)
				}
				if _, err := conn.Write([]byte("he")); err != nil {
					t.Fatal(err)
				}
				var got Message
				if err := readFrame(b.output, &got); err != nil {
					t.Fatal(err)
				}
				body := make([]byte, 2)
				if _, err := io.ReadFull(b.output, body); err != nil {
					t.Fatal(err)
				}
			}
			b.cancel()
			select {
			case <-b.done:
			case <-time.After(300 * time.Millisecond):
				t.Fatal("bridge cancellation blocked on active sender")
			}
			if _, err := os.Lstat(socket); !os.IsNotExist(err) {
				t.Fatalf("socket remains after cancelled bridge: %v", err)
			}
			descriptors, err := filepath.Glob(filepath.Join(h, ".local/share/peek/targets", testID+"-*.json"))
			if err != nil || len(descriptors) != 0 {
				t.Fatalf("descriptors remain: %+v %v", descriptors, err)
			}
			_ = conn.SetReadDeadline(time.Now().Add(100 * time.Millisecond))
			_, err = io.Copy(io.Discard, conn)
			if timeout, ok := err.(net.Error); ok && timeout.Timeout() {
				t.Fatal("active sender socket remained open")
			}
		})
	}
}
func TestInstallFallbackSurvivesOptionalLauncherFailure(t *testing.T) {
	exe := filepath.Join(t.TempDir(), "peek-remote")
	build := exec.Command("go", "build", "-o", exe, ".")
	if output, err := build.CombinedOutput(); err != nil {
		t.Fatalf("build actual helper: %v\n%s", err, output)
	}
	for _, collision := range []string{"regular-file", "unwritable-directory"} {
		t.Run(collision, func(t *testing.T) {
			if collision == "unwritable-directory" && os.Geteuid() == 0 {
				t.Skip("root bypasses directory write permissions")
			}
			h := t.TempDir()
			t.Setenv("PATH", filepath.Join(h, "empty-path"))
			launcherDir := filepath.Join(h, ".local/bin")
			if collision == "regular-file" {
				fixture(t, launcherDir, "unrelated object\n")
			} else {
				if err := os.MkdirAll(launcherDir, 0700); err != nil {
					t.Fatal(err)
				}
				if err := os.Chmod(launcherDir, 0500); err != nil {
					t.Fatal(err)
				}
				t.Cleanup(func() { _ = os.Chmod(launcherDir, 0700) })
			}
			command, err := install(h, exe)
			if err != nil {
				t.Fatalf("optional launcher failure discarded installed fallback: %v", err)
			}
			if command != "'"+filepath.Join(h, ".local/share/peek/bin/peek-remote")+"'" {
				t.Fatalf("bad fallback command: %s", command)
			}
			if collision == "regular-file" {
				data, err := os.ReadFile(launcherDir)
				if err != nil || string(data) != "unrelated object\n" {
					t.Fatalf("unrelated object changed: %q %v", data, err)
				}
			} else {
				st, err := os.Stat(launcherDir)
				if err != nil || st.Mode().Perm() != 0500 {
					t.Fatalf("unwritable directory changed: %v %v", st, err)
				}
			}
			output, err := exec.Command("/bin/sh", "-c", command+" --version").CombinedOutput()
			if err != nil || string(output) != "peek-remote 1.0.0 (protocol 1)\n" {
				t.Fatalf("fallback execution: %q %v", output, err)
			}
		})
	}
}

func TestSenderFlagsAllowTrailingOptionsAndLongNames(t *testing.T) {
	opts, err := parseSenderArgs([]string{"before.png", "after.png", "--title", "Header Diff", "--conversation=UI Agent", "-s", "checkout", "--", "-literal.png"})
	if err != nil {
		t.Fatal(err)
	}
	if opts.title != "Header Diff" || opts.conversation != "UI Agent" || opts.source != "checkout" {
		t.Fatalf("unexpected options: %+v", opts)
	}
	if strings.Join(opts.files, ",") != "before.png,after.png,-literal.png" {
		t.Fatalf("unexpected files: %+v", opts.files)
	}
	t.Setenv("PEEK_SOURCE", "")
	defaults, err := parseSenderArgs([]string{"report.md"})
	if err != nil || defaults.source != "" {
		t.Fatalf("default source must be empty, got %q (%v)", defaults.source, err)
	}
}

func TestAutoDetectsGitProjectClaudeNameAndSpacedMarkdownAssets(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	t.Setenv("CLAUDE_PID", "4242")
	fixture(t, filepath.Join(home, ".claude/sessions/4242.json"), `{"name":"Perf Audit","nameSource":"user"}`)
	repo := filepath.Join(home, "work/api-gateway")
	if err := os.MkdirAll(filepath.Join(repo, ".git"), 0700); err != nil {
		t.Fatal(err)
	}
	sub := filepath.Join(repo, "docs")
	doc := fixture(t, filepath.Join(sub, "report.md"), "![chart](<my chart.png>)\n")
	fixture(t, filepath.Join(sub, "my chart.png"), "png-bytes")
	prev, err := os.Getwd()
	if err != nil {
		t.Fatal(err)
	}
	if err := os.Chdir(sub); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = os.Chdir(prev) })
	m, _, err := collect([]string{doc}, "", "", "")
	if err != nil {
		t.Fatal(err)
	}
	if m.Source != "" {
		t.Fatalf("expected empty explicit source, got %q", m.Source)
	}
	if m.Conversation != "Perf Audit" {
		t.Fatalf("expected Claude session name, got %q", m.Conversation)
	}
	if m.Origin == nil || m.Origin.Project != "api-gateway" {
		t.Fatalf("expected detected git repo, got %+v", m.Origin)
	}
	if len(m.Files) != 2 || m.Files[1].Path != "0/my chart.png" {
		t.Fatalf("expected spaced markdown asset, got %+v", m.Files)
	}
	fallback := filepath.Join(home, ".local/share/peek/bin/peek-remote")
	exe := fixture(t, filepath.Join(home, "uploaded"), "helper-bytes")
	cmd1, err := install(home, exe)
	if err != nil {
		t.Fatal(err)
	}
	cmd2, err := install(home, fallback)
	if err != nil || cmd1 != cmd2 {
		t.Fatalf("in-place install mismatch: %q vs %q (%v)", cmd1, cmd2, err)
	}
}
