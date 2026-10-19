package tailscale

import (
	"context"
	"errors"
	"os/exec"
	"strings"
	"sync"
	"testing"
	"time"
)

// fakeTS answers like tailscaled: logged out until `up` runs, then a login
// link, then running once loggedIn is closed (the owner logged in).
type fakeTS struct {
	mu       sync.Mutex
	state    string
	ups      []string
	loggedIn chan struct{}
	missing  bool
}

func (f *fakeTS) run(ctx context.Context, args ...string) ([]byte, error) {
	f.mu.Lock()
	missing := f.missing
	f.mu.Unlock()
	if missing {
		return nil, exec.ErrNotFound
	}
	switch args[0] {
	case "status":
		f.mu.Lock()
		defer f.mu.Unlock()
		switch f.state {
		case "running":
			return []byte(`{"BackendState":"Running","TailscaleIPs":["100.115.230.65","fd7a::1"],
				"Self":{"HostName":"hexapod-k7f2","DNSName":"hexapod-k7f2.tail1.ts.net."},
				"CurrentTailnet":{"Name":"owner@example.com"}}`), nil
		case "waiting":
			return []byte(`{"BackendState":"NeedsLogin","AuthURL":"https://login.tailscale.com/a/abc"}`), nil
		default:
			return []byte(`{"BackendState":"NeedsLogin","AuthURL":""}`), nil
		}
	case "up":
		f.mu.Lock()
		f.ups = append(f.ups, strings.Join(args, " "))
		f.state = "waiting"
		f.mu.Unlock()
		select { // blocks until logged in, like the real one
		case <-f.loggedIn:
			f.mu.Lock()
			f.state = "running"
			f.mu.Unlock()
			return nil, nil
		case <-ctx.Done():
			return nil, ctx.Err()
		}
	case "logout":
		f.mu.Lock()
		f.state = ""
		f.mu.Unlock()
		return nil, nil
	}
	return nil, nil
}

func TestLoginHandsTheLinkThenRuns(t *testing.T) {
	f := &fakeTS{loggedIn: make(chan struct{})}
	prepared := 0
	c := &Client{Run: f.run, Hostname: "hexapod-k7f2", Poll: time.Millisecond,
		Prepare: func(context.Context) error { prepared++; return nil }}
	ctx := context.Background()

	s, err := c.Login(ctx)
	if err != nil || s.State != "needs_login" || s.AuthURL != "https://login.tailscale.com/a/abc" {
		t.Fatalf("login: %+v %v", s, err)
	}
	// Asking again (the app retried) must not start a second `up`.
	if _, err := c.Login(ctx); err != nil {
		t.Fatal(err)
	}
	if prepared == 0 {
		t.Error("the operator was not restored before logging in")
	}
	f.mu.Lock()
	if len(f.ups) != 1 || f.ups[0] != "up --hostname=hexapod-k7f2" {
		t.Errorf("ups: %q", f.ups)
	}
	f.mu.Unlock()

	close(f.loggedIn) // the owner logged in on the phone
	deadline := time.Now().Add(2 * time.Second)
	for {
		s, _ = c.Status(ctx)
		if s.State == "running" || time.Now().After(deadline) {
			break
		}
		time.Sleep(5 * time.Millisecond)
	}
	want := Status{State: "running", Name: "hexapod-k7f2", DNSName: "hexapod-k7f2.tail1.ts.net",
		IP: "100.115.230.65", Account: "owner@example.com"}
	if s != want {
		t.Errorf("running: %+v, want %+v", s, want)
	}
	if s, _ := c.Login(ctx); s.State != "running" {
		t.Errorf("login while running: %+v", s)
	}
}

func TestLogout(t *testing.T) {
	f := &fakeTS{loggedIn: make(chan struct{}), state: "running"}
	c := &Client{Run: f.run}
	if err := c.Logout(context.Background()); err != nil {
		t.Fatal(err)
	}
	if s, _ := c.Status(context.Background()); s.State != "needs_login" {
		t.Errorf("after logout: %+v", s)
	}
}

func TestNoTailscale(t *testing.T) {
	c := &Client{Run: (&fakeTS{missing: true}).run}
	s, err := c.Login(context.Background())
	if err != nil || s.State != "absent" {
		t.Errorf("without tailscale: %+v %v", s, err)
	}
}

func TestLoginReportsWhyUpFailed(t *testing.T) {
	c := &Client{
		Run: func(ctx context.Context, args ...string) ([]byte, error) {
			if args[0] == "up" {
				return []byte("Access denied: checkprefs access denied"), errors.New("exit status 1")
			}
			return []byte(`{"BackendState":"NeedsLogin","AuthURL":""}`), nil
		},
		Poll:      time.Millisecond,
		LoginWait: time.Second,
	}
	_, err := c.Login(context.Background())
	if err == nil || !strings.Contains(err.Error(), "Access denied") {
		t.Errorf("error: %v", err)
	}
}
