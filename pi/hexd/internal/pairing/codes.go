package pairing

import (
	"crypto/rand"
	"crypto/subtle"
	"math/big"
	"sync"
	"time"
)

// codeAlphabet has no look-alikes (0/O, 1/I/L): easy to read on a small
// screen and to type; all QR alphanumeric characters.
const codeAlphabet = "23456789ABCDEFGHJKMNPQRSTUVWXYZ"

// CodeLength: 31^5 = 28.6 million codes.
const CodeLength = 5

// MaxFails wrong codes in a row get a new code.
const MaxFails = 5

// Codes is the short pairing code shown on the robot's screen. An app that
// presents it gets the real key. It changes every TTL, after every use and
// after MaxFails wrong tries, so guessing is hopeless. Safe for concurrent use.
type Codes struct {
	TTL time.Duration
	Now func() time.Time

	mu     sync.Mutex
	code   string
	issued time.Time
	fails  int
}

func newCode() string {
	b := make([]byte, CodeLength)
	for i := range b {
		n, err := rand.Int(rand.Reader, big.NewInt(int64(len(codeAlphabet))))
		if err != nil {
			panic(err) // no randomness: nothing safe to do
		}
		b[i] = codeAlphabet[n.Int64()]
	}
	return string(b)
}

func (c *Codes) now() time.Time {
	if c.Now != nil {
		return c.Now()
	}
	return time.Now()
}

func (c *Codes) rotate(now time.Time) {
	c.code, c.issued, c.fails = newCode(), now, 0
}

// Current is the code to show now.
func (c *Codes) Current() string {
	c.mu.Lock()
	defer c.mu.Unlock()
	if now := c.now(); c.code == "" || now.Sub(c.issued) >= c.TTL {
		c.rotate(now)
	}
	return c.code
}

// Check consumes a try: true (and a new code) when it matches.
func (c *Codes) Check(code string) bool {
	c.mu.Lock()
	defer c.mu.Unlock()
	now := c.now()
	if c.code == "" || now.Sub(c.issued) >= c.TTL {
		c.rotate(now)
	}
	if len(code) == CodeLength && subtle.ConstantTimeCompare([]byte(code), []byte(c.code)) == 1 {
		c.rotate(now) // used once
		return true
	}
	if c.fails++; c.fails >= MaxFails {
		c.rotate(now)
	}
	return false
}

// QR is the pairing QR code text: "HXP2 <id> <code>".
func (id Identity) PairingQR(code string) string { return "HXP2 " + id.ID + " " + code }
