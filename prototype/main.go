// camera-check exercises a small set of known α6700 operations. Reads are the
// default; iso-roundtrip is an explicit temporary write followed by restoration.
// Credentials arrive on stdin from the local Keychain helper, never flags.
package main

import (
	"bytes"
	"context"
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"image/jpeg"
	"io"
	"net"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"time"

	"github.com/knallli/alpha2go/ptpip"
)

type access struct{ Host, User, Password, Fingerprint string }
type selection struct {
	ContentID  uint32                `json:"content_id"`
	CreatedUTC time.Time             `json:"created_utc"`
	File       ptpip.SonyContentFile `json:"file"`
}
type session struct {
	c    *ptpip.Client
	ssh  *ptpip.SSHDialer
	info *ptpip.DeviceInfo
	ext  *ptpip.SonyExtInfo
}

var urlInError = regexp.MustCompile(`(?i)https?://[^\s"<>]+`)

func publicError(err error, password string) string {
	message := urlInError.ReplaceAllString(err.Error(), "[URL redacted]")
	if password != "" {
		message = strings.ReplaceAll(message, password, "[redacted]")
	}
	return message
}

func (s *session) close() {
	if s == nil {
		return
	}
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	_ = s.c.CloseSession(ctx)
	_ = s.c.Close()
	_ = s.ssh.Close()
}

func open(ctx context.Context, a access, guid [16]byte, log io.Writer) (*session, error) {
	ctx, cancel := context.WithTimeout(ctx, 20*time.Second)
	defer cancel()
	sd := ptpip.NewSSHDialer(ptpip.SSHConfig{User: a.User, Password: a.Password, Fingerprint: a.Fingerprint})
	enc := json.NewEncoder(log)
	c, err := ptpip.Dial(ctx, net.JoinHostPort(a.Host, "15740"), ptpip.Options{
		Name: "Sony Local Verification", GUID: guid, IOTimeout: 10 * time.Second,
		DialContext: sd.DialContext,
		Trace: func(t ptpip.TraceEvent) {
			if t.Phase == "end" {
				_ = enc.Encode(map[string]any{"at": time.Now().UTC(), "op": fmt.Sprintf("0x%04X", t.Op), "params": t.Params, "ms": t.Dur.Milliseconds(), "ok": t.Err == nil})
			}
		},
	})
	if err != nil {
		sd.Close()
		return nil, fmt.Errorf("connect: %w", err)
	}
	s := &session{c: c, ssh: sd}
	good := false
	defer func() {
		if !good {
			c.Close()
			sd.Close()
		}
	}()
	if s.info, err = c.GetDeviceInfo(ctx); err != nil {
		return nil, fmt.Errorf("GetDeviceInfo: %w", err)
	}
	if !s.info.IsSony() || s.info.Model != "ILCE-6700" {
		return nil, errors.New("responder is not the expected Sony ILCE-6700")
	}
	if s.info.DeviceVersion != "2.00" {
		return nil, errors.New("this verification profile expects camera firmware 2.00")
	}
	if err = c.OpenSession(ctx, 1); err != nil {
		return nil, fmt.Errorf("OpenSession: %w", err)
	}
	if s.ext, err = c.SonyHandshake(ctx); err != nil {
		return nil, fmt.Errorf("SonyHandshake: %w", err)
	}
	if s.ext.ProtocolVersion != 0x12c || len(s.ext.Properties) == 0 {
		return nil, errors.New("Sony handshake did not establish protocol 3.00 capabilities")
	}
	good = true
	return s, nil
}

func saveJSON(path string, v any) error {
	b, err := json.MarshalIndent(v, "", "  ")
	if err != nil {
		return err
	}
	return os.WriteFile(path, append(b, '\n'), 0600)
}

func stableGUID(path string) ([16]byte, error) {
	var id [16]byte
	b, err := os.ReadFile(path)
	if err == nil {
		raw, e := hex.DecodeString(strings.TrimSpace(string(b)))
		if e != nil || len(raw) != 16 {
			return id, errors.New("invalid stored initiator GUID")
		}
		copy(id[:], raw)
		return id, nil
	}
	if !errors.Is(err, os.ErrNotExist) {
		return id, err
	}
	if _, err = rand.Read(id[:]); err != nil {
		return id, err
	}
	if err = os.MkdirAll(filepath.Dir(path), 0700); err != nil {
		return id, err
	}
	f, err := os.OpenFile(path, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0600)
	if err != nil {
		return id, err
	}
	_, err = f.WriteString(hex.EncodeToString(id[:]) + "\n")
	closeErr := f.Close()
	if err == nil {
		err = closeErr
	}
	return id, err
}

// A bounded first page is sufficient for selecting a small test file. Do not
// claim that it is the entire card, and never request a page from an empty slot.
func firstPage(ctx context.Context, c *ptpip.Client) ([]ptpip.SonyContent, error) {
	dates, err := c.SonyGetCapturedDateList(ctx, 1)
	if err != nil {
		return nil, err
	}
	if len(dates) == 0 {
		return nil, nil
	}
	return c.SonyGetContentsInfoList(ctx, 1, 0)
}

func choose(cs []ptpip.SonyContent) (selection, error) {
	var choices []selection
	for _, c := range cs {
		for _, f := range c.Files {
			ext := strings.ToLower(filepath.Ext(f.Path))
			if c.Type == 1 && f.Size > 0 && f.Size <= 64<<20 && (ext == ".jpg" || ext == ".jpeg" || ext == ".hif" || ext == ".heif" || ext == ".arw") {
				choices = append(choices, selection{ContentID: c.ID, CreatedUTC: c.CreatedUTC, File: f})
			}
		}
	}
	if len(choices) == 0 {
		return selection{}, errors.New("first page has no still-image file at most 64 MiB")
	}
	sort.Slice(choices, func(i, j int) bool { return choices[i].File.Size < choices[j].File.Size })
	return choices[0], nil
}

func sameSelection(a, b selection) bool {
	return a.ContentID == b.ContentID && a.CreatedUTC.Equal(b.CreatedUTC) && a.File.ID == b.File.ID && a.File.Path == b.File.Path && a.File.Size == b.File.Size && a.File.UMID == b.File.UMID
}

type chunkSource interface {
	SonyGetContentsData(context.Context, uint32, uint32, uint16, uint64, uint32, bool, io.Writer) (uint32, error)
}
type cappedWriter struct {
	w         io.Writer
	remaining int64
	written   int64
}

func (w *cappedWriter) Write(p []byte) (int, error) {
	if int64(len(p)) > w.remaining {
		return 0, errors.New("camera exceeded requested chunk length")
	}
	n, e := w.w.Write(p)
	w.remaining -= int64(n)
	w.written += int64(n)
	return n, e
}

// Commit only a successfully acknowledged chunk. If a connection fails after
// writing some bytes, discard that unacknowledged tail before any later retry.
func readChunk(ctx context.Context, c chunkSource, sel selection, f *os.File, offset uint64, want uint32) (uint64, error) {
	if _, err := f.Seek(int64(offset), io.SeekStart); err != nil {
		return offset, err
	}
	writer := &cappedWriter{w: f, remaining: int64(want)}
	n, err := c.SonyGetContentsData(ctx, 1, sel.ContentID, sel.File.ID, offset, want, offset+uint64(want) >= sel.File.Size, writer)
	if err == nil && (n == 0 || n > want || int64(n) != writer.written) {
		err = errors.New("invalid chunk byte count")
	}
	if err != nil {
		if e := f.Truncate(int64(offset)); e != nil {
			return offset, fmt.Errorf("%v; could not discard partial tail: %w", err, e)
		}
		return offset, err
	}
	if err = f.Sync(); err != nil {
		return offset, err
	}
	return offset + uint64(n), nil
}

func transfer(ctx context.Context, c chunkSource, sel selection, f *os.File, offset uint64) error {
	if offset > sel.File.Size {
		return errors.New("resume offset exceeds file size")
	}
	st, err := f.Stat()
	if err != nil {
		return err
	}
	if uint64(st.Size()) != offset {
		return errors.New("local file size differs from committed resume offset")
	}
	for offset < sel.File.Size {
		want := uint32(min(uint64(4<<20), sel.File.Size-offset))
		next, err := readChunk(ctx, c, sel, f, offset, want)
		if err != nil {
			return err
		}
		offset = next
	}
	return nil
}

func digestFile(path string) (string, error) {
	f, err := os.Open(path)
	if err != nil {
		return "", err
	}
	defer f.Close()
	h := sha256.New()
	if _, err = io.Copy(h, f); err != nil {
		return "", err
	}
	return hex.EncodeToString(h.Sum(nil)), nil
}

func run(ctx context.Context, a access, guid [16]byte, step, out string, result map[string]any) error {
	log, err := os.OpenFile(filepath.Join(out, "operations.jsonl"), os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0600)
	if err != nil {
		return err
	}
	defer log.Close()
	start := time.Now()
	s, err := open(ctx, a, guid, log)
	if err != nil {
		return err
	}
	defer func() { s.close() }()
	result["model"], result["firmware"], result["connect_ms"] = s.info.Model, s.info.DeviceVersion, time.Since(start).Milliseconds()
	result["protocol"], result["advertised_properties"], result["advertised_controls"] = "3.00", len(s.ext.Properties), len(s.ext.Controls)
	switch step {
	case "capture-once":
		return captureOnce(ctx, s.c, out, result)
	case "iso-roundtrip":
		return isoRoundtrip(ctx, s.c, out, result)
	case "info":
		props, e := s.c.SonyGetProps(ctx, false)
		if e != nil {
			return e
		}
		result["properties_read"] = len(props)
		values := map[string]any{}
		for _, p := range props {
			switch p.Code {
			case 0x5007, 0x500E, 0xD20D, 0xD21E:
				values[fmt.Sprintf("0x%04X", p.Code)] = map[string]any{"raw": p.Current.Int, "enabled": p.Enabled, "settable_count": len(p.Settable)}
			}
		}
		result["selected_properties"] = values
		var inventory []map[string]any
		for _, p := range props {
			inventory = append(inventory, map[string]any{"code": fmt.Sprintf("0x%04X", p.Code), "type": p.Type, "writable": p.Writable, "enabled": p.Enabled})
		}
		return saveJSON(filepath.Join(out, "property-inventory.json"), inventory)
	case "reconnect":
		s.close()
		s = nil
		start = time.Now()
		s, err = open(ctx, a, guid, log)
		if err != nil {
			return err
		}
		props, e := s.c.SonyGetProps(ctx, false)
		if e != nil {
			return e
		}
		result["reconnect_ms"], result["properties_read_after_reconnect"] = time.Since(start).Milliseconds(), len(props)
		return nil
	case "liveview":
		ctx, cancel := context.WithTimeout(ctx, 15*time.Second)
		defer cancel()
		lv, e := s.c.SonyOpenLiveView(ctx)
		if e != nil {
			return e
		}
		defer lv.Close()
		var frames []map[string]any
		for i := 0; i < 3; i++ {
			frame, e := lv.Next()
			if e != nil {
				return e
			}
			decoded, e := jpeg.Decode(bytes.NewReader(frame.JPEG))
			if e != nil {
				return fmt.Errorf("invalid live-view JPEG: %w", e)
			}
			name := fmt.Sprintf("liveview-%02d.jpg", i+1)
			if e = os.WriteFile(filepath.Join(out, name), frame.JPEG, 0600); e != nil {
				return e
			}
			frames = append(frames, map[string]any{"file": name, "bytes": len(frame.JPEG), "width": decoded.Bounds().Dx(), "height": decoded.Bounds().Dy(), "metadata_bytes": len(frame.Meta)})
		}
		result["frames"] = frames
		return nil
	case "list", "thumbnail", "download", "resume-check":
		if !s.info.SupportsSonyRemoteTransfer() {
			return errors.New("camera does not advertise the required content operations")
		}
		cs, e := firstPage(ctx, s.c)
		if e != nil {
			return e
		}
		result["page_count"], result["contents_in_page"], result["listing_complete"] = 1, len(cs), len(cs) < 100
		if e = saveJSON(filepath.Join(out, "contents-first-page.json"), cs); e != nil {
			return e
		}
		if step == "list" {
			return nil
		}
		sel, e := choose(cs)
		if e != nil {
			return e
		}
		if e = saveJSON(filepath.Join(out, "selected-file.json"), sel); e != nil {
			return e
		}
		result["selected_bytes"] = sel.File.Size
		result["selected_format"] = fmt.Sprintf("0x%04X", sel.File.Format)
		if step == "thumbnail" {
			if !s.info.Supports(ptpip.OpSonyGetContentsCompressedData) {
				return errors.New("thumbnail operation not advertised")
			}
			var b bytes.Buffer
			limited := &cappedWriter{w: &b, remaining: 8 << 20}
			n, e := s.c.SonyGetContentsCompressed(ctx, 1, sel.ContentID, sel.File.ID, ptpip.SonyThumbnail, limited)
			if e != nil {
				return e
			}
			if n == 0 || n != int64(b.Len()) {
				return errors.New("empty or inconsistent thumbnail")
			}
			result["thumbnail_bytes"] = n
			return os.WriteFile(filepath.Join(out, "thumbnail.bin"), b.Bytes(), 0600)
		}
		dst := filepath.Join(out, "download"+strings.ToLower(filepath.Ext(sel.File.Path)))
		f, e := os.OpenFile(dst, os.O_CREATE|os.O_EXCL|os.O_RDWR, 0600)
		if e != nil {
			return e
		}
		defer f.Close()
		var offset uint64
		if step == "resume-check" {
			if sel.File.Size <= 65536 {
				return errors.New("selected file too small for interrupted-transfer verification")
			}
			offset, e = readChunk(ctx, s.c, sel, f, 0, 65536)
			if e != nil {
				return e
			}
			// End the transport after one committed chunk, then re-authenticate.
			s.c.Close()
			s.ssh.Close()
			s = nil
			s, e = open(ctx, a, guid, log)
			if e != nil {
				return e
			}
			current, e := firstPage(ctx, s.c)
			if e != nil {
				return e
			}
			matched := false
			for _, c := range current {
				for _, file := range c.Files {
					if sameSelection(sel, selection{ContentID: c.ID, CreatedUTC: c.CreatedUTC, File: file}) {
						matched = true
					}
				}
			}
			if !matched {
				return errors.New("selected remote file changed across reconnect")
			}
			result["resumed_from_bytes"] = offset
		}
		if e = transfer(ctx, s.c, sel, f, offset); e != nil {
			return e
		}
		if e = f.Close(); e != nil {
			return e
		}
		stat, e := os.Stat(dst)
		if e != nil {
			return e
		}
		if uint64(stat.Size()) != sel.File.Size {
			return errors.New("download size differs from camera metadata")
		}
		digest, e := digestFile(dst)
		if e != nil {
			return e
		}
		result["download_sha256"], result["downloaded_bytes"] = digest, sel.File.Size
		if step == "resume-check" {
			reference, e := os.OpenFile(filepath.Join(out, "reference.bin"), os.O_CREATE|os.O_EXCL|os.O_RDWR, 0600)
			if e != nil {
				return e
			}
			e = transfer(ctx, s.c, sel, reference, 0)
			closeErr := reference.Close()
			if e != nil {
				return e
			}
			if closeErr != nil {
				return closeErr
			}
			refDigest, e := digestFile(filepath.Join(out, "reference.bin"))
			if e != nil {
				return e
			}
			result["reference_sha256"], result["resume_bytes_match"] = refDigest, digest == refDigest
			if digest != refDigest {
				return errors.New("resumed file differs from a fresh transfer")
			}
		}
		return nil
	}
	return errors.New("unsupported verification step")
}

func main() {
	step := flag.String("step", "info", "info|liveview|list|thumbnail|download|resume-check|reconnect|iso-roundtrip|capture-once")
	out := flag.String("out", "", "new local evidence directory (required)")
	guidPath := flag.String("guid-file", ".local/initiator-guid", "persistent initiator identity")
	flag.Parse()
	switch *step {
	case "info", "liveview", "list", "thumbnail", "download", "resume-check", "reconnect", "iso-roundtrip", "capture-once":
	default:
		fmt.Fprintln(os.Stderr, "Unknown step")
		os.Exit(2)
	}
	if *out == "" {
		fmt.Fprintln(os.Stderr, "-out is required")
		os.Exit(2)
	}
	var a access
	if err := json.NewDecoder(io.LimitReader(os.Stdin, 16384)).Decode(&a); err != nil {
		fmt.Fprintln(os.Stderr, "Missing local credentials")
		os.Exit(2)
	}
	ip := net.ParseIP(a.Host)
	if ip == nil || !ip.IsPrivate() || a.User == "" || a.Password == "" || a.Fingerprint == "" {
		fmt.Fprintln(os.Stderr, "Incomplete camera access information")
		os.Exit(2)
	}
	if err := os.Mkdir(*out, 0700); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(2)
	}
	result := map[string]any{"step": *step, "started_at": time.Now().UTC(), "source_commit": "02883425c9445c653b2950210187cdd1547320c2"}
	guid, err := stableGUID(*guidPath)
	if err == nil {
		ctx, cancel := context.WithTimeout(context.Background(), 2*time.Minute)
		err = run(ctx, a, guid, *step, *out, result)
		cancel()
	}
	result["ok"], result["finished_at"] = err == nil, time.Now().UTC()
	if err != nil {
		result["error"] = publicError(err, a.Password)
	}
	if e := saveJSON(filepath.Join(*out, "result.json"), result); e != nil {
		fmt.Fprintln(os.Stderr, e)
		os.Exit(1)
	}
	json.NewEncoder(os.Stdout).Encode(result)
	if err != nil {
		os.Exit(1)
	}
}
