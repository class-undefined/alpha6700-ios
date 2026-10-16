package core

import (
	"context"
	"encoding/json"
	"errors"
	"github.com/knallli/alpha2go/ptpip"
	"github.com/knallli/alpha2go/ptpip/ptpiptest"
	"io"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestPropertyConstraintsAndPrecision(t *testing.T) {
	p := ptpip.SonyProp{Type: 6, Writable: true, Enabled: 1, Form: 2, Settable: []ptpip.SonyValue{{Int: 100}, {Int: 200}}}
	if validateValue(p, ptpip.SonyValue{Int: 125}) == nil {
		t.Fatal("unadvertised ISO accepted")
	}
	if e := validateValue(p, ptpip.SonyValue{Int: 200}); e != nil {
		t.Fatal(e)
	}
	p.Enabled = 2
	if validateValue(p, ptpip.SonyValue{Int: 200}) == nil {
		t.Fatal("display-only value writable")
	}
	p = ptpip.SonyProp{Type: 5, Writable: true, Enabled: 1, Form: 1, Min: ptpip.SonyValue{Int: -3000}, Max: ptpip.SonyValue{Int: 3000}, Step: ptpip.SonyValue{Int: 500}}
	if validateValue(p, ptpip.SonyValue{Int: -2500}) != nil || validateValue(p, ptpip.SonyValue{Int: 501}) == nil {
		t.Fatal("range step validation")
	}
	for _, text := range []string{"9007199254740993", "18446744073709551615"} {
		v, e := parseValue(8, text)
		if e != nil || valueText(8, v) != text {
			t.Fatal("64-bit precision lost")
		}
	}
	if _, e := parseValue(2, "256"); e == nil {
		t.Fatal("uint8 overflow")
	}
}

type failingChunk struct {
	offset uint64
	count  uint32
	fail   bool
}

func (f *failingChunk) SonyGetContentsData(_ context.Context, _, _ uint32, _ uint16, offset uint64, size uint32, _ bool, w io.Writer) (uint32, error) {
	f.offset = offset
	f.count = size
	n, e := w.Write([]byte("abc"))
	if f.fail {
		return uint32(n), errors.New("network dropped")
	}
	return uint32(n), e
}
func TestUnacknowledgedChunkRollbackAnd64BitOffset(t *testing.T) {
	file, e := os.CreateTemp(t.TempDir(), "part")
	if e != nil {
		t.Fatal(e)
	}
	defer file.Close()
	offset := uint64(1<<32) + 11
	if e = file.Truncate(int64(offset)); e != nil {
		t.Fatal(e)
	}
	sel := Selection{File: ptpip.SonyContentFile{Size: offset + 3}}
	source := &failingChunk{fail: true}
	next, e := commitChunk(context.Background(), source, sel, file, offset, 3)
	st, _ := file.Stat()
	if e == nil || next != offset || uint64(st.Size()) != offset || source.offset != offset {
		t.Fatal("unacknowledged tail was committed or offset truncated")
	}
	source.fail = false
	next, e = commitChunk(context.Background(), source, sel, file, offset, 3)
	if e != nil || next != offset+3 {
		t.Fatal(next, e)
	}
}
func fakeEngine(t *testing.T, dir string) (*Engine, *ptpiptest.Server) {
	t.Helper()
	server, e := ptpiptest.Start(ptpiptest.Options{Dir: dir, A6700: true})
	if e != nil {
		t.Fatal(e)
	}
	t.Cleanup(func() { server.Close() })
	c, e := ptpip.Dial(context.Background(), server.Addr(), ptpip.Options{IOTimeout: time.Second})
	if e != nil {
		t.Fatal(e)
	}
	if e = c.OpenSession(context.Background(), 1); e != nil {
		t.Fatal(e)
	}
	info, e := c.GetDeviceInfo(context.Background())
	if e != nil {
		t.Fatal(e)
	}
	ext, e := c.SonyHandshake(context.Background())
	if e != nil {
		t.Fatal(e)
	}
	s, e := New(t.TempDir(), "00112233445566778899aabbccddeeff")
	if e != nil {
		t.Fatal(e)
	}
	s.client = c
	s.info = info
	s.ext = ext
	t.Cleanup(s.close)
	return s, server
}
func TestEmptyCardNeverRequestsContentsAndConfirmation(t *testing.T) {
	s, server := fakeEngine(t, t.TempDir())
	r := s.Request(`{"op":"list"}`)
	if !strings.Contains(r, `"data":[]`) {
		t.Fatal(r)
	}
	if len(server.ContentRequests()) != 0 {
		t.Fatal("empty-card listing requested a page")
	}
	r = s.Request(`{"op":"delete","id":1}`)
	if !strings.Contains(r, `"ok":false`) || len(server.Deletes()) != 0 {
		t.Fatal("unconfirmed deletion")
	}
	if r = s.Request(`{"op":"set","code":53374,"value":"1"}`); !strings.Contains(r, `"ok":false`) {
		t.Fatal("unknown property accepted")
	}
}
func TestImportPersistsAndVerifiesIdentity(t *testing.T) {
	dir := t.TempDir()
	data := []byte("real local payload")
	if e := os.WriteFile(filepath.Join(dir, "DSC001.JPG"), data, 0600); e != nil {
		t.Fatal(e)
	}
	s, _ := fakeEngine(t, dir)
	if _, e := s.list(context.Background()); e != nil {
		t.Fatal(e)
	}
	if len(s.contents) != 1 {
		t.Fatal(s.contents)
	}
	ct := s.contents[0]
	v, e := s.transferChunk(context.Background(), ct.ID, ct.Files[0].ID, "")
	if e != nil {
		t.Fatal(e)
	}
	tr := v.(Transfer)
	b, e := os.ReadFile(tr.Path)
	if e != nil || string(b) != string(data) || tr.Status != "complete" || len(tr.SHA256) != 64 {
		t.Fatal(tr, e)
	}
	if _, e = s.transferChunk(context.Background(), ct.ID, ct.Files[0].ID, ""); e != nil {
		t.Fatal("completed transfer not idempotent", e)
	}
	if _, e = s.transferChunk(context.Background(), ct.ID, ct.Files[0].ID, "wrong-identity"); e == nil {
		t.Fatal("stale queue resumed a different file")
	}
	changed := tr.Selection
	changed.File.Size++
	if sameFile(tr.Selection, changed) {
		t.Fatal("changed file identity accepted")
	}
	queue, e := s.queue()
	if e != nil || len(queue.([]Transfer)) != 1 {
		t.Fatal("durable queue lost")
	}
}
func TestErrorsDoNotLeakCredentials(t *testing.T) {
	s := encodeReply(nil, errors.New("secret-password"), "secret-password")
	var r Reply
	if e := json.Unmarshal([]byte(s), &r); e != nil || strings.Contains(s, "secret-password") || r.OK {
		t.Fatal(s)
	}
}

func TestCatalogIsNamesOnlyAndDoesNotEnableWrites(t *testing.T) {
	p := property(ptpip.SonyProp{Code: 0xD253, Type: 4, Writable: false, Enabled: 0, Current: ptpip.SonyValue{Int: 2}})
	if p.Name == "0xD253" || p.Writable || len(p.Choices) != 0 {
		t.Fatal("catalog must only name properties, never create permissions or choices", p)
	}
	if name, _, ok := catalogName(0xD21E); !ok || name == "" {
		t.Fatal("missing exposure catalog")
	}
	if len(catalogNames) < 600 {
		t.Fatal("incomplete name catalog")
	}
}
