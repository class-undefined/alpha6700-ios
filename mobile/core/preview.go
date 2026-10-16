package core

import (
	"context"
	"errors"
	"io"
	"os"
	"path/filepath"
	"sort"
	"time"

	"github.com/knallli/alpha2go/ptpip"
)

type Preview struct {
	Path    string `json:"path"`
	Quality string `json:"quality"`
	Bytes   int64  `json:"bytes"`
	Cached  bool   `json:"cached"`
}

// Cache by full camera/file identity, not by reusable content IDs. The bridge
// returns a file URL so HEIF/JPEG data never expands through JSON/Base64.
func (s *Engine) preview(ctx context.Context, id uint32, fileID uint16, quality string) (any, error) {
	typ := ptpip.SonyScreennail
	if quality == "thumbnail" {
		typ = ptpip.SonyThumbnail
	} else if quality != "screen" {
		return nil, errors.New("Unknown preview quality")
	}
	if !s.listed {
		if _, e := s.list(ctx); e != nil {
			return nil, e
		}
	}
	sel, e := s.selection(id, fileID)
	if e != nil {
		return nil, e
	}
	directory := filepath.Join(s.root, ".previews")
	if e = os.MkdirAll(directory, 0700); e != nil {
		return nil, e
	}
	path := filepath.Join(directory, transferKey(sel)+"-"+quality+".image")
	if st, e := os.Stat(path); e == nil && st.Size() > 0 {
		now := time.Now()
		_ = os.Chtimes(path, now, now)
		return Preview{path, quality, st.Size(), true}, nil
	}
	f, e := os.CreateTemp(directory, ".preview-")
	if e != nil {
		return nil, e
	}
	tmp := f.Name()
	defer os.Remove(tmp)
	w := &cappedWriter{w: f, remaining: 64 << 20}
	n, e := s.client.SonyGetContentsCompressed(ctx, 1, id, fileID, typ, w)
	if e == nil && (n <= 0 || n != w.n) {
		e = errors.New("Camera returned an empty or incomplete preview")
	}
	e = errors.Join(e, f.Close())
	if e != nil {
		return nil, e
	}
	if e = os.Rename(tmp, path); e != nil {
		return nil, e
	}
	trimPreviewCache(directory, path, 256<<20)
	return Preview{path, quality, n, false}, nil
}
func trimPreviewCache(directory, keep string, limit int64) {
	entries, _ := os.ReadDir(directory)
	var files []os.FileInfo
	var size int64
	for _, entry := range entries {
		if entry.IsDir() {
			continue
		}
		if st, e := entry.Info(); e == nil {
			files = append(files, st)
			size += st.Size()
		}
	}
	sort.Slice(files, func(i, j int) bool { return files[i].ModTime().Before(files[j].ModTime()) })
	for _, st := range files {
		if size <= limit {
			break
		}
		p := filepath.Join(directory, st.Name())
		if p != keep && os.Remove(p) == nil {
			size -= st.Size()
		}
	}
}

type contextReader struct {
	ctx context.Context
	r   io.Reader
}

func (r contextReader) Read(p []byte) (int, error) {
	select {
	case <-r.ctx.Done():
		return 0, r.ctx.Err()
	default:
		return r.r.Read(p)
	}
}
