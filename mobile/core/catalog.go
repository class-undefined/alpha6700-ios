package core

import (
	_ "embed"
	"encoding/json"
	"regexp"
	"strconv"
	"strings"
)

//go:embed catalog/names.json
var catalogJSON []byte
var catalogNames = func() map[string]string {
	var names map[string]string
	if err := json.Unmarshal(catalogJSON, &names); err != nil {
		panic("invalid bundled property name catalog")
	}
	return names
}()
var wordBoundary = regexp.MustCompile(`([a-z0-9])([A-Z])`)

func catalogName(code uint16) (string, string, bool) {
	name, ok := catalogNames[strconv.Itoa(int(code))]
	if !ok {
		return "", "", false
	}
	title := wordBoundary.ReplaceAllString(strings.ReplaceAll(name, "_", " "), "$1 $2")
	group := "Device"
	low := strings.ToLower(name)
	switch {
	case strings.Contains(low, "focus") || strings.HasPrefix(low, "af") || strings.Contains(low, "tracking") || strings.Contains(low, "recognition"):
		group = "Focus"
	case strings.Contains(low, "shutter") || strings.Contains(low, "iso") || strings.Contains(low, "exposure") || strings.Contains(low, "metering") || strings.Contains(low, "iris"):
		group = "Exposure"
	case strings.Contains(low, "whitebalance") || strings.Contains(low, "colortemp") || strings.Contains(low, "colortuning"):
		group = "White balance"
	case strings.Contains(low, "movie") || strings.Contains(low, "audio") || strings.Contains(low, "recording") || strings.Contains(low, "slog") || strings.Contains(low, "lut"):
		group = "Movie"
	case strings.Contains(low, "transfer") || strings.Contains(low, "ftp") || strings.Contains(low, "destination"):
		group = "Transfer"
	case strings.Contains(low, "drive") || strings.Contains(low, "bracket") || strings.Contains(low, "interval"):
		group = "Drive"
	case strings.Contains(low, "image") || strings.Contains(low, "raw") || strings.Contains(low, "jpeg") || strings.Contains(low, "heif") || strings.Contains(low, "filetype") || strings.Contains(low, "picture") || strings.Contains(low, "aspect") || strings.Contains(low, "creative"):
		group = "Image"
	case strings.Contains(low, "display") || strings.Contains(low, "monitor") || strings.Contains(low, "liveview") || strings.Contains(low, "finder") || strings.Contains(low, "peaking") || strings.Contains(low, "zebra"):
		group = "Display"
	}
	return title, group, true
}
