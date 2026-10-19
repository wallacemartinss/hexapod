package server

import (
	"context"
	"net/http"
	"time"

	"github.com/wallacemartinss/hexapod/pi/hexd/internal/tailscale"
)

// Tailscale is what the setup API needs to put the robot on the owner's
// tailnet (remote access).
type Tailscale interface {
	Status(ctx context.Context) (tailscale.Status, error)
	Login(ctx context.Context) (tailscale.Status, error)
	Logout(ctx context.Context) error
}

func (s *Server) tailscaleOr404(w http.ResponseWriter, r *http.Request) (Tailscale, bool) {
	if !s.authorized(w, r) {
		return nil, false
	}
	if s.cfg.Tailscale == nil {
		writeJSON(w, http.StatusNotFound, map[string]string{"error": "remote access off (tailscale.enabled: false)"})
		return nil, false
	}
	return s.cfg.Tailscale, true
}

func (s *Server) handleTailscaleStatus(w http.ResponseWriter, r *http.Request) {
	ts, ok := s.tailscaleOr404(w, r)
	if !ok {
		return
	}
	ctx, cancel := context.WithTimeout(r.Context(), 5*time.Second)
	defer cancel()
	st, err := ts.Status(ctx)
	if err != nil {
		writeJSON(w, http.StatusServiceUnavailable, map[string]string{"error": "tailscale is not answering"})
		return
	}
	writeJSON(w, http.StatusOK, st)
}

// handleTailscaleLogin answers with the login link (state needs_login) for
// the app to open, or with the running status if already logged in.
func (s *Server) handleTailscaleLogin(w http.ResponseWriter, r *http.Request) {
	ts, ok := s.tailscaleOr404(w, r)
	if !ok {
		return
	}
	ctx, cancel := context.WithTimeout(r.Context(), 20*time.Second)
	defer cancel()
	st, err := ts.Login(ctx)
	if err != nil {
		s.log.Warn("tailscale login", "err", err)
		writeJSON(w, http.StatusServiceUnavailable, map[string]string{"error": "tailscale gave no login link"})
		return
	}
	writeJSON(w, http.StatusOK, st)
}

func (s *Server) handleTailscaleLogout(w http.ResponseWriter, r *http.Request) {
	ts, ok := s.tailscaleOr404(w, r)
	if !ok {
		return
	}
	ctx, cancel := context.WithTimeout(r.Context(), 10*time.Second)
	defer cancel()
	if err := ts.Logout(ctx); err != nil {
		writeJSON(w, http.StatusServiceUnavailable, map[string]string{"error": "tailscale did not log out"})
		return
	}
	writeJSON(w, http.StatusOK, map[string]string{"state": "needs_login"})
}
