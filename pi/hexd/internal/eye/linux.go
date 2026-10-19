package eye

import (
	"fmt"
	"os"
	"unsafe"

	"golang.org/x/sys/unix"
)

// Talking to the display from Linux userspace with no library: SPI through
// spidev, the DC/RESET/backlight pins through the GPIO character device
// (uAPI v2). Both need only the spi and gpio groups.

// SPI is an open spidev device.
type SPI struct{ f *os.File }

const (
	spiIOCWrMode        = 0x40016b01 // _IOW('k', 1, u8)
	spiIOCWrBitsPerWord = 0x40016b03 // _IOW('k', 3, u8)
	spiIOCWrMaxSpeedHz  = 0x40046b04 // _IOW('k', 4, u32)
	spiChunk            = 4096       // spidev's default buffer
)

// OpenSPI opens a spidev (e.g. /dev/spidev0.0) in the given mode (0..3) and
// clock (Hz).
func OpenSPI(dev string, mode uint8, hz uint32) (*SPI, error) {
	f, err := os.OpenFile(dev, os.O_RDWR, 0)
	if err != nil {
		return nil, err
	}
	bits := uint8(8)
	for _, set := range []struct {
		req uintptr
		arg unsafe.Pointer
	}{{spiIOCWrMode, unsafe.Pointer(&mode)}, {spiIOCWrBitsPerWord, unsafe.Pointer(&bits)}, {spiIOCWrMaxSpeedHz, unsafe.Pointer(&hz)}} {
		if _, _, e := unix.Syscall(unix.SYS_IOCTL, f.Fd(), set.req, uintptr(set.arg)); e != 0 {
			f.Close()
			return nil, fmt.Errorf("spi setup: %w", e)
		}
	}
	return &SPI{f: f}, nil
}

// Write sends b in chunks the driver accepts.
func (s *SPI) Write(b []byte) error {
	for len(b) > 0 {
		n := min(len(b), spiChunk)
		if _, err := s.f.Write(b[:n]); err != nil {
			return err
		}
		b = b[n:]
	}
	return nil
}

func (s *SPI) Close() error { return s.f.Close() }

// GPIO uAPI v2 (linux/gpio.h).
const (
	gpioV2GetLineIOCTL      = 0xc250b407 // _IOWR(0xB4, 0x07, struct gpio_v2_line_request)
	gpioV2LineSetValuesIOCT = 0xc010b40f // _IOWR(0xB4, 0x0F, struct gpio_v2_line_values)
	gpioV2LineFlagOutput    = 1 << 3
)

type gpioLineAttr struct {
	ID  uint32
	_   uint32
	Val uint64
}

type gpioLineConfigAttr struct {
	Attr gpioLineAttr
	Mask uint64
}

type gpioLineConfig struct {
	Flags    uint64
	NumAttrs uint32
	_        [5]uint32
	Attrs    [10]gpioLineConfigAttr
}

type gpioLineRequest struct {
	Offsets         [64]uint32
	Consumer        [32]byte
	Config          gpioLineConfig
	NumLines        uint32
	EventBufferSize uint32
	_               [5]uint32
	Fd              int32
}

type gpioLineValues struct{ Bits, Mask uint64 }

// Pins are output lines of a GPIO chip, set by index in the order requested.
type Pins struct{ fd int }

// OpenPins requests lines (BCM numbers on the Pi's gpiochip0) as outputs, all low.
func OpenPins(chip string, lines ...int) (*Pins, error) {
	f, err := os.Open(chip)
	if err != nil {
		return nil, err
	}
	defer f.Close()
	var req gpioLineRequest
	for i, l := range lines {
		req.Offsets[i] = uint32(l)
	}
	copy(req.Consumer[:], "hexd-eye")
	req.Config.Flags = gpioV2LineFlagOutput
	req.NumLines = uint32(len(lines))
	if _, _, e := unix.Syscall(unix.SYS_IOCTL, f.Fd(), gpioV2GetLineIOCTL, uintptr(unsafe.Pointer(&req))); e != 0 {
		return nil, fmt.Errorf("gpio lines %v: %w", lines, e)
	}
	return &Pins{fd: int(req.Fd)}, nil
}

// Set drives line i (its index in OpenPins) high or low.
func (p *Pins) Set(i int, high bool) error {
	v := gpioLineValues{Mask: 1 << i}
	if high {
		v.Bits = 1 << i
	}
	if _, _, e := unix.Syscall(unix.SYS_IOCTL, uintptr(p.fd), gpioV2LineSetValuesIOCT, uintptr(unsafe.Pointer(&v))); e != 0 {
		return e
	}
	return nil
}

func (p *Pins) Close() error { return unix.Close(p.fd) }
