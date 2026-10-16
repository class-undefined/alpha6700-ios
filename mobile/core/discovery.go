package core

import (
	"context"
	"io"
	"net"
	"net/http"
	"strings"
	"time"

	"github.com/knallli/alpha2go/discovery"
)

// No SSDP multicast entitlement: scan local private /24s for SSH, then confirm
// Sony metadata over unicast HTTP. Credentials are never sent during discovery.
func discover(ctx context.Context) (any, error) {
	ctx, cancel := context.WithTimeout(ctx, 12*time.Second)
	defer cancel()
	hosts := discovery.ScanPort(ctx, discovery.LocalSubnets(), 22, 250*time.Millisecond, 32)
	result := []string{}
	hc := http.Client{Timeout: 800 * time.Millisecond, CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }}
	for _, host := range hosts {
		req, e := http.NewRequestWithContext(ctx, "GET", "http://"+net.JoinHostPort(host, "64321")+"/dd.xml", nil)
		if e != nil {
			continue
		}
		r, e := hc.Do(req)
		if e != nil {
			continue
		}
		b, _ := io.ReadAll(io.LimitReader(r.Body, 64<<10))
		r.Body.Close()
		if r.StatusCode == 200 && strings.Contains(string(b), "ILCE-6700") {
			result = append(result, host)
		}
	}
	return result, nil
}
