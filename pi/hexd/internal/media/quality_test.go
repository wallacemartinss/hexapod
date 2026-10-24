package media

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"sync"
	"testing"
	"time"
)

// fakeMediaMTX keeps the cam path's width like MediaMTX's config API.
func fakeMediaMTX(t *testing.T, width *int, mu *sync.Mutex) *httptest.Server {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		mu.Lock()
		defer mu.Unlock()
		switch {
		case r.Method == http.MethodPatch && r.URL.Path == "/v3/config/paths/patch/cam":
			var body struct{ RpiCameraWidth int }
			_ = json.NewDecoder(r.Body).Decode(&body)
			*width = body.RpiCameraWidth
		case r.Method == http.MethodGet && r.URL.Path == "/v3/config/paths/get/cam":
			_ = json.NewEncoder(w).Encode(map[string]int{"rpiCameraWidth": *width})
		default:
			http.NotFound(w, r)
		}
	}))
	t.Cleanup(srv.Close)
	return srv
}

func TestQuality(t *testing.T) {
	var mu sync.Mutex
	width := 1280
	srv := fakeMediaMTX(t, &width, &mu)
	c := &Camera{API: srv.URL, Path: "cam", Settings: filepath.Join(t.TempDir(), "camera.json")}

	if q := c.Quality(); q != "720p" {
		t.Errorf("default: %s", q)
	}
	if err := c.SetQuality(context.Background(), "4k"); err == nil {
		t.Error("unknown preset accepted")
	}
	if err := c.SetQuality(context.Background(), "1080p"); err != nil {
		t.Fatal(err)
	}
	mu.Lock()
	if width != 1920 {
		t.Errorf("MediaMTX width %d", width)
	}
	width = 1280 // MediaMTX restarted: back to its file
	mu.Unlock()
	if q := c.Quality(); q != "1080p" {
		t.Errorf("saved: %s", q)
	}

	ctx, cancel := context.WithCancel(context.Background())
	go c.Keep(ctx, 10*time.Millisecond)
	deadline := time.Now().Add(2 * time.Second)
	for {
		mu.Lock()
		w := width
		mu.Unlock()
		if w == 1920 || time.Now().After(deadline) {
			if w != 1920 {
				t.Errorf("preset not applied again: %d", w)
			}
			break
		}
		time.Sleep(5 * time.Millisecond)
	}
	cancel()
}
