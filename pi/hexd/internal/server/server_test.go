package server

import (
	"context"
	"io"
	"log/slog"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/coder/websocket"
	pb "github.com/wallacemartinss/hexapod/pi/hexd/gen/hexapod/v1"
	"github.com/wallacemartinss/hexapod/pi/hexd/internal/device"
	"github.com/wallacemartinss/hexapod/pi/internal/sim"
	"google.golang.org/protobuf/proto"
)

var quiet = slog.New(slog.NewTextHandler(io.Discard, nil))

type rig struct {
	sim  *sim.Sim
	dev  *device.Device
	srv  *Server
	http *httptest.Server
}

func newRig(t *testing.T, cfg Config) *rig {
	t.Helper()
	ctx, cancel := context.WithCancel(context.Background())
	t.Cleanup(cancel)
	s := sim.New(sim.Options{FirmwareVersion: "fw-test", GitHash: "abc123"})
	dev := device.New(device.Options{Logger: quiet, HexdVersion: "test",
		Dial: func(context.Context) (io.ReadWriteCloser, error) {
			a, b := net.Pipe()
			go func() { _ = s.Serve(ctx, b); b.Close() }()
			return a, nil
		}})
	go dev.Run(ctx)
	srv := New(cfg, dev, quiet)
	go srv.Run(ctx)
	h := httptest.NewServer(srv.Handler())
	t.Cleanup(h.Close)
	waitFor(t, "esp32 link", func() bool { return dev.SendCommand(&pb.Command{}) == nil })
	return &rig{s, dev, srv, h}
}

func waitFor(t *testing.T, what string, cond func() bool) {
	t.Helper()
	deadline := time.Now().Add(3 * time.Second)
	for !cond() {
		if time.Now().After(deadline) {
			t.Fatalf("timeout waiting for %s", what)
		}
		time.Sleep(10 * time.Millisecond)
	}
}

// app is a WebSocket client playing the Flutter app.
type app struct {
	t    *testing.T
	conn *websocket.Conn
	in   chan *pb.Envelope
}

func connectApp(t *testing.T, r *rig) *app {
	t.Helper()
	ctx := context.Background()
	conn, _, err := websocket.Dial(ctx, "ws"+strings.TrimPrefix(r.http.URL, "http")+"/ws", nil)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { conn.CloseNow() })
	a := &app{t: t, conn: conn, in: make(chan *pb.Envelope, 256)}
	go func() {
		for {
			_, b, err := conn.Read(ctx)
			if err != nil {
				close(a.in)
				return
			}
			var env pb.Envelope
			if proto.Unmarshal(b, &env) == nil {
				a.in <- &env
			}
		}
	}()
	return a
}

func (a *app) send(cmd *pb.Command) {
	b, _ := proto.Marshal(&pb.Envelope{Payload: &pb.Envelope_Command{Command: cmd}})
	if err := a.conn.Write(context.Background(), websocket.MessageBinary, b); err != nil {
		a.t.Fatal(err)
	}
}

func (a *app) waitState(want pb.State) {
	a.t.Helper()
	deadline := time.After(3 * time.Second)
	for {
		select {
		case env, ok := <-a.in:
			if !ok {
				a.t.Fatal("websocket closed")
			}
			if tel := env.GetTelemetry(); tel != nil && tel.State == want {
				return
			}
		case <-deadline:
			a.t.Fatalf("no %v over the websocket", want)
		}
	}
}

func (a *app) waitHello(ok func(*pb.Hello) bool) {
	a.t.Helper()
	deadline := time.After(3 * time.Second)
	for {
		select {
		case env, open := <-a.in:
			if !open {
				a.t.Fatal("websocket closed")
			}
			if h := env.GetHello(); h != nil && ok(h) {
				return
			}
		case <-deadline:
			a.t.Fatal("expected hello never arrived")
		}
	}
}

func TestAppDrivesTheBoardThroughHexd(t *testing.T) {
	r := newRig(t, Config{HexdVersion: "v-app"})
	a := connectApp(t, r)

	h := (<-a.in).GetHello()
	if h == nil || h.HexdVersion != "v-app" {
		t.Fatalf("first message should be a hello with hexd's version, got %v", h)
	}
	if h.FirmwareVersion != "fw-test" {
		// The firmware's version follows as soon as the ESP32 introduced itself.
		a.waitHello(func(h *pb.Hello) bool { return h.FirmwareVersion == "fw-test" && h.HexdVersion == "v-app" })
	}
	// The app sends commands at 20 Hz, seq left at 0: hexd stamps it.
	stop := make(chan struct{})
	go func() {
		tick := time.NewTicker(50 * time.Millisecond)
		defer tick.Stop()
		a.send(&pb.Command{Mode: pb.Mode_MODE_STAND})
		for {
			select {
			case <-stop:
				return
			case <-tick.C:
				a.send(&pb.Command{Mode: pb.Mode_MODE_WALK, Vx: 0.5})
			}
		}
	}()
	a.waitState(pb.State_STATE_NORMAL)
	time.Sleep(500 * time.Millisecond)
	a.waitState(pb.State_STATE_NORMAL) // still fine while the app talks

	// App goes silent: hexd sends ONE zero command, then the ESP32 escalates.
	close(stop)
	before := r.dev.Snapshot().Telemetry.LastCommandSeq
	a.waitState(pb.State_STATE_STOPPING)
	a.waitState(pb.State_STATE_SAFE_SIT)
	after := r.dev.Snapshot().Telemetry.LastCommandSeq
	if after-before > 2 { // the deadman command, maybe one in-flight app command
		t.Fatalf("hexd kept forwarding after the app went silent: seq %d -> %d", before, after)
	}
	r.srv.mu.Lock()
	trips := r.srv.deadmanTrips
	r.srv.mu.Unlock()
	if trips != 1 {
		t.Fatalf("deadman trips = %d, want 1", trips)
	}
}

func TestCrossOriginBrowserRejected(t *testing.T) {
	r := newRig(t, Config{})
	_, resp, err := websocket.Dial(context.Background(), "ws"+strings.TrimPrefix(r.http.URL, "http")+"/ws",
		&websocket.DialOptions{HTTPHeader: http.Header{"Origin": []string{"http://evil.example"}}})
	if err == nil {
		t.Fatal("cross-origin websocket accepted")
	}
	if resp != nil && resp.StatusCode != http.StatusForbidden {
		t.Fatalf("status %d, want 403", resp.StatusCode)
	}
}

func get(t *testing.T, url string) (int, string) {
	t.Helper()
	resp, err := http.Get(url)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	b, _ := io.ReadAll(resp.Body)
	return resp.StatusCode, string(b)
}

func TestHealthVersionMetrics(t *testing.T) {
	dir := t.TempDir()
	temp := filepath.Join(dir, "temp")
	wireless := filepath.Join(dir, "wireless")
	for path, content := range map[string]string{
		temp: "48312\n",
		wireless: "Inter-| sta-|   Quality        |\n face | tus | link level noise |\n" +
			" wlan0: 0000   55.  -61.  -256        0      0      0      0     12        0\n",
	} {
		if err := os.WriteFile(path, []byte(content), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	r := newRig(t, Config{HexdVersion: "v-test", PiTemperaturePath: temp, WirelessPath: wireless, WifiInterface: "wlan0"})

	if code, _ := get(t, r.http.URL+"/health"); code != 200 {
		t.Fatalf("/health = %d", code)
	}
	code, body := get(t, r.http.URL+"/version")
	if code != 200 || !strings.Contains(body, `"firmware_version":"fw-test"`) || !strings.Contains(body, `"hexd_version":"v-test"`) {
		t.Fatalf("/version = %d %s", code, body)
	}
	waitFor(t, "telemetry", func() bool { return r.dev.Snapshot().Telemetry != nil })
	if code, body := get(t, r.http.URL+"/status"); code != 200 || !strings.Contains(body, `"state":"RELAXED"`) ||
		!strings.Contains(body, `"connected":true`) {
		t.Fatalf("/status = %d %s", code, body)
	}
	_, metrics := get(t, r.http.URL+"/metrics")
	for _, want := range []string{
		"hexapod_esp32_up 1",
		`hexapod_state{state="RELAXED"} 1`,
		`hexapod_state{state="NORMAL"} 0`,
		`hexapod_distance_millimeters{sensor="front"}`,
		"hexapod_battery_voltage_volts 1",
		"hexapod_motion_loop_seconds 0.0003",
		"hexapod_pi_temperature_celsius 48.312",
		"hexapod_wifi_rssi_dbm -61",
		"# TYPE hexapod_link_errors_total counter",
	} {
		if !strings.Contains(metrics, want) {
			t.Errorf("/metrics missing %q", want)
		}
	}
}

func TestHealthFailsWithoutESP32(t *testing.T) {
	dev := device.New(device.Options{Logger: quiet})
	h := httptest.NewServer(New(Config{}, dev, quiet).Handler())
	defer h.Close()
	if code, body := get(t, h.URL+"/health"); code != http.StatusServiceUnavailable {
		t.Fatalf("/health = %d %s", code, body)
	}
}

func TestProfileFromInterface(t *testing.T) {
	s := New(Config{CellularInterfaces: []string{"wwan", "ppp"}}, nil, quiet)
	lo := &net.TCPAddr{IP: net.IPv4(127, 0, 0, 1)} // "lo": not cellular
	if p := s.ProfileFor(lo); p != pb.LinkProfile_LINK_PROFILE_WIFI {
		t.Fatalf("loopback -> %v", p)
	}
	s.cfg.CellularInterfaces = []string{"lo"}
	if p := s.ProfileFor(lo); p != pb.LinkProfile_LINK_PROFILE_CELLULAR {
		t.Fatalf("lo as cellular -> %v", p)
	}
}
