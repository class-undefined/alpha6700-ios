package main

import (
	"context"
	"errors"
	"fmt"
	"path/filepath"
	"time"

	"github.com/knallli/alpha2go/ptpip"
)

type isoCamera interface {
	SonyGetProps(context.Context, bool) ([]ptpip.SonyProp, error)
	SonySetProp(context.Context, uint16, uint16, ptpip.SonyValue) error
}

func isoProp(ctx context.Context, c isoCamera) (ptpip.SonyProp, error) {
	props, err := c.SonyGetProps(ctx, false)
	if err != nil {
		return ptpip.SonyProp{}, err
	}
	for _, p := range props {
		if p.Code == 0xD21E {
			return p, nil
		}
	}
	return ptpip.SonyProp{}, errors.New("camera did not return the ISO property")
}

func waitISO(ctx context.Context, c isoCamera, value int64) error {
	ctx, cancel := context.WithTimeout(ctx, 2*time.Second)
	defer cancel()
	for {
		p, err := isoProp(ctx, c)
		if err != nil {
			return err
		}
		if p.Current.Int == value {
			return nil
		}
		select {
		case <-ctx.Done():
			return fmt.Errorf("ISO did not read back as %d: %w", value, ctx.Err())
		case <-time.After(100 * time.Millisecond):
		}
	}
}

// Temporarily use one camera-advertised ISO value and verify restoration even
// when the write or its readback fails. Persist the original before any write.
func isoRoundtrip(ctx context.Context, c isoCamera, out string, result map[string]any) (err error) {
	p, err := isoProp(ctx, c)
	if err != nil {
		return err
	}
	if !p.Writable || p.Enabled != 1 || p.Type != 6 || p.Current.Int < 50 || p.Current.Int > 102400 {
		return errors.New("ISO is not an enabled, writable manual value for this check")
	}
	before := p.Current.Int
	var target int64
	best := int64(1 << 62)
	for _, v := range p.Settable {
		if v.Int < 50 || v.Int > 102400 || v.Int == before {
			continue
		}
		diff := v.Int - before
		if diff < 0 {
			diff = -diff
		}
		if diff < best {
			best, target = diff, v.Int
		}
	}
	if target == 0 {
		return errors.New("camera supplied no alternate manual ISO value")
	}
	result["iso_before"], result["iso_test_value"], result["iso_restore_verified"] = before, target, false
	planPath := filepath.Join(out, "restore-plan.json")
	if err = saveJSON(planPath, result); err != nil {
		return err
	}
	defer func() {
		rctx, cancel := context.WithTimeout(context.WithoutCancel(ctx), 8*time.Second)
		defer cancel()
		restoreErr := c.SonySetProp(rctx, p.Code, p.Type, ptpip.SonyValue{Int: before})
		result["iso_restore_acknowledged"] = restoreErr == nil
		if restoreErr == nil {
			restoreErr = waitISO(rctx, c, before)
		}
		result["iso_restore_verified"] = restoreErr == nil
		if restoreErr == nil {
			result["iso_after_restore"] = before
		}
		if restoreErr != nil {
			err = errors.Join(err, fmt.Errorf("restore original ISO %d: %w", before, restoreErr))
		}
		err = errors.Join(err, saveJSON(planPath, result))
	}()
	err = c.SonySetProp(ctx, p.Code, p.Type, ptpip.SonyValue{Int: target})
	result["iso_test_acknowledged"] = err == nil
	if err != nil {
		return err
	}
	if err = waitISO(ctx, c, target); err != nil {
		return err
	}
	result["iso_test_readback"] = target
	return nil
}
