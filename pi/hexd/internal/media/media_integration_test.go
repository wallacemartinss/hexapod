package media

import (
	"context"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// TestRealCamera runs ffmpeg against a real RTSP stream (no camera needed:
// MediaMTX with an ffmpeg test pattern published to it). Skipped unless
// HEXAPOD_TEST_RTSP points at the stream, e.g.:
//
//	mediamtx test.yml   # path cam, source: publisher, rtsp on :18554
//	ffmpeg -re -f lavfi -i testsrc2=size=1280x720:rate=30 -c:v libx264 -g 30 \
//	  -f rtsp rtsp://127.0.0.1:18554/cam
//	HEXAPOD_TEST_RTSP=rtsp://127.0.0.1:18554/cam go test ./internal/media -run RealCamera
func TestRealCamera(t *testing.T) {
	src := os.Getenv("HEXAPOD_TEST_RTSP")
	if src == "" {
		t.Skip("HEXAPOD_TEST_RTSP not set")
	}
	dir := t.TempDir()
	g, err := New(Options{Dir: dir, Source: src, MaxRecord: time.Minute})
	if err != nil {
		t.Fatal(err)
	}
	photo, err := g.Photo(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if err := g.StartRecording(); err != nil {
		t.Fatal(err)
	}
	time.Sleep(4 * time.Second)
	video, err := g.StopRecording()
	if err != nil {
		t.Fatal(err)
	}
	for _, f := range []string{photo.Name, video.Name} {
		out, err := exec.Command("ffprobe", "-v", "error", "-show_entries", "stream=codec_name,width,height",
			"-show_entries", "format=duration", "-of", "compact", filepath.Join(dir, f)).CombinedOutput()
		if err != nil {
			t.Fatalf("%s is not valid media: %v %s", f, err, out)
		}
		t.Logf("%s: %s", f, strings.TrimSpace(string(out)))
		if _, err := g.Path(f, true); err != nil {
			t.Errorf("%s: no thumbnail", f)
		}
	}
	if !strings.Contains(video.Name, "video-") || video.Size < 10_000 {
		t.Errorf("video: %+v", video)
	}
}

// TestRealCameraPowerCut: a recording killed without warning (power cut)
// must still play up to where it was.
func TestRealCameraPowerCut(t *testing.T) {
	src := os.Getenv("HEXAPOD_TEST_RTSP")
	if src == "" {
		t.Skip("HEXAPOD_TEST_RTSP not set")
	}
	dir := t.TempDir()
	g, err := New(Options{Dir: dir, Source: src, MaxRecord: time.Minute})
	if err != nil {
		t.Fatal(err)
	}
	if err := g.StartRecording(); err != nil {
		t.Fatal(err)
	}
	time.Sleep(4 * time.Second)
	// What is on the card at this instant is what a power cut leaves.
	g.mu.Lock()
	part := g.part
	g.mu.Unlock()
	b, err := os.ReadFile(part)
	if err != nil {
		t.Fatal(err)
	}
	cut := filepath.Join(t.TempDir(), "cut.mp4")
	_ = os.WriteFile(cut, b, 0o644)
	_, _ = g.StopRecording()
	out, err := exec.Command("ffprobe", "-v", "error", "-show_entries", "format=duration", "-of", "csv=p=0", cut).CombinedOutput()
	if err != nil || strings.TrimSpace(string(out)) == "N/A" {
		t.Fatalf("cut recording does not play: %v %s", err, out)
	}
	t.Logf("cut recording plays: %ss", strings.TrimSpace(string(out)))
}
