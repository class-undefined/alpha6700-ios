package main

import (
	"context"
	"errors"
	"testing"

	"github.com/knallli/alpha2go/ptpip"
)

type fakeISO struct {
	value              int64
	writes             []int64
	readFailOnce       bool
	failReadAfterWrite bool
	canceledRestore    bool
}

func (f *fakeISO) SonyGetProps(ctx context.Context, _ bool) ([]ptpip.SonyProp, error) {
	if f.readFailOnce {
		f.readFailOnce = false
		return nil, errors.New("readback failed")
	}
	return []ptpip.SonyProp{{Code: 0xD21E, Type: 6, Writable: true, Enabled: 1, Current: ptpip.SonyValue{Int: f.value}, Settable: []ptpip.SonyValue{{Int: 200}, {Int: 250}, {Int: 320}, {Int: 0xFFFFFF}}}}, nil
}
func (f *fakeISO) SonySetProp(ctx context.Context, code, typ uint16, v ptpip.SonyValue) error {
	f.writes = append(f.writes, v.Int)
	f.value = v.Int
	if len(f.writes) == 1 && f.failReadAfterWrite {
		f.readFailOnce = true
	}
	if len(f.writes) > 1 && ctx.Err() != nil {
		f.canceledRestore = true
	}
	return nil
}

func TestISORestoredAfterSuccessfulAndFailedReadback(t *testing.T) {
	for _, fail := range []bool{false, true} {
		f := &fakeISO{value: 250, failReadAfterWrite: fail}
		result := map[string]any{}
		err := isoRoundtrip(context.Background(), f, t.TempDir(), result)
		if (err != nil) != fail {
			t.Fatalf("fail=%v err=%v", fail, err)
		}
		if f.value != 250 || len(f.writes) != 2 || f.writes[0] != 200 || f.writes[1] != 250 || result["iso_restore_verified"] != true {
			t.Fatalf("restore failed: %+v %+v", f, result)
		}
	}
}
