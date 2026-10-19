package eye

import (
	"fmt"
	"image"
	"time"
)

// Bus is how the panel is reached: commands and data over SPI, with the
// DC pin telling them apart, plus reset and backlight. Tests use a fake.
type Bus interface {
	Command(cmd byte, data ...byte) error
	Data(b []byte) error
	Reset() error
	Backlight(on bool) error
	Close() error
}

// ST7789 commands.
const (
	cmdSWRESET = 0x01
	cmdSLPIN   = 0x10
	cmdSLPOUT  = 0x11
	cmdNORON   = 0x13
	cmdINVON   = 0x21
	cmdDISPOFF = 0x28
	cmdDISPON  = 0x29
	cmdCASET   = 0x2A
	cmdRASET   = 0x2B
	cmdRAMWR   = 0x2C
	cmdMADCTL  = 0x36
	cmdCOLMOD  = 0x3A
)

// Panel drives a 240x240 ST7789 (the 1.54" IPS boards). It only sends the
// rectangle that changed since the last frame: the eye mostly moves inside
// the iris, so most frames are a fraction of the screen.
type Panel struct {
	bus      Bus
	rotation int  // 0, 90, 180, 270
	bgr      bool // panel wired blue-green-red
	prev     []uint16
	buf      []byte
	sleep    func(time.Duration)
}

// NewPanel wraps a bus; Init must run before Draw.
func NewPanel(bus Bus, rotation int, bgr bool) *Panel {
	return &Panel{bus: bus, rotation: rotation, bgr: bgr, sleep: time.Sleep}
}

// Init resets the controller and turns the panel on, black.
func (p *Panel) Init() error {
	if err := p.bus.Reset(); err != nil {
		return err
	}
	madctl := map[int]byte{0: 0x00, 90: 0x60, 180: 0xC0, 270: 0xA0}[p.rotation]
	if p.bgr {
		madctl |= 0x08
	}
	steps := []struct {
		cmd  byte
		data []byte
		wait time.Duration
	}{
		{cmdSWRESET, nil, 150 * time.Millisecond},
		{cmdSLPOUT, nil, 120 * time.Millisecond},
		{cmdCOLMOD, []byte{0x55}, 10 * time.Millisecond}, // 16-bit RGB565
		{cmdMADCTL, []byte{madctl}, 0},
		{cmdINVON, nil, 0}, // IPS panels show true colors inverted
		{cmdNORON, nil, 10 * time.Millisecond},
	}
	for _, s := range steps {
		if err := p.bus.Command(s.cmd, s.data...); err != nil {
			return fmt.Errorf("st7789 init 0x%02x: %w", s.cmd, err)
		}
		p.sleep(s.wait)
	}
	p.prev = nil
	if err := p.Draw(image.NewRGBA(image.Rect(0, 0, Size, Size))); err != nil { // black before the light comes on
		return err
	}
	if err := p.bus.Command(cmdDISPON); err != nil {
		return err
	}
	p.sleep(20 * time.Millisecond)
	return p.bus.Backlight(true)
}

// Draw sends the part of img that differs from the last frame.
func (p *Panel) Draw(img *image.RGBA) error {
	cur := make([]uint16, Size*Size)
	for y := 0; y < Size; y++ {
		for x := 0; x < Size; x++ {
			c := img.RGBAAt(x, y)
			cur[y*Size+x] = uint16(c.R>>3)<<11 | uint16(c.G>>2)<<5 | uint16(c.B>>3)
		}
	}
	x0, y0, x1, y1 := 0, 0, Size-1, Size-1
	if p.prev != nil {
		var changed bool
		x0, y0, x1, y1, changed = diffBox(p.prev, cur)
		if !changed {
			return nil
		}
	}
	if err := p.window(x0, y0, x1, y1); err != nil {
		return err
	}
	w := x1 - x0 + 1
	need := w * (y1 - y0 + 1) * 2
	if cap(p.buf) < need {
		p.buf = make([]byte, need)
	}
	b := p.buf[:0]
	for y := y0; y <= y1; y++ {
		for _, v := range cur[y*Size+x0 : y*Size+x1+1] {
			b = append(b, byte(v>>8), byte(v)) // big-endian
		}
	}
	if err := p.bus.Data(b); err != nil {
		return err
	}
	p.prev = cur
	return nil
}

// window sets the area RAMWR fills; a 240x240 panel sits in a 240x320
// controller, offset by 80 when flipped.
func (p *Panel) window(x0, y0, x1, y1 int) error {
	ox, oy := 0, 0
	switch p.rotation {
	case 180:
		oy = 80
	case 270:
		ox = 80
	}
	be := func(a, b int) []byte { return []byte{byte(a >> 8), byte(a), byte(b >> 8), byte(b)} }
	if err := p.bus.Command(cmdCASET, be(x0+ox, x1+ox)...); err != nil {
		return err
	}
	if err := p.bus.Command(cmdRASET, be(y0+oy, y1+oy)...); err != nil {
		return err
	}
	return p.bus.Command(cmdRAMWR)
}

// Off darkens the backlight and puts the controller to sleep.
func (p *Panel) Off() error {
	_ = p.bus.Backlight(false)
	_ = p.bus.Command(cmdDISPOFF)
	return p.bus.Command(cmdSLPIN)
}

// diffBox is the smallest rectangle holding every changed pixel.
func diffBox(a, b []uint16) (x0, y0, x1, y1 int, changed bool) {
	x0, y0, x1, y1 = Size, Size, -1, -1
	for y := 0; y < Size; y++ {
		row := y * Size
		for x := 0; x < Size; x++ {
			if a[row+x] != b[row+x] {
				x0, x1 = min(x0, x), max(x1, x)
				y0, y1 = min(y0, y), max(y1, y)
			}
		}
	}
	return x0, y0, x1, y1, x1 >= 0
}

// LinuxBus is the real wiring: spidev plus three GPIO lines.
type LinuxBus struct {
	spi  *SPI
	pins *Pins // 0 = DC, 1 = RESET, 2 = backlight
}

// Lines of OpenLinuxBus's pins.
const (
	pinDC = iota
	pinReset
	pinBacklight
)

// OpenLinuxBus opens the display's SPI device and GPIO lines (BCM numbers).
func OpenLinuxBus(spiDev string, mode uint8, hz uint32, gpioChip string, dc, reset, backlight int) (*LinuxBus, error) {
	s, err := OpenSPI(spiDev, mode, hz)
	if err != nil {
		return nil, err
	}
	pins, err := OpenPins(gpioChip, dc, reset, backlight)
	if err != nil {
		s.Close()
		return nil, err
	}
	return &LinuxBus{spi: s, pins: pins}, nil
}

func (b *LinuxBus) Command(cmd byte, data ...byte) error {
	if err := b.pins.Set(pinDC, false); err != nil {
		return err
	}
	if err := b.spi.Write([]byte{cmd}); err != nil {
		return err
	}
	if len(data) == 0 {
		return nil
	}
	return b.Data(data)
}

func (b *LinuxBus) Data(d []byte) error {
	if err := b.pins.Set(pinDC, true); err != nil {
		return err
	}
	return b.spi.Write(d)
}

func (b *LinuxBus) Reset() error {
	_ = b.pins.Set(pinReset, true)
	time.Sleep(5 * time.Millisecond)
	if err := b.pins.Set(pinReset, false); err != nil {
		return err
	}
	time.Sleep(20 * time.Millisecond)
	if err := b.pins.Set(pinReset, true); err != nil {
		return err
	}
	time.Sleep(120 * time.Millisecond)
	return nil
}

func (b *LinuxBus) Backlight(on bool) error { return b.pins.Set(pinBacklight, on) }

func (b *LinuxBus) Close() error {
	b.pins.Close()
	return b.spi.Close()
}
