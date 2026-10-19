// Package tailscale lets the app put the robot on the owner's tailnet
// (remote access over 4G or any network) without a terminal: hexd starts
// `tailscale up`, hands the login link to the app, which opens it in the
// phone's browser. hexd runs as the tailscale operator (set at boot by
// hexapod-tailscale-operator.service), so it needs no root.
package tailscale

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"strings"
	"sync"
	"time"
)

// Status of the robot on the tailnet, as the app sees it.
type Status struct {
	// "running", "needs_login", "starting", "off" (logged in, stopped) or
	// "absent" (tailscale not installed or its daemon not running).
	State   string `json:"state"`
	AuthURL string `json:"auth_url,omitempty"` // open it to log in (needs_login)
	Name    string `json:"name,omitempty"`     // machine name, e.g. hexapod-k7f2
	DNSName string `json:"dns_name,omitempty"` // e.g. hexapod-k7f2.tail1234.ts.net
	IP      string `json:"ip,omitempty"`       // tailnet IPv4: what the app dials
	Account string `json:"account,omitempty"`  // tailnet owner
}

// Runner runs the tailscale CLI and returns its standard output.
type Runner func(ctx context.Context, args ...string) ([]byte, error)

// CLI runs the real `tailscale` command (C locale: stable messages).
func CLI(ctx context.Context, args ...string) ([]byte, error) {
	cmd := exec.CommandContext(ctx, "tailscale", args...)
	cmd.Env = append(os.Environ(), "LC_ALL=C")
	return cmd.Output()
}

// RestoreOperator starts hexapod-tailscale-operator.service (allowed to the
// service user by polkit), which runs `tailscale set --operator=hexapod`.
func RestoreOperator(ctx context.Context) error {
	out, err := exec.CommandContext(ctx, "systemctl", "start", "hexapod-tailscale-operator.service").CombinedOutput()
	if err != nil {
		return fmt.Errorf("%w: %s", err, strings.TrimSpace(string(out)))
	}
	return nil
}

// Client drives tailscale for the setup API. Safe for concurrent use.
type Client struct {
	Run      Runner
	Hostname string // machine name to log in with

	// Prepare runs before each login: `tailscale logout` clears the
	// operator setting that lets hexd run tailscale, so it is restored first
	// (RestoreOperator). Nil: nothing to do.
	Prepare func(ctx context.Context) error

	// LoginWait: how long Login waits for the login link (default 15 s).
	LoginWait time.Duration
	// Poll: how often Login checks for it (default 300 ms).
	Poll time.Duration

	mu       sync.Mutex
	upCancel context.CancelFunc // a `tailscale up` waiting for the login
	upErr    error              // why the last `tailscale up` ended early
}

// Status asks tailscaled.
func (c *Client) Status(ctx context.Context) (Status, error) {
	out, err := c.Run(ctx, "status", "--json", "--peers=false")
	if len(out) == 0 && err != nil {
		var exitErr *exec.ExitError
		if errors.As(err, &exitErr) || errors.Is(err, exec.ErrNotFound) {
			return Status{State: "absent"}, nil
		}
		return Status{}, err
	}
	var raw struct {
		BackendState string
		AuthURL      string
		TailscaleIPs []string
		Self         *struct {
			HostName string
			DNSName  string
		}
		CurrentTailnet *struct{ Name string }
	}
	if err := json.Unmarshal(out, &raw); err != nil {
		return Status{}, err
	}
	s := Status{AuthURL: raw.AuthURL}
	switch raw.BackendState {
	case "Running":
		s.State = "running"
	case "NeedsLogin", "NeedsMachineAuth":
		s.State = "needs_login"
	case "Stopped":
		s.State = "off"
	default: // NoState, Starting
		s.State = "starting"
	}
	if s.State == "running" {
		s.AuthURL = ""
		if raw.Self != nil {
			s.Name = raw.Self.HostName
			s.DNSName = strings.TrimSuffix(raw.Self.DNSName, ".")
		}
		for _, ip := range raw.TailscaleIPs {
			if !strings.Contains(ip, ":") {
				s.IP = ip
				break
			}
		}
		if raw.CurrentTailnet != nil {
			s.Account = raw.CurrentTailnet.Name
		}
	}
	return s, nil
}

// Login starts `tailscale up` (it waits in the background for the owner to
// log in, up to 10 min) and returns as soon as tailscaled has a login link,
// or is running already (logged in before: no link needed).
func (c *Client) Login(ctx context.Context) (Status, error) {
	if s, err := c.Status(ctx); err != nil || s.State == "running" || s.State == "absent" {
		return s, err
	}
	if c.Prepare != nil {
		if err := c.Prepare(ctx); err != nil {
			return Status{}, fmt.Errorf("restoring the tailscale operator: %w", err)
		}
	}
	c.mu.Lock()
	if c.upCancel == nil {
		upCtx, cancel := context.WithTimeout(context.Background(), 10*time.Minute)
		c.upCancel = cancel
		args := []string{"up"}
		if c.Hostname != "" {
			args = append(args, "--hostname="+c.Hostname)
		}
		c.upErr = nil
		go func() {
			out, err := c.Run(upCtx, args...)
			c.mu.Lock()
			if err != nil && upCtx.Err() == nil {
				c.upErr = fmt.Errorf("tailscale up: %w: %s", err, strings.TrimSpace(string(out)))
			}
			cancel()
			c.upCancel = nil
			c.mu.Unlock()
		}()
	}
	c.mu.Unlock()

	wait, poll := c.LoginWait, c.Poll
	if wait == 0 {
		wait = 15 * time.Second
	}
	if poll == 0 {
		poll = 300 * time.Millisecond
	}
	deadline := time.Now().Add(wait)
	for {
		s, err := c.Status(ctx)
		if err == nil && (s.AuthURL != "" || s.State == "running") {
			return s, nil
		}
		c.mu.Lock()
		upErr := c.upErr
		c.mu.Unlock()
		if upErr != nil {
			return s, upErr
		}
		if time.Now().After(deadline) {
			if err == nil {
				err = errors.New("tailscale gave no login link")
			}
			return s, err
		}
		select {
		case <-ctx.Done():
			return s, ctx.Err()
		case <-time.After(poll):
		}
	}
}

// Logout takes the robot off the tailnet (the owner can log in again).
func (c *Client) Logout(ctx context.Context) error {
	c.mu.Lock()
	if c.upCancel != nil {
		c.upCancel()
	}
	c.mu.Unlock()
	_, err := c.Run(ctx, "logout")
	return err
}
