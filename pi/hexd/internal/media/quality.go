package media

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"os"
	"path/filepath"
	"time"
)

// Quality presets of the camera: what the app offers. Mode is the OV5647
// sensor mode (width:height:bits:packing): 1296x972 is the whole sensor
// binned 2x2 (the full 120 deg, and less noise in low light); its 1920x1080
// is a crop of the middle (sharper, ~25% narrower). The whole sensor at
// full resolution only does 15 fps.
var Qualities = map[string]struct {
	Width, Height, Bitrate int // px, px, bit/s
	Mode                   string
}{
	"720p":  {1280, 720, 2_500_000, "1296:972:10:P"},   // full view: good over 4G, any Pi
	"1080p": {1920, 1080, 5_000_000, "1920:1080:10:P"}, // sharper, narrower: home Wi-Fi, best on a Pi 4
}

// DefaultQuality matches pi/mediamtx/mediamtx.yml.
const DefaultQuality = "720p"

// Camera switches MediaMTX's camera between presets through its local API
// (path "cam") and remembers the choice in a file, applied again whenever
// hexd or MediaMTX restarts.
type Camera struct {
	API      string // http://127.0.0.1:9997
	Path     string // cam
	Settings string // /opt/hexapod/shared/config/camera.json
	Client   *http.Client
}

// Quality is the saved preset.
func (c *Camera) Quality() string {
	b, err := os.ReadFile(c.Settings)
	if err != nil {
		return DefaultQuality
	}
	var s struct{ Quality string }
	if json.Unmarshal(b, &s) != nil {
		return DefaultQuality
	}
	if _, ok := Qualities[s.Quality]; !ok {
		return DefaultQuality
	}
	return s.Quality
}

// SetQuality applies a preset now and saves it.
func (c *Camera) SetQuality(ctx context.Context, q string) error {
	if _, ok := Qualities[q]; !ok {
		return fmt.Errorf("unknown quality %q", q)
	}
	if err := c.apply(ctx, q); err != nil {
		return err
	}
	b, _ := json.Marshal(map[string]string{"quality": q})
	tmp := c.Settings + ".tmp"
	if err := os.MkdirAll(filepath.Dir(c.Settings), 0o755); err != nil {
		return err
	}
	if err := os.WriteFile(tmp, b, 0o644); err != nil {
		return err
	}
	return os.Rename(tmp, c.Settings)
}

func (c *Camera) apply(ctx context.Context, q string) error {
	p := Qualities[q]
	body, _ := json.Marshal(map[string]any{
		"rpiCameraWidth": p.Width, "rpiCameraHeight": p.Height, "rpiCameraBitrate": p.Bitrate,
		"rpiCameraMode": p.Mode,
	})
	req, err := http.NewRequestWithContext(ctx, http.MethodPatch,
		c.API+"/v3/config/paths/patch/"+c.Path, bytes.NewReader(body))
	if err != nil {
		return err
	}
	req.Header.Set("Content-Type", "application/json")
	client := c.Client
	if client == nil {
		client = &http.Client{Timeout: 5 * time.Second}
	}
	resp, err := client.Do(req)
	if err != nil {
		return fmt.Errorf("%w: %v", ErrCamera, err)
	}
	resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("%w: MediaMTX answered %s", ErrCamera, resp.Status)
	}
	return nil
}

// Keep holds MediaMTX on the saved preset until ctx ends: MediaMTX starts
// from its file (720p) and forgets API changes when it restarts, so the
// preset is checked every interval and applied again when it differs.
func (c *Camera) Keep(ctx context.Context, every time.Duration) {
	for {
		q := c.Quality()
		if w, err := c.width(ctx); err == nil && w != Qualities[q].Width {
			_ = c.apply(ctx, q)
		}
		select {
		case <-ctx.Done():
			return
		case <-time.After(every):
		}
	}
}

// width: the camera width MediaMTX runs with now.
func (c *Camera) width(ctx context.Context) (int, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, c.API+"/v3/config/paths/get/"+c.Path, nil)
	if err != nil {
		return 0, err
	}
	client := c.Client
	if client == nil {
		client = &http.Client{Timeout: 5 * time.Second}
	}
	resp, err := client.Do(req)
	if err != nil {
		return 0, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return 0, fmt.Errorf("MediaMTX answered %s", resp.Status)
	}
	var conf struct{ RpiCameraWidth int }
	if err := json.NewDecoder(resp.Body).Decode(&conf); err != nil {
		return 0, err
	}
	return conf.RpiCameraWidth, nil
}
