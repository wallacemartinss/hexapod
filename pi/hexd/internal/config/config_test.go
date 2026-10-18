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

func TestMissingAndEmptyFiles(t *testing.T) {
	dir := t.TempDir()
	if c, err := Load(filepath.Join(dir, "absent.yaml")); err != nil || c.Listen != ":8080" {
		t.Fatalf("missing file: %v %+v", err, c)
	}
	empty := filepath.Join(dir, "empty.yaml")
	os.WriteFile(empty, nil, 0o644)
	if _, err := Load(empty); err != nil {
		t.Fatalf("empty file: %v", err)
	}
}

func TestOverridesAndTypos(t *testing.T) {
	dir := t.TempDir()
	p := filepath.Join(dir, "hexd.yaml")
	os.WriteFile(p, []byte("serial:\n  device: tcp://127.0.0.1:7777\ndeadman:\n  wifi: 200ms\n"), 0o644)
	c, err := Load(p)
	if err != nil || c.Serial.Device != "tcp://127.0.0.1:7777" || c.Deadman.Wifi.Milliseconds() != 200 ||
		c.Serial.Baud != 115200 {
		t.Fatalf("%v %+v", err, c)
	}
	os.WriteFile(p, []byte("deadman:\n  wfii: 200ms\n"), 0o644)
	if _, err := Load(p); err == nil || !strings.Contains(err.Error(), "wfii") {
		t.Fatalf("typo not reported: %v", err)
	}
}
