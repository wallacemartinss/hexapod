package config

import (
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
)

// The sample shipped in the repo documents the defaults: keep them equal.
func TestSampleEqualsDefaults(t *testing.T) {
	c, err := Load(filepath.Join("..", "..", "hexd.yaml"))
	if err != nil {
		t.Fatal(err)
	}
	if !reflect.DeepEqual(c, Default()) {
		t.Fatalf("pi/hexd/hexd.yaml differs from Default():\n%+v\n%+v", c, Default())
	}
}

func write(t *testing.T, path, content string) {
	t.Helper()
	if err := os.WriteFile(path, []byte(content), 0o644); err != nil {
		t.Fatal(err)
	}
}

func TestMissingAndEmptyFiles(t *testing.T) {
	dir := t.TempDir()
	if c, err := Load(filepath.Join(dir, "absent.yaml")); err != nil || c.Listen != ":8080" {
		t.Fatalf("missing file: %v %+v", err, c)
	}
	empty := filepath.Join(dir, "empty.yaml")
	write(t, empty, "")
	if _, err := Load(empty); err != nil {
		t.Fatalf("empty file: %v", err)
	}
}

func TestOverridesAndTypos(t *testing.T) {
	dir := t.TempDir()
	p := filepath.Join(dir, "hexd.yaml")
	write(t, p, "serial:\n  device: tcp://127.0.0.1:7777\ndeadman:\n  wifi: 200ms\n")
	c, err := Load(p)
	if err != nil || c.Serial.Device != "tcp://127.0.0.1:7777" || c.Deadman.Wifi.Milliseconds() != 200 ||
		c.Serial.Baud != 115200 {
		t.Fatalf("%v %+v", err, c)
	}
	write(t, p, "deadman:\n  wfii: 200ms\n")
	if _, err := Load(p); err == nil || !strings.Contains(err.Error(), "wfii") {
		t.Fatalf("typo not reported: %v", err)
	}
}
