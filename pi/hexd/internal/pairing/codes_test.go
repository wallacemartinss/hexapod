package pairing

import (
	"strings"
	"testing"
	"time"
)

func clock(start time.Time) (func() time.Time, func(time.Duration)) {
	t := start
	return func() time.Time { return t }, func(d time.Duration) { t = t.Add(d) }
}

func TestCodeIsShortAndReadable(t *testing.T) {
	c := &Codes{TTL: 10 * time.Minute}
	code := c.Current()
	if len(code) != CodeLength {
		t.Fatalf("%q", code)
	}
	for _, r := range code {
		if !strings.ContainsRune(codeAlphabet, r) {
			t.Fatalf("%q has %q", code, r)
		}
	}
	if strings.ContainsAny(codeAlphabet, "01OIL") {
		t.Fatal("look-alike characters in the alphabet")
	}
}

func TestCodeWorksOnce(t *testing.T) {
	c := &Codes{TTL: 10 * time.Minute}
	code := c.Current()
	if !c.Check(code) {
		t.Fatal("right code refused")
	}
	if c.Check(code) || c.Current() == code {
		t.Fatal("a used code must change")
	}
}

func TestWrongTriesChangeTheCode(t *testing.T) {
	c := &Codes{TTL: 10 * time.Minute}
	code := c.Current()
	for i := 0; i < MaxFails-1; i++ {
		c.Check("ZZZZZ")
	}
	if c.Current() != code {
		t.Fatal("changed too early")
	}
	c.Check("ZZZZZ")
	if c.Current() == code || c.Check(code) {
		t.Fatal("after MaxFails wrong tries the old code must be dead")
	}
}

func TestCodeExpires(t *testing.T) {
	now, advance := clock(time.Unix(1000, 0))
	c := &Codes{TTL: 10 * time.Minute, Now: now}
	code := c.Current()
	advance(9 * time.Minute)
	if c.Current() != code {
		t.Fatal("expired early")
	}
	advance(2 * time.Minute)
	if c.Check(code) {
		t.Fatal("an expired code was accepted")
	}
}

func TestOwnNetworkOpenUntilPaired(t *testing.T) {
	id := Identity{ID: "7F3A", Token: "ABCDEFGHJKLMNPQRSTUV"}
	if ssid, pass := id.OwnNetwork(); ssid != "Hexapode-7F3A" || pass != "" {
		t.Fatalf("never paired: open network expected, got %q %q", ssid, pass)
	}
	id.Paired = true
	if _, pass := id.OwnNetwork(); pass != "KCGBVTPAD3HK" {
		t.Fatalf("paired: derived password expected, got %q", pass)
	}
}
