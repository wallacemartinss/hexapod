// hexd bridges the app (WebSocket) and the ESP32 (USB serial) on the Pi.
//
//	hexd -config /opt/hexapod/shared/config/hexd.yaml
//	hexd -serial tcp://127.0.0.1:7777 -listen :8080     # against hexsim
//	hexd -boot-screen   # boot checklist on the OLED until the network is up
//	hexd -pairing       # print the robot's id, key and pairing QR (as the service user)
package main

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"log/slog"
	"net/http"
	"os"
	"os/exec"
	"os/signal"
	"strings"
	"sync"
	"syscall"
	"time"

	pb "github.com/wallacemartinss/hexapod/pi/hexd/gen/hexapod/v1"
	"github.com/wallacemartinss/hexapod/pi/hexd/internal/config"
	"github.com/wallacemartinss/hexapod/pi/hexd/internal/device"
	"github.com/wallacemartinss/hexapod/pi/hexd/internal/display"
	"github.com/wallacemartinss/hexapod/pi/hexd/internal/gps"
	"github.com/wallacemartinss/hexapod/pi/hexd/internal/pairing"
	"github.com/wallacemartinss/hexapod/pi/hexd/internal/server"
	"github.com/wallacemartinss/hexapod/pi/hexd/internal/shutdown"
	"github.com/wallacemartinss/hexapod/pi/hexd/internal/sysinfo"
	"github.com/wallacemartinss/hexapod/pi/hexd/internal/tailscale"
	"github.com/wallacemartinss/hexapod/pi/hexd/internal/wifi"
)

// Set at build time: -ldflags "-X main.version=... -X main.gitHash=...".
var (
	version = "dev"
	gitHash = ""
)

func main() {
	path := flag.String("config", "/opt/hexapod/shared/config/hexd.yaml", "configuration file")
	serial := flag.String("serial", "", "override serial.device")
	listen := flag.String("listen", "", "override listen")
	bootScreen := flag.Bool("boot-screen", false, "show the boot checklist on the OLED, then exit")
	showPairing := flag.Bool("pairing", false, "print the pairing key and QR, then exit")
	flag.Parse()
	log := slog.New(slog.NewTextHandler(os.Stderr, nil))

	cfg, err := config.Load(*path)
	if err != nil {
		log.Error("config", "err", err)
		os.Exit(2)
	}
	if *serial != "" {
		cfg.Serial.Device = *serial
	}
	if *listen != "" {
		cfg.Listen = *listen
	}
	if *showPairing {
		id, err := pairing.LoadOrCreate(cfg.Auth.Identity)
		if err != nil {
			fmt.Fprintln(os.Stderr, "pairing:", err, "(run as the service user: sudo -u hexapod ...)")
			os.Exit(1)
		}
		fmt.Printf("Robô %s (%s)\nChave: %s\n\nNo app: Novo robô > escanear este QR\n%s\n", id.ID, id.Name, id.Token, pairing.TerminalQR(id.QR()))
		return
	}
	if *bootScreen {
		runBootScreen(cfg, log.With("component", "boot-screen"))
		return
	}

	log.Info("hexd starting", "version", version, "git", gitHash, "serial", cfg.Serial.Device, "listen", cfg.Listen)

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	dev := device.New(device.Options{
		Dial:         device.Dial(cfg.Serial.Device, cfg.Serial.Baud),
		HexdVersion:  version,
		SilenceLimit: cfg.Serial.SilenceLimit,
		Logger:       log.With("component", "device"),
	})
	go dev.Run(ctx)

	// Pairing: without the key from the robot's screen, no app connects.
	var identity *pairing.Identity
	if cfg.Auth.Required {
		id, err := pairing.LoadOrCreate(cfg.Auth.Identity)
		if err != nil { // fail closed: never serve without the key
			log.Error("pairing identity", "path", cfg.Auth.Identity, "err", err)
			os.Exit(1)
		}
		identity = &id
		log.Info("pairing on", "id", id.ID)
	} else {
		log.Warn("pairing off: any app on the network can drive the robot (auth.required: false)")
	}

	// GPS on the Pi's UART (or simulated); nil when disabled.
	var position func() (*pb.Position, bool)
	if cfg.GPS.Enabled {
		var reader gps.Reader
		if cfg.GPS.Simulate {
			go reader.Simulate(ctx, cfg.GPS.SimLat, cfg.GPS.SimLon)
		} else {
			go reader.Run(ctx, gps.Serial(cfg.GPS.Device, cfg.GPS.Baud), log.With("component", "gps"))
		}
		position = func() (*pb.Position, bool) { return reader.Latest(3 * time.Second) }
	}

	// The Pi's own health (CPU, memory, SD card, power), for the app and /metrics.
	pi := &sysinfo.Sampler{DataPath: "/opt/hexapod", WifiInterface: cfg.Metrics.WifiInterface}
	go pi.Run(ctx, 2*time.Second)

	// The identity's name and "paired" flag change at run time (rename,
	// first pairing): idMu guards them and every save of the file.
	var idMu sync.Mutex
	update := func(change func(*pairing.Identity) bool) error {
		idMu.Lock()
		defer idMu.Unlock()
		if !change(identity) {
			return nil
		}
		return pairing.Save(cfg.Auth.Identity, *identity)
	}
	// Short code on the screen, traded for the key by /pair.
	var codes *pairing.Codes
	if identity != nil {
		codes = &pairing.Codes{TTL: 10 * time.Minute}
	}
	// An app proved it has the key: from now on the own network needs a password.
	var onPaired func()
	if identity != nil {
		onPaired = func() {
			if err := update(func(id *pairing.Identity) bool {
				was := id.Paired
				id.Paired = true
				return !was
			}); err != nil {
				log.Warn("saving paired flag", "err", err)
			}
		}
	}

	// Wi-Fi: the robot's own network (open until the first pairing, then a
	// password from the key) and the home networks the app saves. srv is
	// set below, before Run starts.
	var srv *server.Server
	var wifiMgr *wifi.Manager
	if cfg.WiFi.Enabled && identity != nil {
		wifiMgr = wifi.New(wifi.Options{
			NM: wifi.NM{Run: wifi.Nmcli, Iface: cfg.WiFi.Interface},
			Own: func() (string, string) {
				idMu.Lock()
				defer idMu.Unlock()
				return identity.OwnNetwork()
			},
			SettingsPath:   cfg.WiFi.Settings,
			FallbackAfter:  cfg.WiFi.FallbackAfter,
			RetryHomeEvery: 2 * time.Minute,
			JoinWait:       30,
			Tick:           5 * time.Second,
			Apps:           func() int { return srv.Clients() },
			Log:            log.With("component", "wifi"),
		})
	}
	// Renaming from the app rewrites the identity file (nil without pairing).
	var rename func(name string) error
	if identity != nil {
		rename = func(name string) error {
			return update(func(id *pairing.Identity) bool { id.Name = name; return true })
		}
	}

	// Remote access: the app logs the robot in to the owner's tailnet.
	var remote server.Tailscale
	if cfg.Tailscale.Enabled && identity != nil {
		remote = &tailscale.Client{
			Run:      tailscale.CLI,
			Hostname: "hexapod-" + strings.ToLower(identity.ID),
			Prepare:  tailscale.RestoreOperator,
		}
	}

	srv = server.New(server.Config{
		DeadmanWifi:        cfg.Deadman.Wifi,
		DeadmanCellular:    cfg.Deadman.Cellular,
		CellularInterfaces: cfg.Deadman.CellularInterfaces,
		HealthMaxAge:       cfg.HealthMaxAge,
		HexdVersion:        version,
		HexdGitHash:        gitHash,
		PiTemperaturePath:  cfg.Metrics.PiTemperaturePath,
		WirelessPath:       cfg.Metrics.WirelessPath,
		WifiInterface:      cfg.Metrics.WifiInterface,
		Position:           position,
		PiStatus:           pi.Latest,
		Identity:           identity,
		WiFi:               wifiAPI(wifiMgr),
		Tailscale:          remote,
		Rename:             rename,
		Codes:              codes,
		OnPaired:           onPaired,
	}, dev, log.With("component", "server"))
	if wifiMgr != nil {
		go wifiMgr.Run(ctx)
	}
	go srv.Run(ctx)

	if cfg.Shutdown.Enabled {
		tel, unsubscribe := dev.Subscribe()
		defer unsubscribe()
		go shutdown.Watch(ctx, tel, cfg.Shutdown.Delay, cfg.Shutdown.Command, shutdown.Exec,
			log.With("component", "shutdown"))
	}

	// The screen draws "hexd parado" on the way out: main waits for it.
	displayDone := make(chan struct{})
	if cfg.Display.Enabled {
		go func() {
			defer close(displayDone)
			runDisplay(ctx, cfg, dev, srv, position, identity, codes, wifiMgr, log.With("component", "display"))
		}()
	} else {
		close(displayDone)
	}

	httpServer := &http.Server{Addr: cfg.Listen, Handler: srv.Handler(), ReadHeaderTimeout: 5 * time.Second}
	go func() {
		<-ctx.Done()
		shutdownCtx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
		defer cancel()
		_ = httpServer.Shutdown(shutdownCtx)
	}()
	if err := httpServer.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
		log.Error("http", "err", err)
		os.Exit(1)
	}
	select {
	case <-displayDone:
	case <-time.After(time.Second):
	}
	log.Info("hexd stopped")
}

// runDisplay keeps the OLED status screen up to date. The network is looked
// up every 10 s (it shells out to iw), the rest every refresh.
func runDisplay(ctx context.Context, cfg config.Config, dev *device.Device, srv *server.Server,
	position func() (*pb.Position, bool), identity *pairing.Identity, codes *pairing.Codes,
	wifiMgr *wifi.Manager, log *slog.Logger) {
	var label, ip, ts string
	var netAt time.Time
	status := func() display.Status {
		if now := time.Now(); now.Sub(netAt) > 10*time.Second {
			label, ip, ts = display.Network(cfg.Metrics.WifiInterface, cfg.Display.Wired, cfg.Display.Tailnet)
			// In its own network iw shows no SSID: say which network it is.
			if wifiMgr != nil {
				if w := wifiMgr.Status(); w.State == wifi.StateOwn {
					label, ip = "Rede própria", w.IP
				}
			}
			netAt = now
		}
		snap := dev.Snapshot()
		if ctx.Err() != nil { // stopping: say why, if the whole Pi is going down
			return display.Status{Stopped: true, Shutdown: systemShutdown(), Version: version}
		}
		st := display.Status{
			ESP32:     snap.Connected && time.Since(snap.LastRx) < cfg.HealthMaxAge,
			Telemetry: snap.Telemetry,
			Apps:      srv.Clients(),
			Network:   label,
			IP:        ip,
			Tailscale: ts,
			Version:   version,
			GPS:       gpsLine(position),
		}
		if identity != nil && codes != nil {
			code := codes.Current()
			st.Pairing, st.RobotID, st.PairCode = identity.PairingQR(code), identity.ID, code
		}
		return st
	}
	display.Run(ctx, display.Options{
		Bus:      cfg.Display.Bus,
		Address:  cfg.Display.Address,
		PageTime: cfg.Display.PageTime,
		Retry:    30 * time.Second,
	}, display.Open, status, log)
}

// runBootScreen shows the boot checklist until the network is up (at most a
// minute); hexd.service starts after it and takes the screen over.
func runBootScreen(cfg config.Config, log *slog.Logger) {
	if !cfg.Display.Enabled {
		return
	}
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	probe := func() display.Boot {
		_, ip, _ := display.Network(cfg.Metrics.WifiInterface, cfg.Display.Wired, cfg.Display.Tailnet)
		_, err := os.Stat(cfg.Serial.Device)
		return display.Boot{IP: ip, ESP32: err == nil}
	}
	display.RunBoot(ctx, display.Options{Bus: cfg.Display.Bus, Address: cfg.Display.Address},
		display.Open, probe, time.Minute, log)
}

// systemShutdown tells whether the Pi itself is powering off or rebooting
// (hexd stops first); "" when only hexd is stopping.
func systemShutdown() string {
	ctx, cancel := context.WithTimeout(context.Background(), 500*time.Millisecond)
	defer cancel()
	out, err := exec.CommandContext(ctx, "systemctl", "list-jobs", "--no-legend").Output()
	if err != nil {
		return ""
	}
	switch jobs := string(out); {
	case strings.Contains(jobs, "reboot.target"):
		return "reboot"
	case strings.Contains(jobs, "poweroff.target"), strings.Contains(jobs, "halt.target"):
		return "poweroff"
	}
	return ""
}

// gpsLine is the GPS row of the status screen ("" when there is no GPS).
func gpsLine(position func() (*pb.Position, bool)) string {
	if position == nil {
		return ""
	}
	p, ok := position()
	switch {
	case !ok:
		return "GPS: sem resposta"
	case p.Fix:
		return fmt.Sprintf("GPS: ok, %d satélites", p.SatellitesUsed)
	default:
		return fmt.Sprintf("GPS: procurando (%d)", p.SatellitesInView)
	}
}

// wifiAPI keeps a nil manager a nil interface (no Wi-Fi API).
func wifiAPI(m *wifi.Manager) server.WiFi {
	if m == nil {
		return nil
	}
	return m
}
