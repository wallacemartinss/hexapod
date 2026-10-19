package server

import (
	"encoding/json"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/wallacemartinss/hexapod/pi/hexd/internal/media"
	"github.com/wallacemartinss/hexapod/pi/hexd/internal/pairing"
)

// Writes every .jpg/.part output; a recording waits for "q" (see media's tests).
const fakeFFmpeg = `#!/bin/sh
rec=0
for a in "$@"; do case "$a" in *.part) rec=1;; esac; done
for a in "$@"; do case "$a" in *.jpg|*.part) echo frame-data > "$a";; esac; done
if [ $rec = 1 ]; then head -c1 >/dev/null; fi
exit 0
`

func TestMediaAPI(t *testing.T) {
	bin := filepath.Join(t.TempDir(), "ffmpeg")
	if err := os.WriteFile(bin, []byte(fakeFFmpeg), 0o755); err != nil {
		t.Fatal(err)
	}
	g, err := media.New(media.Options{Dir: t.TempDir(), Source: "rtsp://x/cam", FFmpeg: bin, MaxRecord: time.Minute})
	if err != nil {
		t.Fatal(err)
	}
	id, _ := pairing.New()
	r := newRig(t, Config{Identity: &id, Media: g})
	call := func(method, path, body string, key bool, hdr ...string) (int, string, http.Header) {
		req, _ := http.NewRequest(method, r.http.URL+path, strings.NewReader(body))
		if key {
			req.Header.Set("Authorization", "Bearer "+id.Token)
		}
		for i := 0; i+1 < len(hdr); i += 2 {
			req.Header.Set(hdr[i], hdr[i+1])
		}
		resp, err := http.DefaultClient.Do(req)
		if err != nil {
			t.Fatal(err)
		}
		defer resp.Body.Close()
		b, _ := io.ReadAll(resp.Body)
		return resp.StatusCode, string(b), resp.Header
	}

	if code, _, _ := call("POST", "/api/media/photo", "", false); code != http.StatusUnauthorized {
		t.Fatalf("photo without key: %d", code)
	}
	code, body, _ := call("POST", "/api/media/photo", "", true)
	var photo media.Item
	_ = json.Unmarshal([]byte(body), &photo)
	if code != 200 || photo.Kind != "photo" {
		t.Fatalf("photo: %d %s", code, body)
	}
	if code, _, _ := call("POST", "/api/media/record", `{"on":true}`, true); code != 200 {
		t.Fatalf("record on: %d", code)
	}
	if code, _, _ := call("POST", "/api/media/record", `{"on":true}`, true); code != http.StatusConflict {
		t.Fatalf("record twice: %d", code)
	}
	if code, body, _ := call("GET", "/api/media", "", true); code != 200 || !strings.Contains(body, `"recording":true`) {
		t.Fatalf("status while recording: %d %s", code, body)
	}
	if code, body, _ := call("POST", "/api/media/record", `{"on":false}`, true); code != 200 || !strings.Contains(body, `"kind":"video"`) {
		t.Fatalf("record off: %d %s", code, body)
	}

	// Download, a range (resume), the thumbnail, then delete.
	code, body, hdr := call("GET", "/api/media/files/"+photo.Name, "", true)
	if code != 200 || body != "frame-data\n" || !strings.Contains(hdr.Get("Content-Disposition"), photo.Name) {
		t.Fatalf("download: %d %q %v", code, body, hdr)
	}
	if code, body, _ := call("GET", "/api/media/files/"+photo.Name, "", true, "Range", "bytes=6-"); code != http.StatusPartialContent || body != "data\n" {
		t.Fatalf("range: %d %q", code, body)
	}
	if code, _, _ := call("GET", "/api/media/files/"+photo.Name+"?thumb=1", "", true); code != 200 {
		t.Fatalf("thumbnail: %d", code)
	}
	if code, _, _ := call("GET", "/api/media/files/..%2Fidentity.json", "", true); code != http.StatusNotFound {
		t.Fatalf("path escape: %d", code)
	}
	if code, _, _ := call("DELETE", "/api/media/files/"+photo.Name, "", true); code != 200 {
		t.Fatalf("delete: %d", code)
	}
	if code, body, _ := call("GET", "/api/media", "", true); code != 200 || strings.Count(body, `"name"`) != 1 {
		t.Fatalf("after delete: %s", body)
	}
}
