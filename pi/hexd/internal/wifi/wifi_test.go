package wifi

import (
	"context"
	"errors"
	"io"
	"log/slog"
	"path/filepath"
	"slices"
	"strings"
	"testing"
	"time"
)

// fakeNM plays NetworkManager: profiles, the active one, networks in range
// and their passwords.
type fakeNM struct {
	present  bool
	active   string
	profiles map[string]map[string]string // name -> settings (ssid, psk, mode)
	inRange  map[string]string            // ssid -> right password ("" = open)
	calls    []string
}

func newFake() *fakeNM {
	return &fakeNM{present: true, profiles: map[string]map[string]string{}, inRange: map[string]string{}}
}

func arg(args []string, key string) string {
	if i := slices.Index(args, key); i >= 0 && i+1 < len(args) {
		return args[i+1]
	}
	return ""
}

func (f *fakeNM) run(_ context.Context, args ...string) (string, error) {
	f.calls = append(f.calls, strings.Join(args, " "))
	j := strings.Join(args, " ")
	switch {
	case strings.HasPrefix(j, "-t -f DEVICE,TYPE,STATE,CONNECTION device"):
		state := "disconnected"
		switch {
		case !f.present:
			state = "unavailable"
		case f.active != "":
			state = "connected"
		}
		return "eth0:ethernet:connected:Wired\nwlan0:wifi:" + state + ":" + f.active + "\n", nil
	case strings.HasPrefix(j, "-t -g IP4.ADDRESS"):
		return "10.0.0.86/24\n", nil
	case j == "-t -f NAME,TYPE connection show":
		var b strings.Builder
		for name := range f.profiles {
			b.WriteString(name + ":802-11-wireless\n")
		}
		return b.String() + "Wired:802-3-ethernet\n", nil
	case strings.HasPrefix(j, "-t -g 802-11-wireless.ssid,802-11-wireless.mode connection show "):
		p := f.profiles[args[len(args)-1]]
		mode := p["mode"]
		if mode == "" {
			mode = "infrastructure"
		}
		return p["ssid"] + "\n" + mode + "\n", nil
	case strings.HasPrefix(j, "-t -g connection.id connection show "):
		if _, ok := f.profiles[args[len(args)-1]]; !ok {
			return "", errors.New("no such connection profile")
		}
		return args[len(args)-1] + "\n", nil
	case strings.HasPrefix(j, "connection add") || strings.HasPrefix(j, "connection modify"):
		name := arg(args, "con-name")
		if args[1] == "modify" {
			name = args[2]
		}
		f.profiles[name] = map[string]string{
			"ssid": arg(args, "ssid"), "psk": arg(args, "wifi-sec.psk"), "mode": arg(args, "802-11-wireless.mode"),
		}
		return "", nil
	case strings.Contains(j, "connection up "):
		name := args[len(args)-1]
		p, ok := f.profiles[name]
		if !ok {
			return "", errors.New("unknown connection")
		}
		if p["mode"] == "ap" {
			f.active = name
			return "", nil
		}
		right, here := f.inRange[p["ssid"]]
		switch {
		case !here:
			return "", errors.New("No network with SSID '" + p["ssid"] + "' found")
		case right != p["psk"]:
			return "", errors.New("Secrets were required, but not provided")
		}
		f.active = name
		return "", nil
	case strings.HasPrefix(j, "connection down "):
		if f.active == args[len(args)-1] {
			f.active = ""
		}
		return "", nil
	case strings.HasPrefix(j, "connection delete "):
		delete(f.profiles, args[len(args)-1])
		return "", nil
	case strings.HasPrefix(j, "-t -f SSID,SIGNAL,SECURITY device wifi list"):
		var b strings.Builder
		for ssid, pw := range f.inRange {
			sec := "WPA2"
			if pw == "" {
				sec = ""
			}
			b.WriteString(strings.ReplaceAll(ssid, ":", `\:`) + ":70:" + sec + "\n")
		}
		return b.String(), nil
	}
	return "", errors.New("fake nmcli: unexpected " + j)
}

func manager(t *testing.T, f *fakeNM, apps int) *Manager {
	t.Helper()
	m := New(Options{
		NM: NM{Run: f.run, Iface: "wlan0"}, APSSID: "Hexapode-7F3A", APPassword: "SECRETPASS12",
		SettingsPath:  filepath.Join(t.TempDir(), "network.json"),
		FallbackAfter: 45 * time.Second, RetryHomeEvery: 2 * time.Minute, JoinWait: 30, Tick: time.Hour,
		Apps: func() int { return apps }, Log: slog.New(slog.NewTextHandler(io.Discard, nil)),
	})
	ctx := context.Background()
	m.home = time.Now()
	if err := m.opt.NM.EnsureAP(ctx, m.opt.APSSID, m.opt.APPassword); err != nil {
		t.Fatal(err)
	}
	m.refreshSaved(ctx)
	return m
}

func TestFirstBootOpensItsOwnNetwork(t *testing.T) {
	f := newFake()
	m := manager(t, f, 0)
	m.step(context.Background(), time.Now())
	s := m.Status()
	if s.State != StateOwn || s.SSID != "Hexapode-7F3A" || s.IP != APAddress || f.active != apName {
		t.Fatalf("no saved network: own network expected at once, got %+v", s)
	}
	if p := f.profiles[apName]; p["psk"] != "SECRETPASS12" || p["mode"] != "ap" {
		t.Fatalf("own network profile: %v", p)
	}
}

func TestJoinWithTheRightPassword(t *testing.T) {
	f := newFake()
	f.inRange["Casa"] = "senha-certa"
	m := manager(t, f, 0)
	ctx := context.Background()
	m.step(ctx, time.Now())
	m.do(ctx, join{"Casa", "senha-certa"})
	m.step(ctx, time.Now())
	s := m.Status()
	if s.State != StateHome || s.SSID != "Casa" || s.Error != "" || !slices.Contains(s.Saved, "Casa") {
		t.Fatalf("after join: %+v", s)
	}
	if again := New(m.opt); again.Status().Mode != ModeHome {
		t.Fatal("mode not persisted")
	}
}

func TestWrongPasswordComesBack(t *testing.T) {
	f := newFake()
	f.inRange["Casa"] = "senha-certa"
	m := manager(t, f, 0)
	ctx := context.Background()
	m.step(ctx, time.Now())
	m.do(ctx, join{"Casa", "errada123"})
	s := m.Status()
	if s.State != StateOwn || f.active != apName {
		t.Fatalf("a wrong password must bring the robot back to its own network: %+v", s)
	}
	if !strings.Contains(s.Error, "senha incorreta") || slices.Contains(s.Saved, "Casa") {
		t.Fatalf("error and cleanup: %+v", s)
	}
}

func TestUnknownNetworkComesBackToo(t *testing.T) {
	f := newFake()
	m := manager(t, f, 0)
	m.do(context.Background(), join{"Longe", "qualquer1"})
	if s := m.Status(); s.State != StateOwn || !strings.Contains(s.Error, "rede não encontrada") {
		t.Fatalf("%+v", s)
	}
}

func TestDirectModeStaysOnItsOwnNetwork(t *testing.T) {
	f := newFake()
	f.inRange["Casa"] = "senha-certa"
	m := manager(t, f, 0)
	ctx := context.Background()
	m.do(ctx, join{"Casa", "senha-certa"})
	m.step(ctx, time.Now())
	m.do(ctx, ModeDirect)
	m.step(ctx, time.Now())
	if s := m.Status(); s.Mode != ModeDirect || s.State != StateOwn || f.active != apName {
		t.Fatalf("direct mode: %+v active=%s", s, f.active)
	}
	if New(m.opt).Status().Mode != ModeDirect {
		t.Fatal("direct mode not persisted")
	}
}

func TestFallbackThenBackHomeWhenNobodyUsesIt(t *testing.T) {
	f := newFake()
	f.inRange["Casa"] = "senha-certa"
	ctx := context.Background()
	m := manager(t, f, 0)
	m.do(ctx, join{"Casa", "senha-certa"})

	delete(f.inRange, "Casa") // router off
	f.active = ""
	t0 := time.Now()
	m.home = t0
	m.step(ctx, t0.Add(10*time.Second))
	if s := m.Status(); s.State != StateConnecting {
		t.Fatalf("give NetworkManager time first: %+v", s)
	}
	m.step(ctx, t0.Add(50*time.Second))
	if s := m.Status(); s.State != StateOwn {
		t.Fatalf("after 45 s without home: own network expected, %+v", s)
	}

	f.inRange["Casa"] = "senha-certa" // router back
	m.step(ctx, t0.Add(50*time.Second+3*time.Minute))
	m.step(ctx, t0.Add(50*time.Second+3*time.Minute))
	if s := m.Status(); s.State != StateHome {
		t.Fatalf("saved network back in range: home expected, %+v", s)
	}
}

func TestNeverLeavesWhileAnAppIsConnected(t *testing.T) {
	f := newFake()
	f.inRange["Casa"] = "senha-certa"
	ctx := context.Background()
	m := manager(t, f, 1) // someone is piloting over the robot's network
	f.profiles[homePrefix+"Casa"] = map[string]string{"ssid": "Casa", "psk": "senha-certa"}
	m.refreshSaved(ctx)
	f.active = apName
	m.step(ctx, time.Now().Add(time.Hour))
	if f.active != apName {
		t.Fatal("left its own network under a connected app")
	}
}

func TestNoChip(t *testing.T) {
	f := newFake()
	f.present = false
	m := manager(t, f, 0)
	m.step(context.Background(), time.Now())
	if s := m.Status(); s.State != StateNoWiFi {
		t.Fatalf("%+v", s)
	}
}

func TestScanHidesItsOwnNetworkAndEscapes(t *testing.T) {
	f := newFake()
	f.inRange["Hexapode-7F3A"] = "x"
	f.inRange["Café: 2.4G"] = "senha"
	m := manager(t, f, 0)
	list, err := m.Scan(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if len(list) != 1 || list[0].SSID != "Café: 2.4G" || !list[0].Secure {
		t.Fatalf("%+v", list)
	}
}

func TestJoinValidatesThePassword(t *testing.T) {
	m := manager(t, newFake(), 0)
	if m.Join("Casa", "curta") == nil {
		t.Fatal("WPA passwords have 8-63 characters")
	}
	if m.Join("", "senha-longa") == nil {
		t.Fatal("empty SSID")
	}
	if m.Join("Aberta", "") != nil {
		t.Fatal("open networks have no password")
	}
}
