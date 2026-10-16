package core

import (
	"context"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"sync"
	"time"

	"github.com/knallli/alpha2go/ptpip"
)

type Engine struct {
	op         sync.Mutex
	mu         sync.Mutex
	client     *ptpip.Client
	tunnel     *ptpip.SSHDialer
	cancel     context.CancelFunc
	liveCancel context.CancelFunc
	frame      []byte
	frameAt    time.Time
	frameMeta  ptpip.SonyLiveViewInfo
	liveError  string
	events     []ptpip.Event
	liveWG     sync.WaitGroup
	guid       [16]byte
	root       string
	access     Access
	info       *ptpip.DeviceInfo
	ext        *ptpip.SonyExtInfo
	contents   []ptpip.SonyContent
	listed     bool
}

func New(root, guid string) (*Engine, error) {
	raw, e := hex.DecodeString(strings.ReplaceAll(guid, "-", ""))
	if e != nil || len(raw) != 16 {
		return nil, errors.New("Invalid stable initiator ID")
	}
	if e = os.MkdirAll(root, 0700); e != nil {
		return nil, e
	}
	s := &Engine{root: root}
	copy(s.guid[:], raw)
	return s, nil
}

// Abort interrupts in-flight network work from another thread. It never waits
// for the serial command lock, which is important when iOS suspends the app.
func (s *Engine) Abort() {
	s.mu.Lock()
	if s.cancel != nil {
		s.cancel()
	}
	if s.liveCancel != nil {
		s.liveCancel()
	}
	c, d := s.client, s.tunnel
	s.mu.Unlock()
	if c != nil {
		_ = c.Close()
	}
	if d != nil {
		_ = d.Close()
	}
}
func (s *Engine) Frame() []byte {
	s.mu.Lock()
	defer s.mu.Unlock()
	if time.Since(s.frameAt) > 3*time.Second {
		return nil
	}
	return append([]byte(nil), s.frame...)
}
func (s *Engine) stopLive() {
	s.mu.Lock()
	cancel := s.liveCancel
	s.liveCancel = nil
	s.mu.Unlock()
	if cancel != nil {
		cancel()
	}
	s.liveWG.Wait()
	s.mu.Lock()
	s.frame = nil
	s.frameAt = time.Time{}
	s.mu.Unlock()
}
func (s *Engine) close() {
	s.stopLive()
	s.mu.Lock()
	c, d := s.client, s.tunnel
	s.client = nil
	s.tunnel = nil
	s.mu.Unlock()
	if c != nil {
		ctx, cancel := context.WithTimeout(context.Background(), time.Second)
		_ = c.CloseSession(ctx)
		cancel()
		_ = c.Close()
	}
	if d != nil {
		_ = d.Close()
	}
	s.contents = nil
	s.listed = false
	s.info = nil
	s.ext = nil
}
func (s *Engine) connect(ctx context.Context, a Access) (any, error) {
	s.close()
	if net.ParseIP(strings.Trim(a.Host, "[]")) == nil {
		return nil, errors.New("Enter the camera IPv4 or IPv6 address")
	}
	if strings.TrimSpace(a.User) == "" || a.Password == "" || a.Fingerprint == "" {
		return nil, errors.New("Camera access username, password and verified fingerprint are required")
	}
	s.access = a
	d := ptpip.NewSSHDialer(ptpip.SSHConfig{User: a.User, Password: a.Password, Fingerprint: a.Fingerprint})
	s.mu.Lock()
	s.tunnel = d
	s.mu.Unlock()
	c, err := ptpip.Dial(ctx, net.JoinHostPort(strings.Trim(a.Host, "[]"), "15740"), ptpip.Options{Name: "Alpha Remote iOS", GUID: s.guid, IOTimeout: 8 * time.Second, DialContext: d.DialContext})
	if err != nil {
		s.close()
		return nil, err
	}
	s.mu.Lock()
	s.client = c
	s.mu.Unlock()
	if s.info, err = c.GetDeviceInfo(ctx); err == nil {
		if !s.info.IsSony() || s.info.Model != "ILCE-6700" {
			err = errors.New("This build expects a Sony ILCE-6700")
		}
	}
	if err == nil {
		err = c.OpenSession(ctx, 1)
	}
	if err == nil {
		s.ext, err = c.SonyHandshake(ctx)
	}
	if err != nil {
		s.close()
		return nil, err
	}
	s.mu.Lock()
	s.events = nil
	s.liveError = ""
	s.mu.Unlock()
	go func() {
		for ev := range c.Events() {
			s.mu.Lock()
			if s.client == c {
				s.events = append(s.events, ev)
				if len(s.events) > 80 {
					s.events = s.events[len(s.events)-80:]
				}
			}
			s.mu.Unlock()
		}
	}()
	return s.snapshot(ctx)
}
func (s *Engine) snapshot(ctx context.Context) (any, error) {
	ps, err := s.client.SonyGetProps(ctx, false)
	if err != nil {
		return nil, err
	}
	props := make([]Property, 0, len(ps))
	for _, p := range ps {
		props = append(props, property(p))
	}
	s.mu.Lock()
	events := append([]ptpip.Event{}, s.events...)
	meta, le, at := s.frameMeta, s.liveError, s.frameAt
	s.mu.Unlock()
	return map[string]any{"model": s.info.Model, "firmware": s.info.DeviceVersion, "properties": props, "controls": s.ext.Controls, "operations": s.info.Operations, "events": events, "liveMeta": meta, "liveError": le, "frameAt": at}, nil
}
func (s *Engine) startLive() error {
	s.stopLive()
	ctx, cancel := context.WithCancel(context.Background())
	s.mu.Lock()
	s.liveCancel = cancel
	s.liveError = ""
	s.mu.Unlock()
	timer := time.AfterFunc(20*time.Second, cancel)
	lv, err := s.client.SonyOpenLiveView(ctx)
	timer.Stop()
	if err != nil {
		cancel()
		return err
	}
	s.liveWG.Add(1)
	go func() {
		defer s.liveWG.Done()
		defer lv.Close()
		for {
			f, e := lv.Next()
			if e != nil {
				s.mu.Lock()
				if ctx.Err() == nil {
					s.liveError = "Live view ended; reconnect to resume"
				}
				s.mu.Unlock()
				return
			}
			meta, _ := ptpip.ParseSonyLiveViewMeta(f.Meta)
			s.mu.Lock()
			s.frame = append(s.frame[:0], f.JPEG...)
			s.frameAt = time.Now()
			s.frameMeta = meta
			s.mu.Unlock()
		}
	}()
	return nil
}
func (s *Engine) prop(ctx context.Context, code uint16) (ptpip.SonyProp, error) {
	ps, e := s.client.SonyGetProps(ctx, false)
	if e != nil {
		return ptpip.SonyProp{}, e
	}
	for _, p := range ps {
		if p.Code == code {
			return p, nil
		}
	}
	return ptpip.SonyProp{}, errors.New("Camera did not expose that property")
}
func (s *Engine) set(ctx context.Context, r Request) (any, error) {
	var text string
	if e := json.Unmarshal(r.Value, &text); e != nil {
		return nil, errors.New("Property value must be a string")
	}
	p, e := s.prop(ctx, r.Code)
	if e != nil {
		return nil, e
	}
	v, e := parseValue(p.Type, text)
	if e != nil {
		return nil, e
	}
	if e = validateValue(p, v); e != nil {
		return nil, e
	}
	if e = s.client.SonySetProp(ctx, p.Code, p.Type, v); e != nil {
		return nil, e
	}
	// Acknowledgement is not readback. Poll briefly for asynchronous changes.
	for i := 0; i < 12; i++ {
		p, e = s.prop(ctx, r.Code)
		if e != nil {
			return nil, e
		}
		if equalValue(p.Type, p.Current, v) {
			return property(p), nil
		}
		select {
		case <-ctx.Done():
			return nil, ctx.Err()
		case <-time.After(100 * time.Millisecond):
		}
	}
	return nil, errors.New("Camera acknowledged the write but readback differs; refresh before retrying")
}
func (s *Engine) hasControl(code uint16) error {
	if !slices.Contains(s.ext.Controls, code) {
		return fmt.Errorf("Camera does not advertise control 0x%04X", code)
	}
	return nil
}
func (s *Engine) pulse(ctx context.Context, code uint16) (err error) {
	if err = s.hasControl(code); err != nil {
		return
	}
	defer func() {
		rctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
		defer cancel()
		err = errors.Join(err, s.client.SonyButton(rctx, code, false))
	}()
	if err = s.client.SonyButton(ctx, code, true); err != nil {
		return
	}
	select {
	case <-ctx.Done():
		return ctx.Err()
	case <-time.After(500 * time.Millisecond):
		return nil
	}
}
func (s *Engine) availableID(ctx context.Context, code, id uint16) error {
	p, e := s.prop(ctx, code)
	if e != nil {
		return e
	}
	if p.Enabled != 1 {
		return errors.New("Control is unavailable in the current camera mode")
	}
	if !slices.ContainsFunc(p.Settable, func(v ptpip.SonyValue) bool { return v.Int == int64(id) }) {
		return errors.New("Camera does not currently allow this button or dial")
	}
	return nil
}
func (s *Engine) Request(raw string) string {
	s.op.Lock()
	defer s.op.Unlock()
	var r Request
	if e := json.Unmarshal([]byte(raw), &r); e != nil {
		return encodeReply(nil, errors.New("Invalid request"))
	}
	ctx, cancel := context.WithTimeout(context.Background(), 45*time.Second)
	s.mu.Lock()
	s.cancel = cancel
	s.mu.Unlock()
	defer func() { cancel(); s.mu.Lock(); s.cancel = nil; s.mu.Unlock() }()
	data, err := s.dispatch(ctx, r)
	if err != nil { // Session errors are exposed once. Mutations are never replayed.
		return encodeReply(nil, err, s.access.Password, s.access.User)
	}
	return encodeReply(data, nil)
}
func (s *Engine) dispatch(ctx context.Context, r Request) (any, error) {
	switch r.Op {
	case "connect":
		return s.connect(ctx, r.Access)
	case "disconnect":
		s.close()
		return true, nil
	case "discover":
		return discover(ctx)
	case "queue":
		return s.queue()
	case "discardTransfer":
		return true, s.discardTransfer(r.Name)
	}
	if s.client == nil {
		return nil, errors.New("Connect to your camera first")
	}
	switch r.Op {
	case "status":
		return s.snapshot(ctx)
	case "set":
		return s.set(ctx, r)
	case "liveStart":
		return true, s.startLive()
	case "liveStop":
		s.stopLive()
		return true, nil
	case "capture":
		if e := s.hasControl(ptpip.SonyCtlShutterFull); e != nil {
			return nil, e
		}
		return true, s.client.SonyCapture(ctx, true)
	case "focus":
		return true, s.pulse(ctx, ptpip.SonyCtlShutterHalf)
	case "movie":
		if e := s.hasControl(ptpip.SonyCtlMovie); e != nil {
			return nil, e
		}
		return true, s.client.SonyToggleMovie(ctx)
	case "touch", "afPosition":
		code := uint16(ptpip.SonyCtlRemoteTouch)
		if r.Op == "afPosition" {
			code = ptpip.SonyCtlAFAreaPosition
		}
		if e := s.hasControl(code); e != nil {
			return nil, e
		}
		if r.X < 0 || r.X > 639 || r.Y < 0 || r.Y > 479 {
			return nil, errors.New("Focus point outside viewfinder")
		}
		if r.Op == "touch" {
			p, e := s.prop(ctx, 0xD284)
			if e != nil {
				return nil, e
			}
			if p.Current.Int != 1 {
				return nil, errors.New("Enable touch tracking on the camera first")
			}
		}
		return true, s.client.SonyControl(ctx, code, 6, ptpip.SonyValue{Int: int64(r.X)<<16 | int64(r.Y)})
	case "cancelTracking":
		return true, s.pulse(ctx, ptpip.SonyCtlRemoteTouchCancel)
	case "button":
		if e := s.availableID(ctx, 0xD208, r.Code); e != nil {
			return nil, e
		}
		return true, s.client.SonyPressButton(ctx, r.Code)
	case "dial":
		if e := s.availableID(ctx, 0xD20A, r.Code); e != nil {
			return nil, e
		}
		if r.Steps < -10 || r.Steps > 10 {
			return nil, errors.New("Dial step outside -10...10")
		}
		return true, s.client.SonyTurnDial(ctx, r.Code, r.Steps)
	case "list":
		return s.list(ctx)
	case "thumbnail":
		var b boundedBuffer
		b.limit = 8 << 20
		_, e := s.client.SonyGetContentsCompressed(ctx, 1, r.ID, r.FileID, ptpip.SonyThumbnail, &b)
		return b.Bytes(), e
	case "transfer":
		return s.transferChunk(ctx, r.ID, r.FileID)
	case "fetchCapture":
		return s.fetchCapture(ctx)
	case "delete":
		if !r.Confirm {
			return nil, errors.New("Explicit delete confirmation required")
		}
		if _, e := s.selection(r.ID, r.FileID); e != nil {
			return nil, e
		}
		e := s.client.SonyDeleteContent(ctx, 1, r.ID)
		s.listed = false
		return true, e
	case "backup":
		return s.backup(ctx)
	case "restore":
		if !r.Confirm {
			return nil, errors.New("Explicit restore confirmation required")
		}
		b, e := readLimited(r.Path, 8<<20)
		if e != nil {
			return nil, e
		}
		return "Request sent; check camera result event 0xC209", s.client.SonyRestoreSettings(ctx, b)
	case "lut":
		if !r.Confirm {
			return nil, errors.New("Explicit LUT slot overwrite confirmation required")
		}
		b, e := readLimited(r.Path, 32<<20)
		if e != nil {
			return nil, e
		}
		if !strings.EqualFold(filepath.Ext(r.Name), ".cube") {
			return nil, errors.New("Select a .cube file")
		}
		return "Request sent; check camera result event 0xC214", s.client.SonyImportLUT(ctx, r.Slot, r.Name, b)
	case "clock":
		return s.client.SonyGetTimeZone(ctx)
	case "setClock":
		var tz ptpip.SonyTimeZone
		if e := json.Unmarshal(r.Value, &tz); e != nil {
			return nil, e
		}
		return true, s.client.SonySetTimeZone(ctx, tz)
	case "osd":
		if e := s.client.SonySetOSDMode(ctx, r.Enabled); e != nil {
			return nil, e
		}
		if !r.Enabled {
			return nil, nil
		}
		f, e := s.client.SonyGetOSDImage(ctx)
		return f.JPEG, e
	case "strings":
		return s.client.SonyGetDisplayStrings(ctx, 0)
	case "ftpNames":
		return s.client.SonyGetFTPServerNames(ctx)
	case "operationResults":
		return s.client.SonyGetOperationResults(ctx)
	case "description":
		b, e := s.client.SonyGetDeviceDescription(ctx)
		return string(b), e
	default:
		return nil, fmt.Errorf("Unknown action %q", r.Op)
	}
}
