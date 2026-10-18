// hexd bridges the app (WebSocket) and the ESP32 (USB serial) on the Pi.
//
//	hexd -config /opt/hexapod/shared/config/hexd.yaml
//	hexd -serial tcp://127.0.0.1:7777 -listen :8080     # against hexsim
//	hexd -boot-screen   # boot checklist on the OLED until the network is up
package main

import (
	"context"
	"errors"
	"flag"
	"log/slog"
	"net/http"
	"os"
	"os/exec"
	"os/signal"
	"strings"
	"syscall"
	"time"

	"github.com/wallacemartinss/hexapod/pi/hexd/internal/config"
	"github.com/wallacemartinss/hexapod/pi/hexd/internal/device"
	"github.com/wallacemartinss/hexapod/pi/hexd/internal/display"
	"github.com/wallacemartinss/hexapod/pi/hexd/internal/server"
	"github.com/wallacemartinss/hexapod/pi/hexd/internal/shutdown"
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

	srv := server.New(server.Config{
		DeadmanWifi:        cfg.Deadman.Wifi,
		DeadmanCellular:    cfg.Deadman.Cellular,
		CellularInterfaces: cfg.Deadman.CellularInterfaces,
		HealthMaxAge:       cfg.HealthMaxAge,
		HexdVersion:        version,
		HexdGitHash:        gitHash,
		PiTemperaturePath:  cfg.Metrics.PiTemperaturePath,
		WirelessPath:       cfg.Metrics.WirelessPath,
		WifiInterface:      cfg.Metrics.WifiInterface,
	}, dev, log.With("component", "server"))
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
			runDisplay(ctx, cfg, dev, srv, log.With("component", "display"))
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
func runDisplay(ctx context.Context, cfg config.Config, dev *device.Device, srv *server.Server, log *slog.Logger) {
	var label, ip, ts string
	var netAt time.Time
	status := func() display.Status {
		if now := time.Now(); now.Sub(netAt) > 10*time.Second {
			label, ip, ts = display.Network(cfg.Metrics.WifiInterface, cfg.Display.Wired, cfg.Display.Tailnet)
			netAt = now
		}
		snap := dev.Snapshot()
		if ctx.Err() != nil { // stopping: say why, if the whole Pi is going down
			return display.Status{Stopped: true, Shutdown: systemShutdown(), Version: version}
		}
		return display.Status{
			ESP32:     snap.Connected && time.Since(snap.LastRx) < cfg.HealthMaxAge,
			Telemetry: snap.Telemetry,
			Apps:      srv.Clients(),
			Network:   label,
			IP:        ip,
			Tailscale: ts,
			Version:   version,
		}
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
