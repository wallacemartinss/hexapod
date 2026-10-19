package display

import (
	"fmt"
	"io"
	"os"
	"time"

	"golang.org/x/sys/unix"
)

// i2cSlave is the i2c-dev ioctl that sets the target address.
const i2cSlave = 0x0703

// chunk is the most pixel bytes sent in one I2C write (plus the 0x40 byte).
const chunk = 16

// Panel is an SSD1306 128x64 on an I2C bus.
type Panel struct {
	w io.WriteCloser
	// gap is a pause after every I2C write. The panel on the robot misses
	// writes sent back to back (a lost "display on" left it dark; lost
	// pixels skewed the image), while the same bytes with pauses work.
	gap time.Duration
}

// Open talks to the panel at addr on an i2c-dev bus (e.g. /dev/i2c-1, 0x3C).
func Open(bus string, addr int) (*Panel, error) {
	f, err := os.OpenFile(bus, os.O_RDWR, 0)
	if err != nil {
		return nil, err
	}
	if err := unix.IoctlSetInt(int(f.Fd()), i2cSlave, addr); err != nil {
		f.Close()
		return nil, fmt.Errorf("%s address 0x%02x: %w", bus, addr, err)
	}
	return &Panel{w: f, gap: time.Millisecond}, nil
}

// NewPanel wraps any writer that reaches the panel (tests).
func NewPanel(w io.WriteCloser) *Panel { return &Panel{w: w} }

func (p *Panel) write(b []byte) error {
	_, err := p.w.Write(b)
	if p.gap > 0 {
		time.Sleep(p.gap)
	}
	return err
}

func (p *Panel) cmd(b ...byte) error {
	return p.write(append([]byte{0x00}, b...)) // 0x00: command stream
}

// Init configures the panel and turns it on (charge pump on, horizontal
// addressing, normal orientation).
func (p *Panel) Init() error {
	if err := p.cmd(0xAE); err != nil { // display off while configuring
		return err
	}
	err := p.Wake()
	time.Sleep(20 * p.gap) // let the charge pump settle before the first frame
	return err
}

// Wake re-sends the whole configuration without turning the display off
// first, so it does not flicker. A brown-out resets the controller to
// "display off, page addressing" while the bus keeps answering: re-sent
// often, the screen comes back by itself.
func (p *Panel) Wake() error {
	return p.cmd(
		0x2E,       // no scrolling: a corrupted byte can start it, and it garbles RAM writes
		0x23, 0x00, // no fade-out/blinking: if a corrupted byte starts it, the panel fades dark
		0xD6, 0x00, // no zoom
		0xD5, 0x80, // clock
		0xA8, 0x3F, // 64 rows
		0xD3, 0x00, // no offset
		0x40,       // start line 0
		0x8D, 0x14, // charge pump on (no external VCC)
		0x20, 0x00, // horizontal addressing
		0xA1, 0xC8, // column 127 -> SEG0, scan COM63 -> COM0: upright
		0xDA, 0x12, // COM pins for 128x64
		0x81, 0xCF, // contrast: 0x8F looked dim on the robot's panel
		0xD9, 0xF1, // pre-charge
		0xDB, 0x40, // VCOMH
		0xA4, // show RAM
		0xA6, // not inverted
		0xAF, // display on
	)
}

// Show sends a whole frame.
func (p *Panel) Show(f *Frame) error {
	if err := p.cmd(0x21, 0, Width-1, 0x22, 0, pages-1); err != nil { // full window
		return err
	}
	// Small transfers, like the known SSD1306 drivers: this panel loses
	// long ones (129 bytes) and turned dark, taking pixels for commands.
	for page := range f {
		row := f[page][:]
		for i := 0; i < len(row); i += chunk {
			buf := append([]byte{0x40}, row[i:min(i+chunk, len(row))]...) // 0x40: data stream
			if err := p.write(buf); err != nil {
				return err
			}
		}
	}
	return nil
}

// Close releases the bus. The panel keeps showing the last frame.
func (p *Panel) Close() error { return p.w.Close() }
