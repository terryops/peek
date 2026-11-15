package main

import (
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"html"
	"io"
	"net/url"
	"os"
	"path"
	"path/filepath"
	"regexp"
	"strings"
	"syscall"
)

type localFile struct{ Root, Path string }

func (f localFile) open() (*os.File, error) {
	root, err := os.OpenRoot(f.Root)
	if err != nil {
		return nil, err
	}
	defer root.Close()
	file, err := root.OpenFile(f.Path, os.O_RDONLY|syscall.O_NONBLOCK, 0)
	if err != nil {
		return nil, err
	}
	stat, err := file.Stat()
	if err != nil || !stat.Mode().IsRegular() {
		file.Close()
		if err == nil {
			err = errors.New("not a regular file")
		}
		return nil, err
	}
	return file, nil
}
func newUUID() (string, error) {
	var b [16]byte
	if _, err := rand.Read(b[:]); err != nil {
		return "", err
	}
	b[6] = (b[6] & 15) | 64
	b[8] = (b[8] & 63) | 128
	return fmt.Sprintf("%x-%x-%x-%x-%x", b[:4], b[4:6], b[6:8], b[8:10], b[10:]), nil
}

var htmlRefs = regexp.MustCompile(`(?i)(?:src|href|poster)\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+))`)
var srcsetRefs = regexp.MustCompile(`(?i)srcset\s*=\s*(?:"([^"]*)"|'([^']*)')`)
var cssRefs = regexp.MustCompile(`(?i)url\(\s*["']?([^\s"')]+)["']?\s*\)|@import\s+["']([^"']+)["']`)
var mdRefs = regexp.MustCompile(`!?\[[^\]]*\]\(\s*(?:<([^>\r\n]+)>|([^\s)>]+))(?:\s+[^)]*)?\)|(?m)^\s{0,3}\[[^\]]+\]:\s*(?:<([^>\r\n]+)>|([^\s>]+))`)

func detectProject() string {
	cwd, err := os.Getwd()
	if err != nil {
		return ""
	}
	cwd = filepath.Clean(cwd)
	home, _ := os.UserHomeDir()
	home = filepath.Clean(home)
	for dir := cwd; dir != "/" && dir != "." && dir != home; dir = filepath.Dir(dir) {
		if _, err := os.Stat(filepath.Join(dir, ".git")); err == nil {
			return filepath.Base(dir)
		}
		if filepath.Dir(dir) == dir {
			break
		}
	}
	if cwd == "/" || cwd == "." || cwd == home {
		return ""
	}
	return filepath.Base(cwd)
}

func detectClaudeConversation() string {
	pid := strings.TrimSpace(os.Getenv("CLAUDE_PID"))
	if pid == "" || strings.ContainsAny(pid, "/\\\x00") {
		return ""
	}
	home, err := os.UserHomeDir()
	if err != nil {
		return ""
	}
	data, err := os.ReadFile(filepath.Join(home, ".claude/sessions", pid+".json"))
	if err != nil || len(data) > 65536 {
		return ""
	}
	var session struct {
		Name       string `json:"name"`
		NameSource string `json:"nameSource"`
	}
	if json.Unmarshal(data, &session) != nil || session.NameSource == "derived" {
		return ""
	}
	return strings.TrimSpace(session.Name)
}

func references(data []byte) []string {
	var refs []string
	for _, re := range []*regexp.Regexp{htmlRefs, cssRefs, mdRefs} {
		for _, m := range re.FindAllSubmatch(data, -1) {
			for _, g := range m[1:] {
				if len(g) > 0 {
					refs = append(refs, html.UnescapeString(string(g)))
					break
				}
			}
		}
	}
	for _, m := range srcsetRefs.FindAllSubmatch(data, -1) {
		s := string(m[1])
		if s == "" {
			s = string(m[2])
		}
		for _, part := range strings.Split(s, ",") {
			fields := strings.Fields(part)
			if len(fields) > 0 {
				refs = append(refs, html.UnescapeString(fields[0]))
			}
		}
	}
	return refs
}
func document(ext string) bool {
	switch strings.ToLower(ext) {
	case ".html", ".htm", ".xhtml", ".md", ".markdown", ".mdown", ".mkd", ".css":
		return true
	}
	return false
}
func collect(inputs []string, title, conversation, source string) (Message, []localFile, error) {
	id, err := newUUID()
	if err != nil {
		return Message{}, nil, err
	}
	if conversation == "" {
		conversation = detectClaudeConversation()
	}
	m := Message{Version: 1, Kind: "push", RequestID: id, Title: title, Conversation: conversation, Source: source}
	s, b := os.Getenv("REX_SESSION"), os.Getenv("REX_BLOCK")
	proj := ""
	if source == "" {
		proj = detectProject()
	}
	if s != "" || b != "" || proj != "" {
		m.Origin = &Origin{RexSession: s, RexBlock: b, Project: proj}
	}
	var locals []localFile
	var total int64
	for i, input := range inputs {
		abs, err := filepath.Abs(input)
		if err != nil {
			return m, nil, err
		}
		// The explicitly selected document establishes its asset root. Asset opens
		// stay beneath that root even if an ancestor is concurrently replaced.
		root := filepath.Dir(abs)
		root, err = filepath.EvalSymlinks(root)
		if err != nil {
			return m, nil, err
		}
		seen := map[string]bool{}
		queue := []string{filepath.Base(abs)}
		for len(queue) > 0 {
			rel := queue[0]
			queue = queue[1:]
			if seen[rel] {
				continue
			}
			seen[rel] = true
			lf := localFile{Root: root, Path: rel}
			f, err := lf.open()
			if err != nil {
				if rel == filepath.Base(abs) {
					return m, nil, fmt.Errorf("%s: %w", input, err)
				}
				continue
			}
			st, err := f.Stat()
			if err != nil {
				f.Close()
				return m, nil, err
			}
			if st.Size() < 0 || st.Size() > maxBody-total || len(m.Files) >= maxFiles {
				f.Close()
				return m, nil, errors.New("request exceeds 300 files or 64 MiB")
			}
			hash := sha256.New()
			var data []byte
			var n int64
			if document(filepath.Ext(rel)) {
				data, err = io.ReadAll(io.LimitReader(f, maxBody-total+1))
				n = int64(len(data))
				_, _ = hash.Write(data)
			} else {
				n, err = io.Copy(hash, io.LimitReader(f, maxBody-total+1))
			}
			f.Close()
			if err != nil {
				return m, nil, err
			}
			if n != st.Size() || n > maxBody-total {
				return m, nil, errors.New("file changed or body exceeds 64 MiB")
			}
			total += n
			m.Files = append(m.Files, File{Path: fmt.Sprintf("%d/%s", i, filepath.ToSlash(rel)), Name: filepath.Base(rel), Original: filepath.Join(root, rel), Size: n, SHA256: hex.EncodeToString(hash.Sum(nil)), Primary: rel == filepath.Base(abs)})
			locals = append(locals, lf)
			for _, ref := range references(data) {
				u, err := url.Parse(ref)
				if err != nil || u.IsAbs() || u.Host != "" || u.Path == "" || strings.HasPrefix(u.Path, "/") || strings.ContainsAny(u.Path, "\\\x00") {
					continue
				}
				candidate := path.Clean(path.Join(path.Dir(filepath.ToSlash(rel)), u.Path))
				if candidate == ".." || strings.HasPrefix(candidate, "../") || candidate == "." {
					continue
				}
				queue = append(queue, filepath.FromSlash(candidate))
			}
		}
	}
	if err := validatePush(m); err != nil {
		return m, nil, err
	}
	return m, locals, nil
}
