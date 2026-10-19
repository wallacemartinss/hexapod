package media

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"testing"
	"time"
)

// fakeFFmpeg behaves like ffmpeg for these commands: it writes every .jpg
// and .part output, and a recording (a .part output) runs until it reads
// "q" on stdin. With HEXAPOD_FAKE_CAMERA=off it fails like a missing camera.
const fakeFFmpeg = `#!/bin/sh
if [ "$HEXAPOD_FAKE_CAMERA" = off ]; then echo "rtsp://127.0.0.1:8554/cam: 404 Not Found" >&2; exit 1; fi
rec=0
for a in "$@"; do case "$a" in *.part) rec=1;; esac; done
for a in "$@"; do case "$a" in *.jpg|*.part) echo frame > "$a";; esac; done
if [ $rec = 1 ]; then head -c1 >/dev/null; fi
exit 0
`

func gallery(t *testing.T, now time.Time) (*Gallery, string) {
	t.Helper()
	dir := t.TempDir()
	bin := filepath.Join(t.TempDir(), "ffmpeg")
	if err := os.WriteFile(bin, []byte(fakeFFmpeg), 0o755); err != nil {
		t.Fatal(err)
	}
	clock := now
	g, err := New(Options{
		Dir: dir, Source: "rtsp://127.0.0.1:8554/cam", FFmpeg: bin, MaxRecord: time.Hour,
		Now: func() time.Time { return clock },
	})
	if err != nil {
		t.Fatal(err)
	}
	return g, dir
}

func TestPhoto(t *testing.T) {
	g, dir := gallery(t, time.Date(2026, 10, 19, 9, 15, 0, 0, time.Local))
	it, err := g.Photo(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if it.Name != "photo-20261019-091500.jpg" || it.Kind != "photo" || it.Size == 0 {
		t.Errorf("photo: %+v", it)
	}
	if _, err := os.Stat(filepath.Join(dir, ".thumbs", "photo-20261019-091500.jpg")); err != nil {
		t.Error("no thumbnail")
	}
	// A second one in the same second gets its own name.
	it2, _ := g.Photo(context.Background())
	if it2.Name != "photo-20261019-091500-2.jpg" {
		t.Errorf("second photo: %s", it2.Name)
	}
}

func TestRecording(t *testing.T) {
	g, _ := gallery(t, time.Date(2026, 10, 19, 9, 20, 0, 0, time.Local))
	if err := g.StartRecording(); err != nil {
		t.Fatal(err)
	}
	if err := g.StartRecording(); !errors.Is(err, ErrRecording) {
		t.Errorf("second start: %v", err)
	}
	if on, _ := g.Recording(); !on {
		t.Error("not recording")
	}
	st, _ := g.Status()
	if !st.Recording || len(st.Items) != 0 {
		t.Errorf("while recording: %+v (the .part must not be listed)", st)
	}
	it, err := g.StopRecording()
	if err != nil || it.Name != "video-20261019-092000.mp4" || it.Kind != "video" {
		t.Fatalf("stop: %+v %v", it, err)
	}
	if on, _ := g.Recording(); on {
		t.Error("still recording")
	}
	if p, err := g.Path(it.Name, true); err != nil || p == "" {
		t.Errorf("video thumbnail: %v", err)
	}
}

func TestStatusDeleteAndNames(t *testing.T) {
	g, dir := gallery(t, time.Date(2026, 10, 19, 9, 0, 0, 0, time.Local))
	_, _ = g.Photo(context.Background())
	_ = g.StartRecording()
	_, _ = g.StopRecording()
	_ = os.WriteFile(filepath.Join(dir, "notes.txt"), []byte("x"), 0o644) // not media

	st, err := g.Status()
	if err != nil || len(st.Items) != 2 {
		t.Fatalf("status: %+v %v", st, err)
	}
	for _, bad := range []string{"../identity.json", ".thumbs/x.jpg", "notes.txt", "photo-1.jpg"} {
		if _, err := g.Path(bad, false); !errors.Is(err, ErrNotFound) {
			t.Errorf("path %q: %v", bad, err)
		}
		if err := g.Delete(bad); !errors.Is(err, ErrNotFound) {
			t.Errorf("delete %q: %v", bad, err)
		}
	}
	if err := g.Delete("photo-20261019-090000.jpg"); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(filepath.Join(dir, ".thumbs", "photo-20261019-090000.jpg")); err == nil {
		t.Error("thumbnail left behind")
	}
	if st, _ := g.Status(); len(st.Items) != 1 {
		t.Errorf("after delete: %+v", st.Items)
	}
}

func TestNoCamera(t *testing.T) {
	t.Setenv("HEXAPOD_FAKE_CAMERA", "off")
	g, dir := gallery(t, time.Now())
	if _, err := g.Photo(context.Background()); !errors.Is(err, ErrCamera) {
		t.Errorf("photo without camera: %v", err)
	}
	if entries, _ := os.ReadDir(dir); len(entries) != 1 { // only .thumbs
		t.Errorf("left files: %v", entries)
	}
	// A recording that dies at once leaves nothing and frees the recorder.
	if err := g.StartRecording(); err != nil {
		t.Fatal(err)
	}
	deadline := time.Now().Add(3 * time.Second)
	for on, _ := g.Recording(); on && time.Now().Before(deadline); on, _ = g.Recording() {
		time.Sleep(10 * time.Millisecond)
	}
	if on, _ := g.Recording(); on {
		t.Error("a failed recording keeps the recorder busy")
	}
}

func TestNoSpace(t *testing.T) {
	g, _ := gallery(t, time.Now())
	g.opt.MinFreeMB = 1 << 40 // more than any disk
	if _, err := g.Photo(context.Background()); !errors.Is(err, ErrNoSpace) {
		t.Errorf("photo: %v", err)
	}
	if err := g.StartRecording(); !errors.Is(err, ErrNoSpace) {
		t.Errorf("record: %v", err)
	}
}
