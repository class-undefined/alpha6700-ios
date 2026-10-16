package core

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"io"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"

	"github.com/knallli/alpha2go/ptpip"
)

type boundedBuffer struct {
	bytes.Buffer
	limit int
}

func (b *boundedBuffer) Write(p []byte) (int, error) {
	if b.Len()+len(p) > b.limit {
		return 0, errors.New("Camera response exceeds size limit")
	}
	return b.Buffer.Write(p)
}

type Selection struct {
	Camera    string                `json:"camera"`
	ContentID uint32                `json:"contentID"`
	Created   string                `json:"created"`
	File      ptpip.SonyContentFile `json:"file"`
}
type Transfer struct {
	Key       string    `json:"key"`
	Selection Selection `json:"selection"`
	Offset    uint64    `json:"offset"`
	Size      uint64    `json:"size"`
	Name      string    `json:"name"`
	Path      string    `json:"path"`
	Status    string    `json:"status"`
	SHA256    string    `json:"sha256,omitempty"`
}
type MediaFile struct {
	ID    uint16 `json:"id"`
	Name  string `json:"name"`
	Size  uint64 `json:"size"`
	Video bool   `json:"video"`
}
type Media struct {
	ID        uint32      `json:"id"`
	Created   string      `json:"created"`
	Rating    int32       `json:"rating"`
	Protected bool        `json:"protected"`
	Files     []MediaFile `json:"files"`
}

func (s *Engine) list(ctx context.Context) (any, error) {
	cs, e := s.client.SonyListAllContents(ctx, 1)
	if e != nil {
		return nil, e
	}
	s.contents = cs
	s.listed = true
	out := []Media{}
	for _, c := range cs {
		m := Media{ID: c.ID, Created: c.CreatedLocal.Format("2006-01-02 15:04:05"), Rating: c.Rating, Protected: c.Protected, Files: []MediaFile{}}
		for _, f := range c.Files {
			m.Files = append(m.Files, MediaFile{f.ID, filepath.Base(f.Path), f.Size, f.HasVideo})
		}
		out = append(out, m)
	}
	sort.Slice(out, func(i, j int) bool { return out[i].Created > out[j].Created })
	return out, nil
}
func (s *Engine) selection(id uint32, fileID uint16) (Selection, error) {
	for _, c := range s.contents {
		if c.ID == id {
			for _, f := range c.Files {
				if f.ID == fileID {
					return Selection{Camera: s.info.Model + ":" + s.info.SerialNumber, ContentID: id, Created: c.CreatedUTC.Format(time.RFC3339Nano), File: f}, nil
				}
			}
		}
	}
	return Selection{}, errors.New("File no longer exists in the current card listing")
}
func transferKey(sel Selection) string {
	b, _ := json.Marshal(sel)
	sum := sha256.Sum256(b)
	return hex.EncodeToString(sum[:16])
}
func atomicJSON(path string, v any) error {
	b, e := json.MarshalIndent(v, "", "  ")
	if e != nil {
		return e
	}
	f, e := os.CreateTemp(filepath.Dir(path), ".state-")
	if e != nil {
		return e
	}
	tmp := f.Name()
	defer os.Remove(tmp)
	if e = f.Chmod(0600); e == nil {
		_, e = f.Write(b)
	}
	if e == nil {
		e = f.Sync()
	}
	e = errors.Join(e, f.Close())
	if e != nil {
		return e
	}
	return os.Rename(tmp, path)
}
func readLimited(path string, limit int64) ([]byte, error) {
	f, e := os.Open(path)
	if e != nil {
		return nil, e
	}
	defer f.Close()
	b, e := io.ReadAll(io.LimitReader(f, limit+1))
	if len(b) > int(limit) {
		return nil, errors.New("File exceeds allowed size")
	}
	return b, e
}

type chunkSource interface {
	SonyGetContentsData(context.Context, uint32, uint32, uint16, uint64, uint32, bool, io.Writer) (uint32, error)
}
type cappedWriter struct {
	w         io.Writer
	n         int64
	remaining int64
}

func (w *cappedWriter) Write(p []byte) (int, error) {
	if int64(len(p)) > w.remaining {
		return 0, errors.New("Camera exceeded requested chunk size")
	}
	n, e := w.w.Write(p)
	w.n += int64(n)
	w.remaining -= int64(n)
	return n, e
}
func commitChunk(ctx context.Context, c chunkSource, sel Selection, f *os.File, offset uint64, want uint32) (uint64, error) {
	if offset > sel.File.Size || uint64(want) > sel.File.Size-offset || want == 0 {
		return offset, errors.New("Invalid download range")
	}
	if _, e := f.Seek(int64(offset), io.SeekStart); e != nil {
		return offset, e
	}
	w := &cappedWriter{w: f, remaining: int64(want)}
	n, e := c.SonyGetContentsData(ctx, 1, sel.ContentID, sel.File.ID, offset, want, offset+uint64(want) == sel.File.Size, w)
	if e == nil && (n == 0 || n > want || int64(n) != w.n) {
		e = errors.New("Camera acknowledged an invalid byte count")
	}
	if e == nil {
		e = f.Sync()
	}
	if e != nil {
		return offset, errors.Join(e, f.Truncate(int64(offset)))
	}
	return offset + uint64(n), nil
}
func (s *Engine) transferChunk(ctx context.Context, id uint32, fileID uint16, expectedKey string) (any, error) {
	if !s.listed {
		if _, e := s.list(ctx); e != nil {
			return nil, e
		}
	}
	sel, e := s.selection(id, fileID)
	if e != nil {
		return nil, e
	}
	if sel.File.Size == 0 || sel.File.Size > 1<<63-1 {
		return nil, errors.New("Invalid file size")
	}
	key := transferKey(sel)
	if expectedKey != "" && expectedKey != key {
		return nil, errors.New("The camera file identity changed; this queued download cannot resume")
	}
	manifest := filepath.Join(s.root, key+".json")
	part := filepath.Join(s.root, key+".part")
	t := Transfer{Key: key, Selection: sel, Size: sel.File.Size, Name: filepath.Base(sel.File.Path), Status: "paused"}
	if b, e := os.ReadFile(manifest); e == nil {
		if e = json.Unmarshal(b, &t); e != nil {
			return nil, e
		}
		if !sameFile(sel, t.Selection) {
			return nil, errors.New("Camera file identity changed; create a new download")
		}
	} else if !errors.Is(e, os.ErrNotExist) {
		return nil, e
	}
	if t.Path != "" {
		t.Path = filepath.Join(s.root, filepath.Base(t.Path))
	}
	if t.Status == "complete" {
		if st, e := os.Stat(t.Path); e == nil && uint64(st.Size()) == t.Size {
			return t, nil
		}
		return nil, errors.New("Completed local file is missing or changed")
	}
	if t.Offset > t.Size {
		return nil, errors.New("Saved offset exceeds expected size")
	}
	if e = atomicJSON(manifest, t); e != nil {
		return nil, e
	}
	f, e := os.OpenFile(part, os.O_CREATE|os.O_RDWR, 0600)
	if e != nil {
		return nil, e
	}
	defer f.Close()
	st, e := f.Stat()
	if e != nil {
		return nil, e
	}
	if uint64(st.Size()) < t.Offset {
		return nil, errors.New("Local file is shorter than committed download offset")
	}
	// Crash recovery: only the persisted acknowledged offset is trusted.
	if e = f.Truncate(int64(t.Offset)); e != nil {
		return nil, e
	}
	if t.Offset < t.Size {
		next, e := commitChunk(ctx, s.client, sel, f, t.Offset, uint32(min(uint64(2<<20), t.Size-t.Offset)))
		if e != nil {
			return nil, e
		}
		t.Offset = next
		if e = atomicJSON(manifest, t); e != nil {
			return nil, e
		}
	}
	if t.Offset == t.Size {
		if _, e = f.Seek(0, io.SeekStart); e != nil {
			return nil, e
		}
		h := sha256.New()
		if _, e = io.Copy(h, f); e != nil {
			return nil, e
		}
		t.SHA256 = hex.EncodeToString(h.Sum(nil))
		t.Path = filepath.Join(s.root, key+"-"+t.Name)
		// Copying the final name by hard link keeps .part available if the process
		// dies before the completed manifest has been atomically committed.
		if e = os.Link(part, t.Path); e != nil && !errors.Is(e, os.ErrExist) {
			return nil, e
		}
		t.Status = "complete"
		if e = atomicJSON(manifest, t); e != nil {
			return nil, e
		}
		_ = os.Remove(part)
	}
	return t, nil
}
func (s *Engine) queue() (any, error) {
	files, e := filepath.Glob(filepath.Join(s.root, "*.json"))
	if e != nil {
		return nil, e
	}
	out := []Transfer{}
	for _, path := range files {
		b, e := os.ReadFile(path)
		if e != nil {
			return nil, e
		}
		var t Transfer
		if json.Unmarshal(b, &t) == nil && t.Key != "" {
			if t.Path != "" {
				t.Path = filepath.Join(s.root, filepath.Base(t.Path))
			}
			out = append(out, t)
		}
	}
	return out, nil
}
func (s *Engine) discardTransfer(key string) error {
	if len(key) != 32 {
		return errors.New("Invalid transfer key")
	}
	if _, e := hex.DecodeString(key); e != nil {
		return e
	}
	path := filepath.Join(s.root, key+".json")
	b, e := os.ReadFile(path)
	if e != nil {
		return e
	}
	var t Transfer
	if e = json.Unmarshal(b, &t); e != nil {
		return e
	}
	if t.Status == "complete" {
		return errors.New("Completed imports are retained; manage them in Files")
	}
	if e = os.Remove(filepath.Join(s.root, key+".part")); e != nil && !errors.Is(e, os.ErrNotExist) {
		return e
	}
	return os.Remove(path)
}
func (s *Engine) backup(ctx context.Context) (any, error) {
	var b boundedBuffer
	b.limit = 8 << 20
	if _, e := s.client.SonyDownloadSettings(ctx, &b); e != nil {
		return nil, e
	}
	path := filepath.Join(s.root, "ILCE-6700-"+time.Now().Format("20060102-150405")+".dat")
	e := os.WriteFile(path, b.Bytes(), 0600)
	return path, e
}
func (s *Engine) fetchCapture(ctx context.Context) (any, error) {
	ready, _, e := s.client.SonyCapturedPending(ctx)
	if e != nil {
		return nil, e
	}
	if !ready {
		return nil, errors.New("No image pending; use Host + Card as the camera save destination")
	}
	path := filepath.Join(s.root, "Capture-"+time.Now().Format("20060102-150405.000"))
	f, e := os.OpenFile(path+".partial", os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0600)
	if e != nil {
		return nil, e
	}
	info, _, e := s.client.SonyGetCapturedImage(ctx, f, nil)
	e = errors.Join(e, f.Sync(), f.Close())
	if e != nil {
		_ = os.Remove(path + ".partial")
		return nil, e
	}
	ext := strings.ToLower(filepath.Ext(info.Filename))
	if ext == "" {
		ext = ".jpg"
	}
	path += ext
	return path, os.Rename(strings.TrimSuffix(path, ext)+".partial", path)
}
