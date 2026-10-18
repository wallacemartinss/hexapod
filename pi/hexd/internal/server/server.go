// Package server exposes hexd to the app and to monitoring:
//
//	/ws       binary WebSocket, one hexapod.v1.Envelope per message
//	/health   200 only if the ESP32 talked in the last 2 s
//	/version  JSON with hexd and firmware versions
//	/status   JSON with the robot state (deploy.sh checks it is seated)
//	/metrics  Prometheus text format
//
// It also runs the dead man's switch: when the app goes quiet, hexd sends one
// zero-velocity Command and stops forwarding; the ESP32 failsafe does the rest.
package server

import (
	"context"
	"encoding/json"
	"errors"
	"log/slog"
	"net"
	"net/http"
	"strings"
	"sync"
	"time"

	"github.com/coder/websocket"
	pb "github.com/wallacemartinss/hexapod/pi/hexd/gen/hexapod/v1"
	"github.com/wallacemartinss/hexapod/pi/hexd/internal/device"
	"google.golang.org/protobuf/proto"
)

// Config holds the server settings (from hexd.yaml).
type Config struct {
	DeadmanWifi     time.Duration // app silence before the zero command
	DeadmanCellular time.Duration
	// Interface name prefixes that mean "4G" (e.g. wwan, ppp, usb).
	CellularInterfaces []string
	HealthMaxAge       time.Duration
	HexdVersion        string
	HexdGitHash        string
	// Optional sources for /metrics; empty paths are skipped.
	PiTemperaturePath string // /sys/class/thermal/thermal_zone0/temp
	WirelessPath      string // /proc/net/wireless
	WifiInterface     string // wlan0
}

// Server is created once and serves until its context ends.
type Server struct {
	cfg Config
	dev *device.Device
	log *slog.Logger

	mu           sync.Mutex
	lastAppCmd   time.Time
	deadmanFired bool
	deadmanTrips uint64
	profile      pb.LinkProfile
	clients      int
	commands     uint64
	rejected     uint64
}

// New wires a server to a device.
func New(cfg Config, dev *device.Device, log *slog.Logger) *Server {
	if cfg.DeadmanWifi == 0 {
		cfg.DeadmanWifi = 150 * time.Millisecond
	}
	if cfg.DeadmanCellular == 0 {
		cfg.DeadmanCellular = 400 * time.Millisecond
	}
	if cfg.HealthMaxAge == 0 {
		cfg.HealthMaxAge = 2 * time.Second
	}
	return &Server{cfg: cfg, dev: dev, log: log, profile: pb.LinkProfile_LINK_PROFILE_WIFI}
}

// Handler returns the HTTP routes.
func (s *Server) Handler() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /ws", s.handleWS)
	mux.HandleFunc("GET /health", s.handleHealth)
	mux.HandleFunc("GET /version", s.handleVersion)
	mux.HandleFunc("GET /status", s.handleStatus)
	mux.HandleFunc("GET /metrics", s.handleMetrics)
	return mux
}

// Run drives the dead man's switch and keeps the ESP32 told about the link
// profile, until ctx ends.
func (s *Server) Run(ctx context.Context) {
	tick := time.NewTicker(10 * time.Millisecond)
	defer tick.Stop()
	lastProfileSent := time.Time{}
	for {
		select {
		case <-ctx.Done():
			return
		case now := <-tick.C:
			s.checkDeadman(now)
			if now.Sub(lastProfileSent) > 2*time.Second {
				s.mu.Lock()
				p := s.profile
				s.mu.Unlock()
				// Idempotent; the ESP32 only applies it while seated.
				if s.dev.SendLinkConfig(p) == nil {
					lastProfileSent = now
				}
			}
		}
	}
}

func (s *Server) checkDeadman(now time.Time) {
	s.mu.Lock()
	limit := s.cfg.DeadmanWifi
	if s.profile == pb.LinkProfile_LINK_PROFILE_CELLULAR {
		limit = s.cfg.DeadmanCellular
	}
	fire := !s.lastAppCmd.IsZero() && !s.deadmanFired && now.Sub(s.lastAppCmd) > limit
	if fire {
		s.deadmanFired = true
		s.deadmanTrips++
	}
	s.mu.Unlock()
	if !fire {
		return
	}
	// One zero-velocity command, then silence: the ESP32 failsafe takes over.
	if err := s.dev.SendCommand(&pb.Command{}); err != nil {
		s.log.Warn("deadman command not sent", "err", err)
	}
	s.log.Warn("app silent: sent zero-velocity command", "limit", limit)
}

// forward stamps and relays an app command.
func (s *Server) forward(cmd *pb.Command, profile pb.LinkProfile) error {
	s.mu.Lock()
	s.lastAppCmd = time.Now()
	s.deadmanFired = false
	if profile != s.profile {
		s.log.Info("link profile changed", "profile", profile)
		s.profile = profile
	}
	s.mu.Unlock()
	err := s.dev.SendCommand(cmd)
	s.mu.Lock()
	if err != nil {
		s.rejected++
	} else {
		s.commands++
	}
	s.mu.Unlock()
	return err
}

func (s *Server) handleWS(w http.ResponseWriter, r *http.Request) {
	// Default options reject cross-origin browsers: a web page opened on the
	// LAN must not be able to drive the robot. The app sends no Origin header.
	conn, err := websocket.Accept(w, r, nil)
	if err != nil {
		return
	}
	defer conn.CloseNow()
	conn.SetReadLimit(4096)
	profile := s.ProfileFor(localAddr(r))

	s.mu.Lock()
	s.clients++
	s.mu.Unlock()
	defer func() { s.mu.Lock(); s.clients--; s.mu.Unlock() }()
	s.log.Info("app connected", "remote", r.RemoteAddr, "profile", profile)

	ctx, cancel := context.WithCancel(r.Context())
	defer cancel()
	tel, unsubscribe := s.dev.Subscribe()
	defer unsubscribe()

	write := func(env *pb.Envelope) error {
		b, err := proto.Marshal(env)
		if err != nil {
			return err
		}
		wctx, wcancel := context.WithTimeout(ctx, time.Second)
		defer wcancel()
		return conn.Write(wctx, websocket.MessageBinary, b)
	}
	if h := s.dev.Snapshot().Hello; h != nil {
		_ = write(&pb.Envelope{Payload: &pb.Envelope_Hello{Hello: h}})
	}
	go func() {
		defer cancel()
		for {
			select {
			case <-ctx.Done():
				return
			case t := <-tel:
				if write(&pb.Envelope{Payload: &pb.Envelope_Telemetry{Telemetry: t}}) != nil {
					return
				}
			}
		}
	}()

	for {
		typ, b, err := conn.Read(ctx)
		if err != nil {
			s.log.Info("app disconnected", "remote", r.RemoteAddr, "err", err)
			return
		}
		if typ != websocket.MessageBinary {
			continue
		}
		var env pb.Envelope
		if proto.Unmarshal(b, &env) != nil {
			continue
		}
		if cmd := env.GetCommand(); cmd != nil {
			if err := s.forward(cmd, profile); err != nil && !errors.Is(err, device.ErrNotReady) {
				s.log.Warn("command not forwarded", "err", err)
			}
		}
	}
}

func localAddr(r *http.Request) net.Addr {
	if a, ok := r.Context().Value(http.LocalAddrContextKey).(net.Addr); ok {
		return a
	}
	return nil
}

// ProfileFor picks the failsafe profile from the interface that carries the
// app connection: cellular prefixes (wwan, ppp, ...) mean 4G, anything else Wi-Fi.
func (s *Server) ProfileFor(local net.Addr) pb.LinkProfile {
	name := interfaceOf(local)
	for _, prefix := range s.cfg.CellularInterfaces {
		if prefix != "" && strings.HasPrefix(name, prefix) {
			return pb.LinkProfile_LINK_PROFILE_CELLULAR
		}
	}
	return pb.LinkProfile_LINK_PROFILE_WIFI
}

func interfaceOf(a net.Addr) string {
	tcp, ok := a.(*net.TCPAddr)
	if !ok {
		return ""
	}
	ifaces, _ := net.Interfaces()
	for _, ifc := range ifaces {
		addrs, _ := ifc.Addrs()
		for _, addr := range addrs {
			if n, ok := addr.(*net.IPNet); ok && n.IP.Equal(tcp.IP) {
				return ifc.Name
			}
		}
	}
	return ""
}

func (s *Server) handleHealth(w http.ResponseWriter, _ *http.Request) {
	snap := s.dev.Snapshot()
	switch {
	case !snap.Connected:
		http.Error(w, "esp32 not connected", http.StatusServiceUnavailable)
	case time.Since(snap.LastRx) > s.cfg.HealthMaxAge:
		http.Error(w, "esp32 silent", http.StatusServiceUnavailable)
	default:
		_, _ = w.Write([]byte("ok\n"))
	}
}

func (s *Server) handleVersion(w http.ResponseWriter, _ *http.Request) {
	v := map[string]any{
		"hexd_version":     s.cfg.HexdVersion,
		"hexd_git":         s.cfg.HexdGitHash,
		"protocol_version": device.ProtocolVersion,
	}
	if h := s.dev.Snapshot().Hello; h != nil {
		v["firmware_version"] = h.FirmwareVersion
		v["firmware_git"] = h.GitHash
		v["firmware_protocol_version"] = h.ProtocolVersion
	}
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(v)
}

// handleStatus reports what deploy.sh needs to decide whether updating is
// safe. "state" is empty until the first Telemetry.
func (s *Server) handleStatus(w http.ResponseWriter, _ *http.Request) {
	snap := s.dev.Snapshot()
	v := map[string]any{"connected": snap.Connected, "state": ""}
	if t := snap.Telemetry; t != nil {
		v["state"] = strings.TrimPrefix(t.State.String(), "STATE_")
		v["mode"] = strings.TrimPrefix(t.Mode.String(), "MODE_")
		v["fault_flags"] = t.FaultFlags
		v["last_command_seq"] = t.LastCommandSeq
	}
	if !snap.LastRx.IsZero() {
		v["last_rx_age_ms"] = time.Since(snap.LastRx).Milliseconds()
	}
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(v)
}
