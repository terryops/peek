package main

import (
	"encoding/binary"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"regexp"
	"strings"
	"unicode/utf8"
)

const maxHeader = 1048576
const maxFiles = 300
const maxBody int64 = 64 * 1024 * 1024
const maxError = 4096

var uuidPattern = regexp.MustCompile(`^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$`)
var hashPattern = regexp.MustCompile(`^[0-9a-f]{64}$`)

type File struct {
	Path     string `json:"path"`
	Name     string `json:"name"`
	Original string `json:"original"`
	Size     int64  `json:"size"`
	SHA256   string `json:"sha256"`
	Primary  bool   `json:"primary"`
}
type Origin struct {
	RexSession string `json:"rexSession,omitempty"`
	RexBlock   string `json:"rexBlock,omitempty"`
	Project    string `json:"project,omitempty"`
}
type Message struct {
	Version      int     `json:"version"`
	Kind         string  `json:"kind"`
	RequestID    string  `json:"requestId,omitempty"`
	TargetID     string  `json:"targetId,omitempty"`
	TargetName   string  `json:"targetName,omitempty"`
	Command      string  `json:"command,omitempty"`
	Title        string  `json:"title,omitempty"`
	Conversation string  `json:"conversation,omitempty"`
	Source       string  `json:"source,omitempty"`
	Origin       *Origin `json:"origin,omitempty"`
	Files        []File  `json:"files,omitempty"`
	OK           bool    `json:"ok,omitempty"`
	Error        string  `json:"error,omitempty"`
	CardID       string  `json:"cardId,omitempty"`
}

func (m Message) MarshalJSON() ([]byte, error) {
	type plain Message
	var ok *bool
	if m.Kind == "ack" {
		ok = &m.OK
	}
	return json.Marshal(struct {
		plain
		OK *bool `json:"ok,omitempty"`
	}{plain(m), ok})
}
func readFrame(r io.Reader, m *Message) error {
	var h [4]byte
	if _, err := io.ReadFull(r, h[:]); err != nil {
		return err
	}
	n := binary.BigEndian.Uint32(h[:])
	if n == 0 || n > maxHeader {
		return errors.New("invalid frame length")
	}
	b := make([]byte, n)
	if _, err := io.ReadFull(r, b); err != nil {
		return err
	}
	if !utf8.Valid(b) {
		return errors.New("invalid UTF-8 JSON")
	}
	*m = Message{}
	if err := json.Unmarshal(b, m); err != nil {
		return fmt.Errorf("invalid JSON: %w", err)
	}
	if m.Version != 1 {
		return errors.New("unsupported protocol version")
	}
	switch m.Kind {
	case "ready", "push", "ack":
	default:
		return errors.New("unsupported message kind")
	}
	return nil
}
func writeAll(w io.Writer, b []byte) error {
	for len(b) > 0 {
		n, err := w.Write(b)
		if err != nil {
			return err
		}
		if n == 0 {
			return io.ErrShortWrite
		}
		b = b[n:]
	}
	return nil
}
func writeFrame(w io.Writer, m Message) error {
	b, err := json.Marshal(m)
	if err != nil {
		return err
	}
	if len(b) == 0 || len(b) > maxHeader {
		return errors.New("header exceeds 1048576 bytes")
	}
	var h [4]byte
	binary.BigEndian.PutUint32(h[:], uint32(len(b)))
	if err := writeAll(w, h[:]); err != nil {
		return err
	}
	return writeAll(w, b)
}
func validPath(path string) bool {
	if strings.ContainsAny(path, "\\\x00") || strings.HasPrefix(path, "/") {
		return false
	}
	for _, part := range strings.Split(path, "/") {
		if part == "" || part == "." || part == ".." {
			return false
		}
	}
	return true
}
func validatePush(m Message) error {
	if m.Version != 1 || m.Kind != "push" {
		return errors.New("unsupported push version or kind")
	}
	if !uuidPattern.MatchString(m.RequestID) {
		return errors.New("invalid request UUID")
	}
	if len(m.Files) == 0 || len(m.Files) > maxFiles {
		return errors.New("push requires 1..300 files")
	}
	seen := map[string]bool{}
	var total int64
	primary := false
	for _, f := range m.Files {
		if !validPath(f.Path) || seen[f.Path] {
			return errors.New("invalid or duplicate file path")
		}
		seen[f.Path] = true
		if f.Size < 0 || f.Size > maxBody-total {
			return errors.New("body exceeds 64 MiB")
		}
		total += f.Size
		if !hashPattern.MatchString(f.SHA256) {
			return errors.New("invalid SHA256")
		}
		primary = primary || f.Primary
	}
	if !primary {
		return errors.New("push requires a primary file")
	}
	return nil
}
func validateAck(m Message, id string) error {
	if m.Version != 1 || m.Kind != "ack" || m.RequestID != id {
		return errors.New("invalid receiver acknowledgement")
	}
	if len(m.Error) > maxError {
		return errors.New("receiver error exceeds limit")
	}
	if m.OK && m.CardID == "" {
		return errors.New("success acknowledgement lacks card ID")
	}
	if !m.OK {
		if m.Error == "" {
			return errors.New("receiver rejected request")
		}
		return fmt.Errorf("receiver rejected request: %s", m.Error)
	}
	return nil
}
