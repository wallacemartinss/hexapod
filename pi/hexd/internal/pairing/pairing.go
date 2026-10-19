// Package pairing keeps the robot's identity: a short id, a name and the
// secret key an app must present (shown as a QR code on the OLED, so only
// someone holding the robot can pair). Created on first start.
package pairing

import (
	"crypto/rand"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/base32"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"os"
	"path/filepath"
	"strings"

	"rsc.io/qr"
)

// Identity is stored as JSON, readable only by the service user.
type Identity struct {
	ID    string `json:"id"`    // 4 characters, e.g. "7F3A": names the robot's own Wi-Fi
	Name  string `json:"name"`  // shown in the app, changed from the app
	Token string `json:"token"` // 20 base32 characters (100 bits)
	// Paired: some app has paired at least once. Until then the robot's own
	// Wi-Fi is open, so a phone can reach it to type the short code.
	Paired bool `json:"paired"`
}

// QR payload prefix; the version lets the format change later.
const qrPrefix = "HXP1"

// Unambiguous upper-case base32 (no 0/1/8/9): all QR alphanumeric characters.
var encoding = base32.StdEncoding.WithPadding(base32.NoPadding)

func random(n int) (string, error) {
	b := make([]byte, (n*5+7)/8)
	if _, err := rand.Read(b); err != nil {
		return "", err
	}
	return encoding.EncodeToString(b)[:n], nil
}

// New makes a fresh identity.
func New() (Identity, error) {
	id, err := random(4)
	if err != nil {
		return Identity{}, err
	}
	token, err := random(20)
	if err != nil {
		return Identity{}, err
	}
	return Identity{ID: id, Name: "Hexápode " + id, Token: token}, nil
}

// LoadOrCreate reads path, or creates it (mode 0600) on first start.
func LoadOrCreate(path string) (Identity, error) {
	b, err := os.ReadFile(path)
	if err == nil {
		var id Identity
		if err := json.Unmarshal(b, &id); err != nil {
			return Identity{}, fmt.Errorf("%s: %w", path, err)
		}
		if len(id.ID) != 4 || len(id.Token) < 16 {
			return Identity{}, fmt.Errorf("%s: incomplete identity", path)
		}
		return id, nil
	}
	if !errors.Is(err, os.ErrNotExist) {
		return Identity{}, err
	}
	id, err := New()
	if err != nil {
		return Identity{}, err
	}
	return id, Save(path, id)
}

// Save writes atomically, so a power cut never leaves half a file.
func Save(path string, id Identity) error {
	b, err := json.MarshalIndent(id, "", "  ")
	if err != nil {
		return err
	}
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return err
	}
	tmp := path + ".tmp"
	if err := os.WriteFile(tmp, append(b, '\n'), 0o600); err != nil {
		return err
	}
	return os.Rename(tmp, path)
}

// QR is the text of the pairing QR code: "HXP1 7F3A <key>". Only QR
// alphanumeric characters, so it fits a small code (version 2).
func (id Identity) QR() string { return qrPrefix + " " + id.ID + " " + id.Token }

// ParseQR is the reverse of QR (used by tools; the app has its own).
func ParseQR(s string) (robotID, token string, ok bool) {
	f := strings.Fields(strings.TrimSpace(s))
	if len(f) != 3 || f[0] != qrPrefix {
		return "", "", false
	}
	return f[1], f[2], true
}

// Allowed reports whether r presents the key ("Authorization: Bearer
// <key>"), compared in constant time.
func (id Identity) Allowed(r *http.Request) bool {
	got, ok := strings.CutPrefix(r.Header.Get("Authorization"), "Bearer ")
	return ok && subtle.ConstantTimeCompare([]byte(got), []byte(id.Token)) == 1
}

// TerminalQR draws text as a QR code with Unicode half blocks (two module
// rows per line), light on dark terminals included: scan it from the screen.
func TerminalQR(text string) string {
	code, err := qr.Encode(text, qr.M)
	if err != nil {
		return ""
	}
	const quiet = 2
	light := func(x, y int) bool { return !code.Black(x-quiet, y-quiet) }
	n := code.Size + 2*quiet
	var b strings.Builder
	for y := 0; y < n; y += 2 {
		for x := 0; x < n; x++ {
			top, bottom := light(x, y), y+1 < n && light(x, y+1)
			switch {
			case top && bottom:
				b.WriteString("█")
			case top:
				b.WriteString("▀")
			case bottom:
				b.WriteString("▄")
			default:
				b.WriteString(" ")
			}
		}
		b.WriteByte('\n')
	}
	return b.String()
}

// OwnNetwork is the robot's own Wi-Fi: "Hexapode-<id>" and a WPA2 password
// derived one way from the key (the app derives the same). Someone given
// the Wi-Fi password does not learn the key. Open ("") until the first
// pairing, so a new phone can reach the robot to type the short code.
func (id Identity) OwnNetwork() (ssid, password string) {
	ssid = "Hexapode-" + id.ID
	if !id.Paired {
		return ssid, ""
	}
	sum := sha256.Sum256([]byte("hexapod-ap:" + id.Token))
	return ssid, encoding.EncodeToString(sum[:])[:12]
}
