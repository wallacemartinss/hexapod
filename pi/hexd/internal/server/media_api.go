package server

import (
	"context"
	"errors"
	"net/http"
	"os"
	"time"

	"github.com/wallacemartinss/hexapod/pi/hexd/internal/media"
)

// Media is what the gallery API needs: photos and recordings on the SD
// card, served to the app (which saves them to the phone's gallery).
type Media interface {
	Status() (media.Status, error)
	Photo(ctx context.Context) (media.Item, error)
	StartRecording() error
	StopRecording() (media.Item, error)
	Path(name string, thumb bool) (string, error)
	Delete(name string) error
}

// CameraQuality switches the camera between presets (720p, 1080p).
type CameraQuality interface {
	Quality() string
	SetQuality(ctx context.Context, q string) error
}

func (s *Server) mediaOr404(w http.ResponseWriter, r *http.Request) (Media, bool) {
	if !s.authorized(w, r) {
		return nil, false
	}
	if s.cfg.Media == nil {
		writeJSON(w, http.StatusNotFound, map[string]string{"error": "camera off (media.enabled: false)"})
		return nil, false
	}
	return s.cfg.Media, true
}

// mediaError answers with a status the app can tell apart.
func mediaError(w http.ResponseWriter, err error) {
	code := http.StatusInternalServerError
	switch {
	case errors.Is(err, media.ErrNotFound):
		code = http.StatusNotFound
	case errors.Is(err, media.ErrRecording):
		code = http.StatusConflict
	case errors.Is(err, media.ErrNoSpace):
		code = http.StatusInsufficientStorage
	case errors.Is(err, media.ErrCamera):
		code = http.StatusServiceUnavailable
	}
	writeJSON(w, code, map[string]string{"error": err.Error()})
}

func (s *Server) handleMedia(w http.ResponseWriter, r *http.Request) {
	m, ok := s.mediaOr404(w, r)
	if !ok {
		return
	}
	st, err := m.Status()
	if err != nil {
		mediaError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, st)
}

func (s *Server) handlePhoto(w http.ResponseWriter, r *http.Request) {
	m, ok := s.mediaOr404(w, r)
	if !ok {
		return
	}
	ctx, cancel := context.WithTimeout(r.Context(), 20*time.Second)
	defer cancel()
	it, err := m.Photo(ctx)
	if err != nil {
		s.log.Warn("photo", "err", err)
		mediaError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, it)
}

// handleRecord starts ({"on": true}) or stops ({"on": false}) recording.
func (s *Server) handleRecord(w http.ResponseWriter, r *http.Request) {
	m, ok := s.mediaOr404(w, r)
	if !ok {
		return
	}
	var req struct {
		On bool `json:"on"`
	}
	if !readJSON(w, r, &req) {
		return
	}
	if req.On {
		if err := m.StartRecording(); err != nil {
			mediaError(w, err)
			return
		}
		writeJSON(w, http.StatusOK, map[string]bool{"recording": true})
		return
	}
	it, err := m.StopRecording()
	if err != nil {
		mediaError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"recording": false, "item": it})
}

// handleMediaFile serves a photo or video (?thumb=1: its thumbnail), with
// ranges, so big videos can resume.
func (s *Server) handleMediaFile(w http.ResponseWriter, r *http.Request) {
	m, ok := s.mediaOr404(w, r)
	if !ok {
		return
	}
	name := r.PathValue("name")
	path, err := m.Path(name, r.URL.Query().Get("thumb") == "1")
	if err != nil {
		mediaError(w, err)
		return
	}
	f, err := os.Open(path)
	if err != nil {
		mediaError(w, media.ErrNotFound)
		return
	}
	defer f.Close()
	info, err := f.Stat()
	if err != nil {
		mediaError(w, err)
		return
	}
	w.Header().Set("Content-Disposition", `attachment; filename="`+name+`"`)
	http.ServeContent(w, r, name, info.ModTime(), f)
}

func (s *Server) handleMediaDelete(w http.ResponseWriter, r *http.Request) {
	m, ok := s.mediaOr404(w, r)
	if !ok {
		return
	}
	if err := m.Delete(r.PathValue("name")); err != nil {
		mediaError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]string{"deleted": r.PathValue("name")})
}

func (s *Server) handleCamera(w http.ResponseWriter, r *http.Request) {
	if !s.authorized(w, r) {
		return
	}
	if s.cfg.Camera == nil {
		writeJSON(w, http.StatusNotFound, map[string]string{"error": "camera off (media.enabled: false)"})
		return
	}
	if r.Method == http.MethodPost {
		var req struct {
			Quality string `json:"quality"`
		}
		if !readJSON(w, r, &req) {
			return
		}
		ctx, cancel := context.WithTimeout(r.Context(), 10*time.Second)
		defer cancel()
		if _, ok := media.Qualities[req.Quality]; !ok {
			writeJSON(w, http.StatusBadRequest, map[string]string{"error": "unknown quality"})
			return
		}
		if err := s.cfg.Camera.SetQuality(ctx, req.Quality); err != nil {
			mediaError(w, err)
			return
		}
	}
	writeJSON(w, http.StatusOK, map[string]any{"quality": s.cfg.Camera.Quality(), "options": []string{"720p", "1080p"}})
}
