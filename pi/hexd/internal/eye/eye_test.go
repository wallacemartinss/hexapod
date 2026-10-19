package eye

import (
	"context"
	"errors"
	"image"
	"image/color"
	"io"
	"log/slog"
	"math"
	"sync"
	"testing"
	"time"
	"unsafe"
)

// The uAPI structs must match linux/gpio.h byte for byte.
func TestGPIOStructSizes(t *testing.T) {
	if s := unsafe.Sizeof(gpioLineRequest{}); s != 592 {
		t.Errorf("gpio_v2_line_request: %d bytes, want 592", s)
	}
	if s := unsafe.Sizeof(gpioLineConfig{}); s != 272 {
		t.Errorf("gpio_v2_line_config: %d bytes, want 272", s)
	}
	if s := unsafe.Sizeof(gpioLineValues{}); s != 16 {
		t.Errorf("gpio_v2_line_values: %d bytes, want 16", s)
	}
}

// fakeBus records what the panel was sent.
type fakeBus struct {
	mu        sync.Mutex
	cmds      []byte
	windows   [][4]int
	pixels    int // RGB565 pixels sent
	backlight bool
	failAfter int // Data fails after this many calls (0 = never)
	datas     int
	lastCmd   byte
	args      []byte
}

func (b *fakeBus) Command(cmd byte, data ...byte) error {
	b.mu.Lock()
	defer b.mu.Unlock()
	b.cmds = append(b.cmds, cmd)
	switch cmd {
	case cmdCASET:
		b.args = data
	case cmdRASET:
		x0, x1 := int(b.args[0])<<8|int(b.args[1]), int(b.args[2])<<8|int(b.args[3])
		y0, y1 := int(data[0])<<8|int(data[1]), int(data[2])<<8|int(data[3])
		b.windows = append(b.windows, [4]int{x0, y0, x1, y1})
	}
	b.lastCmd = cmd
	return nil
}

func (b *fakeBus) Data(d []byte) error {
	b.mu.Lock()
	defer b.mu.Unlock()
	b.datas++
	if b.failAfter > 0 && b.datas > b.failAfter {
		return errors.New("spi: broken pipe")
	}
	if b.lastCmd == cmdRAMWR {
		b.pixels += len(d) / 2
	}
	return nil
}

func (b *fakeBus) Reset() error            { return nil }
func (b *fakeBus) Backlight(on bool) error { b.mu.Lock(); b.backlight = on; b.mu.Unlock(); return nil }
func (b *fakeBus) Close() error            { return nil }

func TestPanelSendsOnlyWhatChanged(t *testing.T) {
	bus := &fakeBus{}
	p := NewPanel(bus, 0, false)
	p.sleep = func(time.Duration) {}
	if err := p.Init(); err != nil {
		t.Fatal(err)
	}
	if !bus.backlight || bus.pixels != Size*Size {
		t.Fatalf("init: backlight %v, %d pixels", bus.backlight, bus.pixels)
	}
	img := image.NewRGBA(image.Rect(0, 0, Size, Size))
	if err := p.Draw(img); err != nil || bus.pixels != Size*Size {
		t.Fatalf("an unchanged frame was sent: %v, %d", err, bus.pixels)
	}
	img.SetRGBA(10, 20, color.RGBA{255, 0, 0, 255})
	img.SetRGBA(30, 25, color.RGBA{0, 255, 0, 255})
	if err := p.Draw(img); err != nil {
		t.Fatal(err)
	}
	if w := bus.windows[len(bus.windows)-1]; w != [4]int{10, 20, 30, 25} {
		t.Errorf("window %v, want the changed box", w)
	}
	if got := bus.pixels - Size*Size; got != 21*6 {
		t.Errorf("sent %d pixels, want 126", got)
	}
}

func TestPanelOffsetWhenFlipped(t *testing.T) {
	bus := &fakeBus{}
	p := NewPanel(bus, 180, false)
	p.sleep = func(time.Duration) {}
	_ = p.Init()
	if w := bus.windows[0]; w != [4]int{0, 80, 239, 319} {
		t.Errorf("flipped window %v: rows must start at 80", w)
	}
}

func TestRunRetriesAndClosesTheEye(t *testing.T) {
	bus := &fakeBus{}
	opens := 0
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan struct{})
	go func() {
		Run(ctx, Options{
			Open: func() (Bus, error) {
				opens++
				if opens == 1 {
					return nil, errors.New("no /dev/spidev0.0")
				}
				return bus, nil
			},
			FPS: 50, Retry: 10 * time.Millisecond,
			Log: slog.New(slog.NewTextHandler(io.Discard, nil)),
		}, func() Inputs { return Inputs{Mood: Ready, Boot: -1} })
		close(done)
	}()
	time.Sleep(300 * time.Millisecond)
	cancel()
	<-done
	bus.mu.Lock()
	defer bus.mu.Unlock()
	if opens < 2 || bus.pixels <= Size*Size {
		t.Errorf("opens %d, pixels %d: the eye never ran after the retry", opens, bus.pixels)
	}
	if bus.backlight || bus.lastCmd != cmdSLPIN {
		t.Errorf("after stop: backlight %v, last command 0x%02x (want the panel asleep)", bus.backlight, bus.lastCmd)
	}
}

func TestEveryMoodRenders(t *testing.T) {
	a := NewAnimator(1)
	for m := Ready; m <= Hunter; m++ {
		for i := 0; i < 10; i++ {
			img := Render(a.Step(50*time.Millisecond, Inputs{Mood: m, Boot: -1, Wink: i / 5, Photo: i / 5, Sneeze: i / 5}))
			if img.Bounds().Dx() != Size {
				t.Fatalf("mood %d: bad image", m)
			}
		}
	}
	qr := Render(a.Step(time.Millisecond, Inputs{PairQR: "HXP2 K7F2 Q8M3D", PairCode: "Q8M3D", Boot: -1}))
	if qr.RGBAAt(Size/2, 60) == qr.RGBAAt(5, 5) {
		t.Error("pairing screen shows no QR")
	}
}

// How long one frame takes to draw: on a Pi 3, about 8x this machine.
func BenchmarkRender(b *testing.B) {
	a := NewAnimator(1)
	l := a.Step(time.Second, Inputs{Mood: Ready, Boot: -1})
	for b.Loop() {
		Render(l)
	}
}

// The fast path must look like the reference one.
func TestFastMatchesReference(t *testing.T) {
	a := NewAnimator(3)
	for m := Ready; m <= Hunter; m++ {
		var l Look
		for i := 0; i < 40; i++ {
			l = a.Step(50*time.Millisecond, Inputs{Mood: m, Boot: -1, Recording: m == Ready})
		}
		if l.Swirl >= 0 || l.Fire >= 0 {
			continue // those always take the reference path
		}
		fast := Render(l)
		ref := renderReference(l)
		// Rounding in the sprite's blend leaves a few scattered edge pixels
		// a little off; anything more is a real difference.
		off := 0
		for i := 0; i < len(fast.Pix); i += 4 {
			e := 0
			for k := 0; k < 3; k++ {
				e = max(e, abs(int(fast.Pix[i+k])-int(ref.Pix[i+k])))
			}
			if e > 8 {
				off++
			}
		}
		if off > Size*Size/1000 {
			t.Errorf("mood %d: %d pixels differ from the reference", m, off)
		}
	}
}

func abs(x int) int {
	if x < 0 {
		return -x
	}
	return x
}

// renderReference draws l with shade for every pixel.
func renderReference(l Look) *image.RGBA {
	img := image.NewRGBA(image.Rect(0, 0, Size, Size))
	irisR := 0.58
	if l.IrisScale > 0 {
		irisR *= l.IrisScale
	}
	irisR = math.Round(irisR/px*4) / 4 * px // as the sprite rounds it
	cx, cy := snap(l.X*0.30), snap(l.Y*0.26)
	l.ShakeX, l.ShakeY = math.Round(l.ShakeX/px)*px, math.Round(l.ShakeY/px)*px
	l.Glow = math.Round(clamp(l.Glow, 0, 1.6)*64) / 64
	l.Desat = math.Round(clamp(l.Desat, 0, 1)*64) / 64
	pupilR := irisR * 0.36 * clamp(l.Pupil, 0.4, 1.7)
	for y := 0; y < Size; y++ {
		for x := 0; x < Size; x++ {
			u := (float64(x)+0.5)*px - 1 - l.ShakeX
			v := (float64(y)+0.5)*px - 1 - l.ShakeY
			c := shade(l, u, v, cx, cy, irisR, pupilR, px)
			if l.Hud > 0 {
				c = hud(l, c, u+l.ShakeX, v+l.ShakeY, y, px)
			}
			img.SetRGBA(x, y, scale(c, l.Dim))
		}
	}
	finish(img, l)
	return img
}

// A whole second of a calm eye, as Run draws it (skipping still frames).
func BenchmarkCalmSecond(b *testing.B) {
	for b.Loop() {
		a := NewAnimator(9)
		var shown *Look
		for i := 0; i < 20; i++ {
			l := a.Step(50*time.Millisecond, Inputs{Mood: Ready, Boot: -1})
			if shown != nil && Same(*shown, l) {
				continue
			}
			Render(l)
			shown = &l
		}
	}
}
