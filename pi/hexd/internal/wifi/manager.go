package wifi

import (
	"context"
	"encoding/json"
	"errors"
	"log/slog"
	"os"
	"path/filepath"
	"sort"
	"sync"
	"time"
)

// Mode is how the robot uses Wi-Fi.
type Mode string

const (
	// ModeHome joins a saved home network and opens its own network when
	// none works (first boot, wrong password, out of range).
	ModeHome Mode = "home"
	// ModeDirect always runs its own network: the phone connects straight
	// to the robot, anywhere, no router needed.
	ModeDirect Mode = "direct"
)

// What the Wi-Fi is doing, as the app shows it.
const (
	StateNoWiFi     = "no-wifi"    // the chip is not there (under-voltage, broken)
	StateOwn        = "own"        // running its own network
	StateHome       = "home"       // joined a home network
	StateConnecting = "connecting" // joining (or NetworkManager trying)
)

// APAddress is the robot on its own network (NetworkManager "shared").
const APAddress = "10.42.0.1"

// Status is what /api/wifi returns.
type Status struct {
	Mode   Mode     `json:"mode"`
	State  string   `json:"state"`
	SSID   string   `json:"ssid,omitempty"` // network in use (own or home)
	IP     string   `json:"ip,omitempty"`
	APSSID string   `json:"ap_ssid"` // the robot's own network
	Saved  []string `json:"saved"`   // home networks it knows
	Error  string   `json:"error,omitempty"`
}

// Options for the Manager.
type Options struct {
	NM             NM
	APSSID         string
	APPassword     string
	SettingsPath   string        // network.json (mode), on the data partition
	FallbackAfter  time.Duration // without a home network this long: own network
	RetryHomeEvery time.Duration // while on its own network, look for saved ones
	JoinWait       int           // seconds nmcli waits for a network
	Tick           time.Duration
	// Apps is how many apps are connected: the robot never leaves its own
	// network to look for home ones while someone is using it.
	Apps func() int
	Log  *slog.Logger
}

type join struct{ ssid, password string }

// Manager keeps the Wi-Fi in the wanted mode. Safe for concurrent use.
type Manager struct {
	opt   Options
	mu    sync.Mutex
	st    Status
	saved map[string]string // profile -> SSID
	work  chan any          // join | Mode | forget
	home  time.Time         // last time a home network worked (or start)
	retry time.Time         // last look for home networks
}

type forget string

// New loads the saved mode; Run does the rest.
func New(opt Options) *Manager {
	m := &Manager{opt: opt, work: make(chan any, 4), saved: map[string]string{}}
	m.st = Status{Mode: ModeHome, APSSID: opt.APSSID, State: StateConnecting, Saved: []string{}}
	if b, err := os.ReadFile(opt.SettingsPath); err == nil {
		var s struct{ Mode Mode }
		if json.Unmarshal(b, &s) == nil && (s.Mode == ModeHome || s.Mode == ModeDirect) {
			m.st.Mode = s.Mode
		}
	}
	return m
}

// Status is a copy of the current state.
func (m *Manager) Status() Status {
	m.mu.Lock()
	defer m.mu.Unlock()
	s := m.st
	s.Saved = append([]string(nil), m.st.Saved...)
	return s
}

// Scan lists the networks the robot sees.
func (m *Manager) Scan(ctx context.Context) ([]Network, error) {
	list, err := m.opt.NM.Scan(ctx)
	if err != nil {
		return nil, err
	}
	out := list[:0]
	for _, n := range list {
		if n.SSID != m.opt.APSSID { // not its own network
			out = append(out, n)
		}
	}
	return out, nil
}

var errBusy = errors.New("Wi-Fi ocupado com outra troca; tente de novo")

func (m *Manager) submit(v any) error {
	select {
	case m.work <- v:
		return nil
	default:
		return errBusy
	}
}

// Join saves a home network and moves the robot to it; if it fails the
// robot comes back to its own network with Status.Error set.
func (m *Manager) Join(ssid, password string) error {
	if ssid == "" {
		return errors.New("rede sem nome")
	}
	if password != "" && (len(password) < 8 || len(password) > 63) {
		return errors.New("a senha do Wi-Fi tem de 8 a 63 caracteres")
	}
	return m.submit(join{ssid, password})
}

// SetMode switches between home networks and the robot's own network.
func (m *Manager) SetMode(mode Mode) error {
	if mode != ModeHome && mode != ModeDirect {
		return errors.New("modo inválido")
	}
	return m.submit(mode)
}

// Forget removes a saved home network.
func (m *Manager) Forget(ssid string) error { return m.submit(forget(ssid)) }

// Run keeps the Wi-Fi in shape until ctx ends.
func (m *Manager) Run(ctx context.Context) {
	m.home = time.Now()
	if err := m.opt.NM.EnsureAP(ctx, m.opt.APSSID, m.opt.APPassword); err != nil {
		m.opt.Log.Warn("own network profile", "err", err)
	}
	m.refreshSaved(ctx)
	tick := time.NewTicker(m.opt.Tick)
	defer tick.Stop()
	m.step(ctx, time.Now())
	for {
		select {
		case <-ctx.Done():
			return
		case w := <-m.work:
			m.do(ctx, w)
			m.step(ctx, time.Now())
		case now := <-tick.C:
			m.step(ctx, now)
		}
	}
}

func (m *Manager) set(f func(*Status)) {
	m.mu.Lock()
	defer m.mu.Unlock()
	f(&m.st)
}

func (m *Manager) refreshSaved(ctx context.Context) {
	saved, err := m.opt.NM.Saved(ctx)
	if err != nil {
		return
	}
	ssids := make([]string, 0, len(saved))
	for _, s := range saved {
		ssids = append(ssids, s)
	}
	sort.Strings(ssids)
	m.saved = saved
	m.set(func(s *Status) { s.Saved = ssids })
}

func (m *Manager) startOwn(ctx context.Context) {
	if err := m.opt.NM.Up(ctx, apName, 15); err != nil {
		m.opt.Log.Warn("own network did not start", "err", err)
		return
	}
	m.opt.Log.Info("own network up", "ssid", m.opt.APSSID)
	m.set(func(s *Status) { s.State, s.SSID, s.IP = StateOwn, m.opt.APSSID, APAddress })
}

// step brings the Wi-Fi to what the mode asks for.
func (m *Manager) step(ctx context.Context, now time.Time) {
	dev, err := m.opt.NM.Device(ctx)
	if err != nil || !dev.Present {
		m.set(func(s *Status) { s.State, s.SSID, s.IP = StateNoWiFi, "", "" })
		return
	}
	own := dev.Connection == apName
	onHome := dev.Connection != "" && !own
	mode := m.Status().Mode

	switch {
	case mode == ModeDirect:
		if !own {
			if onHome {
				_ = m.opt.NM.Down(ctx, dev.Connection)
			}
			m.startOwn(ctx)
		}
	case onHome:
		m.home = now
		m.set(func(s *Status) {
			s.State, s.SSID, s.IP = StateHome, m.saved[dev.Connection], dev.IP
			if s.SSID == "" {
				s.SSID = dev.Connection
			}
		})
	case own:
		m.set(func(s *Status) { s.State, s.SSID, s.IP = StateOwn, m.opt.APSSID, APAddress })
		if now.Sub(m.retry) >= m.opt.RetryHomeEvery && m.opt.Apps() == 0 && len(m.saved) > 0 {
			m.retry = now
			m.tryHome(ctx)
		}
	default: // nothing up: NetworkManager may still be trying a saved network
		if len(m.saved) == 0 || now.Sub(m.home) >= m.opt.FallbackAfter {
			m.retry = now
			m.startOwn(ctx)
		} else {
			m.set(func(s *Status) { s.State = StateConnecting })
		}
	}
}

// tryHome leaves the robot's own network for a saved network in range, and
// comes back if none connects.
func (m *Manager) tryHome(ctx context.Context) {
	seen, err := m.opt.NM.Scan(ctx)
	if err != nil {
		return
	}
	inRange := map[string]bool{}
	for _, n := range seen {
		inRange[n.SSID] = true
	}
	for name, ssid := range m.saved {
		if !inRange[ssid] {
			continue
		}
		m.opt.Log.Info("trying a saved network", "ssid", ssid)
		_ = m.opt.NM.Down(ctx, apName)
		if m.opt.NM.Up(ctx, name, m.opt.JoinWait) == nil {
			m.home = time.Now()
			return
		}
	}
	m.startOwn(ctx)
}

func (m *Manager) do(ctx context.Context, w any) {
	switch w := w.(type) {
	case Mode:
		m.set(func(s *Status) { s.Mode, s.Error = w, "" })
		m.saveMode(w)
		if w == ModeHome {
			m.retry = time.Time{} // look for home networks right away
			if dev, err := m.opt.NM.Device(ctx); err == nil && dev.Connection == apName && m.opt.Apps() == 0 {
				m.tryHome(ctx)
			}
		}
	case forget:
		for name, ssid := range m.saved {
			if ssid == string(w) {
				_ = m.opt.NM.Delete(ctx, name)
			}
		}
		m.refreshSaved(ctx)
	case join:
		m.set(func(s *Status) { s.Mode, s.State, s.SSID, s.Error = ModeHome, StateConnecting, w.ssid, "" })
		m.saveMode(ModeHome)
		name, err := m.opt.NM.AddHome(ctx, w.ssid, w.password)
		if err == nil {
			_ = m.opt.NM.Down(ctx, apName)
			err = m.opt.NM.Up(ctx, name, m.opt.JoinWait)
		}
		if err != nil {
			reason := joinError(err)
			m.opt.Log.Warn("join failed, back to own network", "ssid", w.ssid, "err", err)
			_ = m.opt.NM.Delete(ctx, name) // a wrong password must not keep retrying
			m.refreshSaved(ctx)
			m.startOwn(ctx)
			m.set(func(s *Status) { s.Error = w.ssid + ": " + reason.Error() })
			return
		}
		m.home = time.Now()
		m.refreshSaved(ctx)
		m.opt.Log.Info("joined", "ssid", w.ssid)
	}
}

func (m *Manager) saveMode(mode Mode) {
	b, _ := json.Marshal(map[string]Mode{"mode": mode})
	if err := os.MkdirAll(filepath.Dir(m.opt.SettingsPath), 0o755); err == nil {
		tmp := m.opt.SettingsPath + ".tmp"
		if os.WriteFile(tmp, b, 0o600) == nil {
			_ = os.Rename(tmp, m.opt.SettingsPath)
		}
	}
}
