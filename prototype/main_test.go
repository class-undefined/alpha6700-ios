package main

import (
	"bytes"
	"context"
	"errors"
	"io"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/knallli/alpha2go/ptpip"
	"github.com/knallli/alpha2go/ptpip/ptpiptest"
)

func TestPublicErrorsRemoveLiveViewTokensAndPasswords(t *testing.T) {
	message := publicError(errors.New(`GET "http://localhost:60152/liveviewstream?token=private-value": secret-pass failed`), "secret-pass")
	if strings.Contains(message, "private-value") || strings.Contains(message, "secret-pass") || strings.Contains(message, "liveviewstream") {
		t.Fatal("sensitive network detail remained in public error")
	}
}

type interruptedSource struct{}

func (interruptedSource) SonyGetContentsData(_ context.Context, _ uint32, _ uint32, _ uint16, _ uint64, _ uint32, _ bool, w io.Writer) (uint32, error) {
	n, _ := w.Write([]byte("unacknowledged-tail"))
	return uint32(n), io.ErrUnexpectedEOF
}

func TestFailedChunkDiscardsUnacknowledgedBytes(t *testing.T) {
	f, err := os.CreateTemp(t.TempDir(), "partial")
	if err != nil {
		t.Fatal(err)
	}
	defer f.Close()
	if _, err = f.WriteString("committed"); err != nil {
		t.Fatal(err)
	}
	sel := selection{File: ptpip.SonyContentFile{Size: 100}}
	offset, err := readChunk(context.Background(), interruptedSource{}, sel, f, 9, 30)
	if err == nil || offset != 9 {
		t.Fatalf("offset=%d err=%v", offset, err)
	}
	b, err := os.ReadFile(f.Name())
	if err != nil {
		t.Fatal(err)
	}
	if string(b) != "committed" {
		t.Fatalf("partial tail retained: %q", b)
	}
}

func connectFake(t *testing.T, srv *ptpiptest.Server) *ptpip.Client {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	c, err := ptpip.Dial(ctx, srv.Addr(), ptpip.Options{IOTimeout: time.Second})
	if err != nil {
		t.Fatal(err)
	}
	if err = c.OpenSession(ctx, 1); err != nil {
		t.Fatal(err)
	}
	if _, err = c.SonyHandshake(ctx); err != nil {
		t.Fatal(err)
	}
	return c
}

func TestReconnectAndResumeMatchesOriginalWithoutCameraWrites(t *testing.T) {
	card := t.TempDir()
	if err := os.MkdirAll(filepath.Join(card, "slot1"), 0700); err != nil {
		t.Fatal(err)
	}
	data := bytes.Repeat([]byte("camera-file-data"), 350000)
	if err := os.WriteFile(filepath.Join(card, "slot1", "sample.JPG"), data, 0600); err != nil {
		t.Fatal(err)
	}
	srv, err := ptpiptest.Start(ptpiptest.Options{Dir: card, A6700: true})
	if err != nil {
		t.Fatal(err)
	}
	defer srv.Close()
	c := connectFake(t, srv)
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	cs, err := firstPage(ctx, c)
	if err != nil {
		t.Fatal(err)
	}
	sel, err := choose(cs)
	if err != nil {
		t.Fatal(err)
	}
	f, err := os.CreateTemp(t.TempDir(), "download")
	if err != nil {
		t.Fatal(err)
	}
	defer f.Close()
	off, err := readChunk(ctx, c, sel, f, 0, 65536)
	if err != nil {
		t.Fatal(err)
	}
	c.Close()
	c = connectFake(t, srv)
	defer c.Close()
	if err = transfer(ctx, c, sel, f, off); err != nil {
		t.Fatal(err)
	}
	actual, err := os.ReadFile(f.Name())
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(actual, data) {
		t.Fatal("resumed output differs from source")
	}
	if srv.Xfer9212.Load() != 0 || len(srv.Controls()) != 0 || len(srv.Deletes()) != 0 || len(srv.Restores()) != 0 || len(srv.Uploads()) != 0 {
		t.Fatal("unexpected camera mutation")
	}
	requests := srv.ContentRequests()
	if len(requests) != 3 || requests[1].Offset != 65536 || !requests[2].Last {
		t.Fatalf("bad resume requests: %+v", requests)
	}
}

func TestEmptyAndBusyCardsDoNotSendContentsPage(t *testing.T) {
	for _, busy := range []bool{false, true} {
		card := t.TempDir()
		os.MkdirAll(filepath.Join(card, "slot1"), 0700)
		srv, err := ptpiptest.Start(ptpiptest.Options{Dir: card, A6700: true, CardBusy: busy})
		if err != nil {
			t.Fatal(err)
		}
		c := connectFake(t, srv)
		before := srv.Ops.Load()
		cs, err := firstPage(context.Background(), c)
		if busy && !errors.Is(err, ptpip.ErrCardUnavailable) {
			t.Fatalf("expected card refusal, got %v", err)
		}
		if !busy && (err != nil || len(cs) != 0) {
			t.Fatalf("empty card: %v", err)
		}
		if srv.Ops.Load()-before != 1 {
			t.Fatal("unexpected page or retry after empty/busy date list")
		}
		c.Close()
		srv.Close()
	}
}

func TestChangedRemoteIdentityCannotResume(t *testing.T) {
	a := selection{ContentID: 1, CreatedUTC: time.Unix(1, 0), File: ptpip.SonyContentFile{ID: 1, Path: "A:/one.JPG", Size: 100}}
	b := a
	b.File.UMID[0] = 1
	if sameSelection(a, b) {
		t.Fatal("changed file identity accepted")
	}
	b = a
	b.File.Size++
	if sameSelection(a, b) {
		t.Fatal("changed file size accepted")
	}
}
