package server

import (
	"context"
	"encoding/json"
	"net/http"
	"strings"
	"time"
	"unicode/utf8"

	"github.com/wallacemartinss/hexapod/pi/hexd/internal/wifi"
)

// WiFi is what the setup API needs from the Wi-Fi manager.
type WiFi interface {
	Status() wifi.Status
	Scan(ctx context.Context) ([]wifi.Network, error)
	Join(ssid, password string) error
	SetMode(mode wifi.Mode) error
	Forget(ssid string) error
}

// authorized: the setup API, like /ws, is for paired apps only.
func (s *Server) authorized(w http.ResponseWriter, r *http.Request) bool {
	if id := s.cfg.Identity; id != nil && !id.Allowed(r) {
		http.Error(w, "pairing key required", http.StatusUnauthorized)
		return false
	}
	return true
}

func writeJSON(w http.ResponseWriter, code int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(code)
	_ = json.NewEncoder(w).Encode(v)
}

// readJSON decodes a small body; it answers 400 itself on failure.
func readJSON(w http.ResponseWriter, r *http.Request, v any) bool {
	r.Body = http.MaxBytesReader(w, r.Body, 4096)
	if err := json.NewDecoder(r.Body).Decode(v); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "pedido inválido"})
		return false
	}
	return true
}

func (s *Server) wifiOr404(w http.ResponseWriter, r *http.Request) (WiFi, bool) {
	if !s.authorized(w, r) {
		return nil, false
	}
	if s.cfg.WiFi == nil {
		writeJSON(w, http.StatusNotFound, map[string]string{"error": "Wi-Fi não gerenciado (wifi.enabled: false)"})
		return nil, false
	}
	return s.cfg.WiFi, true
}

func (s *Server) handleWiFiStatus(w http.ResponseWriter, r *http.Request) {
	if wf, ok := s.wifiOr404(w, r); ok {
		writeJSON(w, http.StatusOK, wf.Status())
	}
}

func (s *Server) handleWiFiScan(w http.ResponseWriter, r *http.Request) {
	wf, ok := s.wifiOr404(w, r)
	if !ok {
		return
	}
	ctx, cancel := context.WithTimeout(r.Context(), 20*time.Second)
	defer cancel()
	list, err := wf.Scan(ctx)
	if err != nil {
		writeJSON(w, http.StatusServiceUnavailable, map[string]string{"error": "não consegui procurar redes agora"})
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"networks": list})
}

// handleWiFiJoin answers at once: the robot then leaves its own network, so
// the app learns the outcome by finding it again (home) or reading
// Status.Error back on the robot's network (failure).
func (s *Server) handleWiFiJoin(w http.ResponseWriter, r *http.Request) {
	wf, ok := s.wifiOr404(w, r)
	if !ok {
		return
	}
	var req struct{ SSID, Password string }
	if !readJSON(w, r, &req) {
		return
	}
	if err := wf.Join(req.SSID, req.Password); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": err.Error()})
		return
	}
	writeJSON(w, http.StatusAccepted, map[string]string{"state": wifi.StateConnecting})
}

func (s *Server) handleWiFiMode(w http.ResponseWriter, r *http.Request) {
	wf, ok := s.wifiOr404(w, r)
	if !ok {
		return
	}
	var req struct{ Mode wifi.Mode }
	if !readJSON(w, r, &req) {
		return
	}
	if err := wf.SetMode(req.Mode); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": err.Error()})
		return
	}
	writeJSON(w, http.StatusAccepted, map[string]string{"mode": string(req.Mode)})
}

func (s *Server) handleWiFiForget(w http.ResponseWriter, r *http.Request) {
	wf, ok := s.wifiOr404(w, r)
	if !ok {
		return
	}
	var req struct{ SSID string }
	if !readJSON(w, r, &req) {
		return
	}
	if err := wf.Forget(req.SSID); err != nil {
		writeJSON(w, http.StatusConflict, map[string]string{"error": err.Error()})
		return
	}
	writeJSON(w, http.StatusAccepted, map[string]string{})
}

// handleName renames the robot (shown in the app and on /identity).
func (s *Server) handleName(w http.ResponseWriter, r *http.Request) {
	if !s.authorized(w, r) {
		return
	}
	var req struct{ Name string }
	if !readJSON(w, r, &req) {
		return
	}
	name := strings.TrimSpace(req.Name)
	if name == "" || utf8.RuneCountInString(name) > 32 {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "o nome tem de 1 a 32 caracteres"})
		return
	}
	if s.cfg.Rename == nil {
		writeJSON(w, http.StatusNotFound, map[string]string{"error": "robô sem pareamento"})
		return
	}
	if err := s.cfg.Rename(name); err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "não consegui salvar o nome"})
		return
	}
	s.mu.Lock()
	s.name = name
	s.mu.Unlock()
	writeJSON(w, http.StatusOK, map[string]string{"name": name})
}
