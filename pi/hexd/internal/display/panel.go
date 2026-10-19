package display

import (
	"fmt"
	"io"
	"os"

	"golang.org/x/sys/unix"
)

// i2cSlave is the i2c-dev ioctl that sets the target address.
const i2cSlave = 0x0703

// chunk is the most pixel bytes sent in one I2C write (plus the 0x40 byte).
const chunk = 16

// Panel is an SSD1306 128x64 on an I2C bus.
type Panel struct {
	w io.WriteCloser
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
	return &Panel{w: f}, nil
}

// NewPanel wraps any writer that reaches the panel (tests).
func NewPanel(w io.WriteCloser) *Panel { return &Panel{w: w} }

func (p *Panel) cmd(b ...byte) error {
	_, err := p.w.Write(append([]byte{0x00}, b...)) // 0x00: command stream
	return err
}

// Init configures the panel and turns it on (charge pump on, horizontal
// addressing, normal orientation).
func (p *Panel) Init() error {
	if err := p.cmd(0xAE); err != nil { // display off while configuring
		return err
	}
	return p.Wake()
}

// Wake re-sends the whole configuration without turning the display off
// first, so it does not flicker. A brown-out resets the controller to
// "display off, page addressing" while the bus keeps answering: re-sent
// often, the screen comes back by itself.
func (p *Panel) Wake() error {
	return p.cmd(
		0xD5, 0x80, // clock
		0xA8, 0x3F, // 64 rows
		0xD3, 0x00, // no offset
		0x40,       // start line 0
		0x8D, 0x14, // charge pump on (no external VCC)
		0x20, 0x00, // horizontal addressing
		0xA1, 0xC8, // column 127 -> SEG0, scan COM63 -> COM0: upright
		0xDA, 0x12, // COM pins for 128x64
		0x81, 0x8F, // contrast (lower than max: less burn-in)
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
			if _, err := p.w.Write(buf); err != nil {
				return err
			}
		}
	}
	return nil
}

// Close releases the bus. The panel keeps showing the last frame.
func (p *Panel) Close() error { return p.w.Close() }
