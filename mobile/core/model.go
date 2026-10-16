// Package core runs entirely inside the iOS process. It never launches a shell
// or depends on a companion server. JSON is only the local Swift/C ABI boundary.
package core

import (
	"encoding/json"
	"errors"
	"fmt"
	"math"
	"reflect"
	"regexp"
	"strconv"
	"strings"
	"unicode/utf16"

	"github.com/knallli/alpha2go/propdb"
	"github.com/knallli/alpha2go/ptpip"
)

type Access struct{ Host, User, Password, Fingerprint string }
type Request struct {
	Op      string          `json:"op"`
	Access  Access          `json:"access"`
	Code    uint16          `json:"code"`
	Value   json.RawMessage `json:"value"`
	ID      uint32          `json:"id"`
	FileID  uint16          `json:"fileID"`
	X, Y    int
	Steps   int16  `json:"steps"`
	Enabled bool   `json:"enabled"`
	Confirm bool   `json:"confirm"`
	Path    string `json:"path"`
	Name    string `json:"name"`
	Slot    uint16 `json:"slot"`
	Offset  int    `json:"offset"`
}
type Reply struct {
	OK    bool   `json:"ok"`
	Data  any    `json:"data,omitempty"`
	Error string `json:"error,omitempty"`
}

var privateURL = regexp.MustCompile(`(?i)https?://[^\s"<>]+`)

func encodeReply(data any, err error, secrets ...string) string {
	r := Reply{OK: err == nil, Data: data}
	if err != nil {
		r.Data = nil
		r.Error = privateURL.ReplaceAllString(err.Error(), "[camera URL redacted]")
		for _, s := range secrets {
			if s != "" {
				r.Error = strings.ReplaceAll(r.Error, s, "[redacted]")
			}
		}
	}
	b, e := json.Marshal(r)
	if e != nil {
		return `{"ok":false,"error":"Response encoding failed"}`
	}
	return string(b)
}

// Values are strings at the UI boundary so 64-bit values never round through a
// JSON double. Array and string properties retain their exact type.
func valueText(t uint16, v ptpip.SonyValue) string {
	if t == 0xffff {
		return v.Str
	}
	if t&0x4000 != 0 {
		b, _ := json.Marshal(v.Arr)
		return string(b)
	}
	if t == 8 {
		return strconv.FormatUint(uint64(v.Int), 10)
	}
	return strconv.FormatInt(v.Int, 10)
}
func parseValue(t uint16, text string) (ptpip.SonyValue, error) {
	var v ptpip.SonyValue
	if t == 0xffff {
		if len(utf16.Encode([]rune(text))) > 254 {
			return v, errors.New("String is too long")
		}
		v.Str = text
		return v, nil
	}
	if t&0x4000 != 0 {
		if err := json.Unmarshal([]byte(text), &v.Arr); err != nil {
			return v, err
		}
		for _, n := range v.Arr {
			if err := scalarFits(t&^0x4000, n); err != nil {
				return v, err
			}
		}
		return v, nil
	}
	if t == 8 {
		n, e := strconv.ParseUint(text, 10, 64)
		v.Int = int64(n)
		return v, e
	}
	n, e := strconv.ParseInt(text, 10, 64)
	if e != nil {
		return v, e
	}
	v.Int = n
	return v, scalarFits(t, n)
}
func scalarFits(t uint16, n int64) error {
	valid := false
	switch t {
	case 1:
		valid = n >= math.MinInt8 && n <= math.MaxInt8
	case 2:
		valid = n >= 0 && n <= math.MaxUint8
	case 3:
		valid = n >= math.MinInt16 && n <= math.MaxInt16
	case 4:
		valid = n >= 0 && n <= math.MaxUint16
	case 5:
		valid = n >= math.MinInt32 && n <= math.MaxInt32
	case 6:
		valid = n >= 0 && n <= math.MaxUint32
	case 7, 8:
		valid = true
	}
	if !valid {
		return errors.New("Value exceeds the camera datatype")
	}
	return nil
}
func equalValue(t uint16, a, b ptpip.SonyValue) bool { return valueText(t, a) == valueText(t, b) }
func validateValue(p ptpip.SonyProp, v ptpip.SonyValue) error {
	if !p.Writable || p.Enabled != 1 {
		return errors.New("This setting is not writable in the current camera mode")
	}
	if p.Form == 2 {
		for _, a := range p.Settable {
			if equalValue(p.Type, a, v) {
				return nil
			}
		}
		return errors.New("Value is not in the camera's current allowed list")
	}
	if p.Form == 1 {
		if p.Type < 1 || p.Type > 8 {
			return errors.New("Non-numeric ranges are unsupported")
		}
		// Compare unsigned 64-bit values without overflow.
		if p.Type == 8 {
			n, lo, hi, step := uint64(v.Int), uint64(p.Min.Int), uint64(p.Max.Int), uint64(p.Step.Int)
			if n < lo || n > hi || (step > 0 && (n-lo)%step != 0) {
				return errors.New("Value is outside the camera range")
			}
		} else if v.Int < p.Min.Int || v.Int > p.Max.Int || (p.Step.Int > 0 && (uint64(v.Int)-uint64(p.Min.Int))%uint64(p.Step.Int) != 0) {
			return errors.New("Value is outside the camera range")
		}
	}
	return nil
}

type Choice struct {
	Value string `json:"value"`
	Label string `json:"label"`
}
type Property struct {
	Code        uint16   `json:"code"`
	Name        string   `json:"name"`
	Group       string   `json:"group"`
	Description string   `json:"description"`
	Value       string   `json:"value"`
	Display     string   `json:"display"`
	Writable    bool     `json:"writable"`
	Type        uint16   `json:"type"`
	Form        uint8    `json:"form"`
	Choices     []Choice `json:"choices"`
	Min         string   `json:"min"`
	Max         string   `json:"max"`
	Step        string   `json:"step"`
	Caution     string   `json:"caution"`
}

func property(p ptpip.SonyProp) Property {
	info, ok := propdb.Lookup(p.Code)
	switch p.Code {
	case 0xD21E:
		info.Name = "ISO"
		info.Group = "Exposure"
		info.Desc = "感光度。可选值来自相机；带模式标记的值保留机身原始编码。"
		ok = true
	case 0xD20D:
		info.Name = "Shutter speed"
		info.Group = "Exposure"
		info.Desc = "快门速度，以秒或分数显示。"
		ok = true
	}
	if !ok {
		if name, group, found := catalogName(p.Code); found {
			info.Name = name
			info.Group = group
			info.Desc = "相机报告的参数。可用范围会随机身模式改变。"
			ok = true
		}
	}
	if !ok {
		info.Name = fmt.Sprintf("0x%04X", p.Code)
		info.Group = "Undocumented"
		info.Desc = "Camera-reported property; semantics not documented."
	}
	label := func(v ptpip.SonyValue) string {
		if s, ok := info.Labels[v.Int]; ok && p.Type != 0xffff && p.Type&0x4000 == 0 {
			return s
		}
		if info.Scale > 0 {
			return fmt.Sprintf("%g %s", float64(v.Int)/info.Scale, info.Unit)
		}
		return valueText(p.Type, v)
	}
	choices := []Choice{}
	for _, v := range p.Settable {
		choices = append(choices, Choice{valueText(p.Type, v), label(v)})
	}
	return Property{p.Code, info.Name, info.Group, info.Desc, valueText(p.Type, p.Current), label(p.Current), p.Writable && p.Enabled == 1, p.Type, p.Form, choices, valueText(p.Type, p.Min), valueText(p.Type, p.Max), valueText(p.Type, p.Step), info.Note}
}
func sameFile(a, b Selection) bool {
	return a.Camera == b.Camera && a.ContentID == b.ContentID && a.Created == b.Created && reflect.DeepEqual(a.File, b.File)
}
