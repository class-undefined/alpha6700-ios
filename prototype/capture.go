package main

import (
	"context"
	"errors"
	"fmt"
	"image/jpeg"
	"os"
	"path/filepath"
	"time"

	"github.com/knallli/alpha2go/ptpip"
)

// Capture once only when the camera is already set for a single still and
// host delivery. Do not change drive mode, image destination or focus settings.
func captureOnce(ctx context.Context, c *ptpip.Client, out string, result map[string]any) error {
	props, err := c.SonyGetProps(ctx, false)
	if err != nil {
		return err
	}
	byCode := map[uint16]ptpip.SonyProp{}
	for _, p := range props {
		byCode[p.Code] = p
	}
	drive, ok := byCode[0x5013]
	if !ok || drive.Current.Int != 1 {
		return errors.New("single-shot drive mode is required; shutter was not sent")
	}
	exposure, ok := byCode[0x500E]
	if !ok || exposure.Current.Int < 1 || exposure.Current.Int > 4 {
		return errors.New("camera must already be in a still-photo P/A/S/M mode; shutter was not sent")
	}
	destination, ok := byCode[ptpip.SonyPropStoreDestination]
	if !ok || destination.Current.Int&ptpip.SonyStoreHost == 0 {
		return errors.New("host image delivery is not enabled; shutter was not sent")
	}
	ready, n, err := c.SonyCapturedPending(ctx)
	if err != nil {
		return err
	}
	if ready || n != 0 {
		return errors.New("pre-existing host images are pending; shutter was not sent")
	}
	focus, ok := byCode[0x500A]
	if !ok {
		return errors.New("focus mode was not reported; shutter was not sent")
	}
	autofocus := focus.Current.Int != 1
	result["shutter_attempts"] = 1
	result["autofocus"] = autofocus
	result["capture_intent_at"] = time.Now().UTC()
	result["must_not_repeat_automatically"] = true
	if err = saveJSON(filepath.Join(out, "capture-intent.json"), result); err != nil {
		return err
	}
	// A failed request can still have reached the camera: never retry it.
	if err = c.SonyCapture(ctx, autofocus); err != nil {
		return err
	}
	result["shutter_acknowledged"] = true
	waitCtx, cancel := context.WithTimeout(ctx, 10*time.Second)
	defer cancel()
	for {
		ready, n, err = c.SonyCapturedPending(waitCtx)
		if err != nil {
			return err
		}
		if ready && n > 0 {
			break
		}
		select {
		case <-waitCtx.Done():
			return errors.New("shutter was acknowledged but no new image arrived; no retry was made")
		case <-time.After(200 * time.Millisecond):
		}
	}
	var images []map[string]any
	for i := 0; i < 4 && ready; i++ {
		if n > 4 {
			return errors.New("unexpected image queue size after one shutter request")
		}
		path := filepath.Join(out, fmt.Sprintf("captured-%02d.bin", i+1))
		f, err := os.OpenFile(path, os.O_CREATE|os.O_EXCL|os.O_RDWR, 0600)
		if err != nil {
			return err
		}
		w := &cappedWriter{w: f, remaining: 64 << 20}
		info, count, err := c.SonyGetCapturedImage(ctx, w, nil)
		closeErr := f.Close()
		if err != nil {
			return err
		}
		if closeErr != nil {
			return closeErr
		}
		if count == 0 || count != w.written || count != int64(info.CompressedSize) {
			return errors.New("captured file size differs from its metadata")
		}
		item := map[string]any{"bytes": count, "format": fmt.Sprintf("0x%04X", info.ObjectFormat)}
		if info.ObjectFormat == 0x3801 {
			input, err := os.Open(path)
			if err != nil {
				return err
			}
			img, err := jpeg.Decode(input)
			input.Close()
			if err != nil {
				return err
			}
			item["width"], item["height"] = img.Bounds().Dx(), img.Bounds().Dy()
			jpegPath := filepath.Join(out, fmt.Sprintf("captured-%02d.jpg", i+1))
			if err = os.Rename(path, jpegPath); err != nil {
				return err
			}
			path = jpegPath
		}
		hash, err := digestFile(path)
		if err != nil {
			return err
		}
		item["sha256"], item["file"] = hash, filepath.Base(path)
		images = append(images, item)
		ready, n, err = c.SonyCapturedPending(ctx)
		if err != nil {
			return err
		}
	}
	result["captured_images"] = images
	result["host_queue_remaining"] = n
	if ready || n != 0 {
		return errors.New("new image queue remains nonempty; capture was not repeated")
	}
	return nil
}
