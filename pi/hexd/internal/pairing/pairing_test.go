package pairing

import (
	"net/http"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"testing"
)

func TestCreatedOnceThenKept(t *testing.T) {
	path := filepath.Join(t.TempDir(), "config", "identity.json")
	first, err := LoadOrCreate(path)
	if err != nil {
		t.Fatal(err)
	}
	again, err := LoadOrCreate(path)
	if err != nil {
		t.Fatal(err)
	}
	if again != first {
		t.Fatalf("identity changed between starts: %v vs %v", first, again)
	}
	info, err := os.Stat(path)
	if err != nil {
		t.Fatal(err)
	}
	if info.Mode().Perm() != 0o600 {
		t.Fatalf("mode %v: the key must be private", info.Mode().Perm())
	}
}

func TestEveryRobotDiffers(t *testing.T) {
	a, _ := New()
	b, _ := New()
	if a.Token == b.Token || a.ID == b.ID && a.Token == b.Token {
		t.Fatal("two robots share a key")
	}
}

func TestQRIsSmallAndAlphanumeric(t *testing.T) {
	id, _ := New()
	qr := id.QR()
	// QR alphanumeric mode: 0-9 A-Z space $ % * + - . / :
	if !regexp.MustCompile(`^[0-9A-Z $%*+\-./:]+$`).MatchString(qr) {
		t.Fatalf("%q leaves alphanumeric mode (bigger QR)", qr)
	}
	if len(qr) > 38 { // version 2, ECC M
		t.Fatalf("%q is %d chars: no longer fits a version 2 QR", qr, len(qr))
	}
	robot, token, ok := ParseQR(qr)
	if !ok || robot != id.ID || token != id.Token {
		t.Fatalf("round trip: %q -> %q %q %v", qr, robot, token, ok)
	}
}

func TestAllowed(t *testing.T) {
	id, _ := New()
	req := func(h string) *http.Request {
		r, _ := http.NewRequest("GET", "/ws", nil)
		if h != "" {
			r.Header.Set("Authorization", h)
		}
		return r
	}
	if !id.Allowed(req("Bearer " + id.Token)) {
		t.Fatal("right key refused")
	}
	for _, h := range []string{"", "Bearer", "Bearer wrong", id.Token, "Basic " + id.Token} {
		if id.Allowed(req(h)) {
			t.Errorf("%q accepted", h)
		}
	}
}

func TestBrokenFileIsAnError(t *testing.T) {
	path := filepath.Join(t.TempDir(), "identity.json")
	if err := os.WriteFile(path, []byte(`{"id":"X"}`), 0o600); err != nil {
		t.Fatal(err)
	}
	if _, err := LoadOrCreate(path); err == nil {
		t.Fatal("a truncated identity must not be used (or silently replaced)")
	}
}

func TestOwnNetwork(t *testing.T) {
	id := Identity{ID: "7F3A", Token: "ABCDEFGHJKLMNPQRSTUV"}
	ssid, pass := id.OwnNetwork()
	// Pinned: the app computes the same (app/test/pairing_test.dart).
	if ssid != "Hexapode-7F3A" || pass != "KCGBVTPAD3HK" {
		t.Fatalf("%q %q", ssid, pass)
	}
	if strings.Contains(id.Token, pass) {
		t.Fatal("the Wi-Fi password must not reveal the key")
	}
}
