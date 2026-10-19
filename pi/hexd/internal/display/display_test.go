package display

import (
	"bytes"
	"context"
	"errors"
	"image"
	"image/color"
	"image/png"
	"io"
	"log/slog"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"sync"
	"testing"
	"time"

	pb "github.com/wallacemartinss/hexapod/pi/hexd/gen/hexapod/v1"
)

var quiet = slog.New(slog.NewTextHandler(io.Discard, nil))

func seated() Status {
	return Status{
		ESP32: true,
		Telemetry: &pb.Telemetry{
			State: pb.State_STATE_NORMAL, Mode: pb.Mode_MODE_SIT,
			BatteryVoltageV: 11.4,
		},
		Apps: 1, Network: "Wi-Fi Casa", IP: "10.0.0.86", Tailscale: "100.101.7.8", Version: "f0eca15",
	}
}

func TestStatusPage(t *testing.T) {
	got := Lines(seated(), PageStatus)
	want := []string{" HEXAPOD      SENTADO", "", "App: conectado", "ESP32: ok", "Bateria: 11.4V 50%", "", "10.0.0.86"}
	if strings.Join(got, "|") != strings.Join(want, "|") {
		t.Fatalf("got\n%q\nwant\n%q", got, want)
	}
	for _, line := range got {
		if n := len([]rune(line)); n > lineChars {
			t.Errorf("%q is %d chars, the panel fits %d", line, n, lineChars)
		}
	}
}

func TestBatteryWithoutMeter(t *testing.T) {
	s := seated()
	s.Telemetry.FaultFlags = uint32(pb.Fault_FAULT_POWER_MONITOR) // the bench board today
	if got := Lines(s, PageStatus)[4]; got != "Bateria: sem medidor" {
		t.Fatalf("got %q", got)
	}
}

func TestNetworkPage(t *testing.T) {
	got := strings.Join(Lines(seated(), PageNetwork), "|")
	for _, want := range []string{"REDE", "Wi-Fi Casa", "IP 10.0.0.86", "hexapod.local", "TS 100.101.7.8", "hexd f0eca15"} {
		if !strings.Contains(got, want) {
			t.Errorf("network page lacks %q: %s", want, got)
		}
	}
	s := seated()
	s.IP, s.Network = "", ""
	if got := Lines(s, PageNetwork)[2]; got != "Sem rede" {
		t.Errorf("offline: got %q", got)
	}
}

func TestAlerts(t *testing.T) {
	cases := []struct {
		name  string
		edit  func(*Status)
		head  string
		alert bool
	}{
		{"all fine", func(*Status) {}, "", false},
		{"esp32 silent", func(s *Status) { s.ESP32 = false }, "ESP32", true},
		{"estop", func(s *Status) { s.Telemetry.State = pb.State_STATE_ESTOP }, "PARADO", true},
		{"tipped", func(s *Status) { s.Telemetry.State = pb.State_STATE_TIPPED }, "TOMBOU", true},
		{"battery", func(s *Status) { s.Telemetry.State = pb.State_STATE_LOW_BATTERY }, "BATERIA", true},
		{"gas wins over estop", func(s *Status) {
			s.Telemetry.State = pb.State_STATE_ESTOP
			s.Telemetry.GasAlarm = true
		}, "GÁS!", true},
	}
	for _, c := range cases {
		s := seated()
		c.edit(&s)
		a, ok := Alert(s)
		if ok != c.alert || a[0] != c.head {
			t.Errorf("%s: got %q %v", c.name, a[0], ok)
		}
		if pages := Pages(s); (pages[0] == PageAlert) != c.alert {
			t.Errorf("%s: pages %v", c.name, pages)
		}
	}
}

func TestEveryTextHasGlyphs(t *testing.T) {
	var all []string
	for _, st := range pb.State_value {
		s := seated()
		s.Telemetry.State = pb.State(st)
		all = append(all, Lines(s, PageStatus)...)
		if a, ok := Alert(s); ok {
			all = append(all, a[:]...)
		}
	}
	s := seated()
	s.Stopped = true
	all = append(all, Lines(s, PageStatus)...)
	all = append(all, Lines(seated(), PageNetwork)...)
	for _, line := range all {
		for _, r := range line {
			if _, ok := glyphs[r]; !ok {
				t.Errorf("no glyph for %q in %q", r, line)
			}
		}
	}
}

func TestHeaderIsInverted(t *testing.T) {
	f := Render(seated(), PageStatus, 0)
	if f[0][127] != 0xFF {
		t.Errorf("header band not lit at the right edge: %#x", f[0][127])
	}
	if f[1] != [Width]byte{} {
		t.Error("line 1 should be blank")
	}
}

// fakeBus records every write to the panel.
type fakeBus struct {
	mu     sync.Mutex
	writes [][]byte
	fail   bool
}

func (b *fakeBus) Write(p []byte) (int, error) {
	b.mu.Lock()
	defer b.mu.Unlock()
	if b.fail {
		return 0, errors.New("nack")
	}
	b.writes = append(b.writes, append([]byte(nil), p...))
	return len(p), nil
}
func (b *fakeBus) Close() error { return nil }

func TestPanelProtocol(t *testing.T) {
	bus := &fakeBus{}
	p := NewPanel(bus)
	if err := p.Init(); err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(bus.writes[0], []byte{0x00, 0xAE}) || !bytes.HasSuffix(bus.writes[1], []byte{0xAF}) {
		t.Fatalf("init: % x / % x", bus.writes[0], bus.writes[1])
	}
	if err := p.Show(Render(seated(), PageStatus, 0)); err != nil {
		t.Fatal(err)
	}
	data := bus.writes[3:]
	if len(data) != pages*Width/chunk {
		t.Fatalf("%d data writes, want %d", len(data), pages*Width/chunk)
	}
	sent := 0
	for _, w := range data {
		// Small writes only: this panel lost 129-byte ones and went dark.
		if w[0] != 0x40 || len(w) > chunk+1 {
			t.Fatalf("data write: len %d prefix %#x", len(w), w[0])
		}
		sent += len(w) - 1
	}
	if sent != pages*Width {
		t.Fatalf("%d pixel bytes sent, want %d", sent, pages*Width)
	}
}

func TestRunWithoutPanelKeepsGoing(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 1500*time.Millisecond)
	defer cancel()
	opens := 0
	open := func(string, int) (*Panel, error) { opens++; return nil, errors.New("no such device") }
	Run(ctx, Options{PageTime: time.Second, Retry: time.Hour}, open, seated, quiet)
	if opens != 1 {
		t.Fatalf("opened %d times; a missing panel must wait Retry", opens)
	}
}

func TestRunLeavesStoppedOnScreen(t *testing.T) {
	bus := &fakeBus{}
	open := func(string, int) (*Panel, error) { return NewPanel(bus), nil }
	ctx, cancel := context.WithTimeout(context.Background(), 1200*time.Millisecond)
	defer cancel()
	Run(ctx, Options{PageTime: time.Second, Retry: time.Hour}, open, seated, quiet)

	bus.mu.Lock()
	defer bus.mu.Unlock()
	// The last frame: its pixel writes, joined back into pages.
	writes := bus.writes[len(bus.writes)-pages*Width/chunk:]
	var got []byte
	for _, w := range writes {
		got = append(got, w[1:]...)
	}
	stopped := seated()
	stopped.Stopped = true
	for shift := 0; shift < 3; shift++ {
		want := Render(stopped, PageStatus, shift)
		var flat []byte
		for p := range want {
			flat = append(flat, want[p][:]...)
		}
		if bytes.Equal(got, flat) {
			return
		}
	}
	t.Fatal("last frame is not the 'hexd parado' screen")
}

func TestParseSSID(t *testing.T) {
	out := "Connected to aa:bb:cc:dd:ee:ff (on wlan0)\n\tSSID: Casa do Wallace\n\tfreq: 2437\n"
	if got := parseSSID(out); got != "Casa do Wallace" {
		t.Fatalf("got %q", got)
	}
	if got := parseSSID("Not connected.\n"); got != "" {
		t.Fatalf("got %q", got)
	}
}

// With DISPLAY_PNG=<dir>, writes every screen as a 4x PNG for design review:
//
//	DISPLAY_PNG=/tmp/oled go test ./hexd/internal/display -run Preview
func TestPreview(t *testing.T) {
	dir := os.Getenv("DISPLAY_PNG")
	if dir == "" {
		t.Skip("set DISPLAY_PNG to write previews")
	}
	estop := seated()
	estop.Telemetry.State = pb.State_STATE_ESTOP
	bench := seated()
	bench.Telemetry.FaultFlags = uint32(pb.Fault_FAULT_POWER_MONITOR)
	bench.Network = "Cabo de rede"
	bench.Tailscale = ""
	stopped := seated()
	stopped.Stopped = true
	for name, f := range map[string]*Frame{
		"status":  Render(seated(), PageStatus, 0),
		"network": Render(seated(), PageNetwork, 0),
		"bench":   Render(bench, PageStatus, 0),
		"alert":   Render(estop, PageAlert, 0),
		"stopped": Render(stopped, PageStatus, 0),
		"boot":    RenderBoot(Boot{Elapsed: 7 * time.Second, ESP32: true}),
		"pairing": Render(paired(), PagePairing, 0),
		"poweroff": func() *Frame {
			s := stopped
			s.Shutdown = "poweroff"
			return Render(s, PageStatus, 0)
		}(),
	} {
		const scale = 4
		img := image.NewRGBA(image.Rect(0, 0, Width*scale, Height*scale))
		for y := 0; y < Height; y++ {
			for x := 0; x < Width; x++ {
				c := color.RGBA{10, 10, 20, 255}
				if f[y/8][x]>>(y%8)&1 == 1 {
					c = color.RGBA{120, 200, 255, 255}
				}
				for dy := 0; dy < scale; dy++ {
					for dx := 0; dx < scale; dx++ {
						img.Set(x*scale+dx, y*scale+dy, c)
					}
				}
			}
		}
		out, err := os.Create(filepath.Join(dir, name+".png"))
		if err != nil {
			t.Fatal(err)
		}
		_ = png.Encode(out, img)
		out.Close()
	}
}

func TestBootChecklist(t *testing.T) {
	waiting := strings.Join(BootLines(Boot{Elapsed: 4 * time.Second}), "|")
	for _, want := range []string{"INICIANDO", "Sistema", "ok", "Rede", "aguarda", "4 s"} {
		if !strings.Contains(waiting, want) {
			t.Errorf("waiting checklist lacks %q: %s", want, waiting)
		}
	}
	up := BootLines(Boot{Elapsed: 9 * time.Second, IP: "10.0.0.86", ESP32: true})
	if !strings.HasSuffix(up[3], "10.0.0.86") || !strings.HasSuffix(up[4], "ok") {
		t.Errorf("network/ESP32 rows: %q %q", up[3], up[4])
	}
	for _, line := range up {
		if n := len([]rune(line)); n > lineChars {
			t.Errorf("%q is %d chars", line, n)
		}
	}
}

func TestRunBootEndsWhenTheNetworkIsUp(t *testing.T) {
	bus := &fakeBus{}
	calls := 0
	probe := func() Boot {
		calls++
		if calls < 3 {
			return Boot{}
		}
		return Boot{IP: "10.0.0.86"}
	}
	done := make(chan struct{})
	go func() {
		RunBoot(context.Background(), Options{}, func(string, int) (*Panel, error) { return NewPanel(bus), nil },
			probe, time.Minute, quiet)
		close(done)
	}()
	select {
	case <-done:
	case <-time.After(5 * time.Second):
		t.Fatal("boot screen did not hand over once the network was up")
	}
	if calls != 3 {
		t.Fatalf("probed %d times", calls)
	}
}

func TestRunBootWithoutPanelReturns(t *testing.T) {
	start := time.Now()
	RunBoot(context.Background(), Options{}, func(string, int) (*Panel, error) { return nil, errors.New("absent") },
		func() Boot { return Boot{} }, time.Minute, quiet)
	if time.Since(start) > 7*time.Second {
		t.Fatal("a missing panel must not hold the boot")
	}
}

func TestShutdownMessages(t *testing.T) {
	s := seated()
	s.Stopped, s.Shutdown = true, "poweroff"
	if got := strings.Join(Lines(s, PageStatus), " "); !strings.Contains(got, "LED verde") {
		t.Errorf("poweroff: %s", got)
	}
	s.Shutdown = "reboot"
	if got := Lines(s, PageStatus)[0]; !strings.Contains(got, "REINICIANDO") {
		t.Errorf("reboot: %s", got)
	}
}

func TestWakeNeverBlanks(t *testing.T) {
	bus := &fakeBus{}
	if err := NewPanel(bus).Wake(); err != nil {
		t.Fatal(err)
	}
	w := bus.writes[0]
	if bytes.IndexByte(w[1:], 0xAE) >= 0 || !bytes.HasSuffix(w, []byte{0xAF}) {
		t.Fatalf("wake must turn on, never off: % x", w)
	}
	if !bytes.Contains(w, []byte{0x20, 0x00}) || !bytes.Contains(w, []byte{0x8D, 0x14}) {
		t.Fatalf("wake must restore addressing and the charge pump: % x", w)
	}
}

func paired() Status {
	s := seated()
	s.Apps = 0
	s.Pairing, s.RobotID = "HXP1 7F3A ABCDEFGHJKLMNPQRSTUV", "7F3A"
	return s
}

func TestPairingPageOnlyWithoutApps(t *testing.T) {
	s := paired()
	if !slices.Contains(Pages(s), PagePairing) {
		t.Fatalf("no app connected: pairing page missing from %v", Pages(s))
	}
	s.Apps = 1
	if slices.Contains(Pages(s), PagePairing) {
		t.Fatal("the key must not be on display while an app is connected")
	}
	s.Apps, s.Pairing = 0, ""
	if slices.Contains(Pages(s), PagePairing) {
		t.Fatal("pairing off: no QR page")
	}
}

func TestQRFitsWithQuietZone(t *testing.T) {
	var f Frame
	w := f.QR(paired().Pairing)
	if w == 0 || w > Height {
		t.Fatalf("QR width %d", w)
	}
	lit := func(x, y int) bool { return f[y/8][x]>>(y%8)&1 == 1 }
	if !lit(0, (Height-w)/2) || !lit(w-1, Height/2) {
		t.Fatal("quiet zone must be lit")
	}
	// Somewhere inside there must be dark modules (the finder patterns).
	dark := 0
	for y := 0; y < Height; y++ {
		for x := 0; x < w; x++ {
			if !lit(x, y) {
				dark++
			}
		}
	}
	if dark < w*w/5 {
		t.Fatalf("only %d dark pixels: no QR drawn", dark)
	}
}
