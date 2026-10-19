package server

import (
	"context"
	"io"
	"net/http"
	"strings"
	"testing"

	"github.com/wallacemartinss/hexapod/pi/hexd/internal/pairing"
	"github.com/wallacemartinss/hexapod/pi/hexd/internal/tailscale"
)

type fakeTailscale struct{ st tailscale.Status }

func (f *fakeTailscale) Status(context.Context) (tailscale.Status, error) { return f.st, nil }
func (f *fakeTailscale) Login(context.Context) (tailscale.Status, error) {
	f.st = tailscale.Status{State: "needs_login", AuthURL: "https://login.tailscale.com/a/abc"}
	return f.st, nil
}
func (f *fakeTailscale) Logout(context.Context) error {
	f.st = tailscale.Status{State: "needs_login"}
	return nil
}

func TestTailscaleAPI(t *testing.T) {
	id, _ := pairing.New()
	ts := &fakeTailscale{st: tailscale.Status{State: "needs_login"}}
	r := newRig(t, Config{Identity: &id, Tailscale: ts})
	call := func(method, path, key string) (int, string) {
		req, _ := http.NewRequest(method, r.http.URL+path, nil)
		if key != "" {
			req.Header.Set("Authorization", "Bearer "+key)
		}
		resp, err := http.DefaultClient.Do(req)
		if err != nil {
			t.Fatal(err)
		}
		defer resp.Body.Close()
		b, _ := io.ReadAll(resp.Body)
		return resp.StatusCode, string(b)
	}

	// Only a paired app may put the robot on a tailnet.
	if code, _ := call("POST", "/api/tailscale/login", ""); code != http.StatusUnauthorized {
		t.Fatalf("login without key: %d", code)
	}
	if code, body := call("POST", "/api/tailscale/login", id.Token); code != 200 ||
		!strings.Contains(body, `"auth_url":"https://login.tailscale.com/a/abc"`) {
		t.Fatalf("login: %d %s", code, body)
	}
	ts.st = tailscale.Status{State: "running", IP: "100.115.230.65", Name: "hexapod-7f3a"}
	if code, body := call("GET", "/api/tailscale", id.Token); code != 200 || !strings.Contains(body, `"ip":"100.115.230.65"`) {
		t.Fatalf("status: %d %s", code, body)
	}
	if code, _ := call("POST", "/api/tailscale/logout", id.Token); code != 200 || ts.st.State != "needs_login" {
		t.Fatalf("logout: %d %+v", code, ts.st)
	}
}

func TestTailscaleAPIOff(t *testing.T) {
	id, _ := pairing.New()
	r := newRig(t, Config{Identity: &id})
	req, _ := http.NewRequest("GET", r.http.URL+"/api/tailscale", nil)
	req.Header.Set("Authorization", "Bearer "+id.Token)
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	resp.Body.Close()
	if resp.StatusCode != http.StatusNotFound {
		t.Errorf("without tailscale: %d, want 404", resp.StatusCode)
	}
}
