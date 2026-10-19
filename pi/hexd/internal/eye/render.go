// Package eye is the robot's cyclops eye: a 240x240 ST7789 behind a round
// 27 mm window on its face, drawn by hexd. The iris is the brand's (the
// logo's eye); lids, pupil and colors carry the robot's mood, and the same
// screen shows the boot progress and the pairing QR code.
package eye

import (
	"image"
	"image/color"
	"math"

	"rsc.io/qr"

	"github.com/wallacemartinss/hexapod/pi/hexd/internal/display"
)

// Size of the panel, in pixels.
const Size = 240

// Palette of the iris: from its bright center to its dark rim.
type Palette struct{ Center, Mid, Rim, Edge color.RGBA }

// Iris colors, one per mood family.
var (
	Cyan   = Palette{rgb(0xb9f2ff), rgb(0x3fcdf5), rgb(0x1590cc), rgb(0x0a4f86)} // the brand's eye
	Amber  = Palette{rgb(0xffe7a3), rgb(0xffb547), rgb(0xd9821c), rgb(0x7a4a0a)} // warning
	Red    = Palette{rgb(0xffc2c4), rgb(0xff5a5f), rgb(0xc8262c), rgb(0x6b0d12)} // danger
	Green  = Palette{rgb(0xc9ffe6), rgb(0x3ddc97), rgb(0x1c9e66), rgb(0x0b5233)} // happy
	Pink   = Palette{rgb(0xffd6ea), rgb(0xff6fae), rgb(0xd63384), rgb(0x6b1238)} // love
	Violet = Palette{rgb(0xe8dcff), rgb(0xa77bff), rgb(0x6f3fd6), rgb(0x2f1470)} // dizzy
)

var (
	socket = rgb(0x0c1428) // around the eye: the brand's navy
	lid    = rgb(0x1a2238) // the eyelids: the shell's dark blue-grey
	lidRim = rgb(0x2c3753)
	pupilC = rgb(0x05080f)
	white  = rgb(0xffffff)
)

func rgb(v uint32) color.RGBA {
	return color.RGBA{uint8(v >> 16), uint8(v >> 8), uint8(v), 255}
}

// Look is everything the eye shows in one frame. Coordinates are in eye
// units: -1..1 across the panel, y down.
type Look struct {
	X, Y    float64 // where the iris looks (-1..1)
	Open    float64 // upper lid: 1 wide open, 0 closed
	Smile   float64 // lower lid rising as an arc (0..1): a happy "^ ^" eye
	Frown   float64 // upper lid tilted down toward the center (0..1): angry
	Pupil   float64 // pupil scale (1 normal, <1 small, >1 wide)
	Glow    float64 // iris brightness (0..1+), for pulses
	Iris    Palette
	Rec     float64 // recording dot opacity (0..1)
	Ring    float64 // progress ring around the iris (0..1), boot; <0 off
	Label   string  // short text under the iris (boot step), "" none
	QR      string  // when set, the eye shows this QR code instead
	Code    string  // pairing code under the QR
	Dim     float64 // overall brightness (0..1), backlight-like
	Scanner float64 // 0..1 sweep angle of a "searching" arc; <0 off

	IrisScale float64 // iris size (1 normal; 0 counts as 1)
	Sad       float64 // upper lid drooping at the outer corners (0..1)
	Swirl     float64 // spiral iris turning (phase 0..1, dizzy); <0 off
	Heart     bool    // heart-shaped pupil
	Shutter   float64 // camera aperture closing over the iris (0..1)
	Flash     float64 // white flash over everything (0..1)
	Zzz       float64 // "z Z Z" floating up (phase 0..1, sleeping); <0 off
	Dots      float64 // "..." pulsing under the iris (phase 0..1, thinking); <0 off
	Desat     float64 // iris colors faded toward grey (0..1)
	Battery   float64 // small battery icon at the bottom with this charge (0..1); <0 off

	ShakeX, ShakeY float64 // the whole eye moved by this much (eye units): trembling, sneezing
	Squint         float64 // lower lid rising straight (0..1): anger, yawning
	Hud            float64 // targeting visor (0..1): red tint, reticle, scanlines
	HudPhase       float64 // reticle rotation (0..1)
	Lock           float64 // targeting brackets closing on the center (0..1)
	Locked         bool    // "LOCKED" under the reticle
	Fire           float64 // iris flickering like flames (phase 0..1, fury); <0 off
}

// Neutral is a calm, open eye looking ahead.
func Neutral() Look {
	return Look{
		Open: 1, Pupil: 1, Glow: 1, Iris: Cyan, Ring: -1, Dim: 1, Scanner: -1,
		IrisScale: 1, Swirl: -1, Zzz: -1, Dots: -1, Battery: -1, Fire: -1,
	}
}

// Render draws l into a new 240x240 image.
func Render(l Look) *image.RGBA {
	img := image.NewRGBA(image.Rect(0, 0, Size, Size))
	if l.QR != "" {
		drawQR(img, l)
		return img
	}
	const px = 2.0 / Size // one pixel in eye units
	irisR := 0.58
	if l.IrisScale > 0 {
		irisR *= l.IrisScale
	}
	cx, cy := l.X*0.30, l.Y*0.26 // the iris moves inside the socket
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
	if l.Label != "" {
		text(img, l.Label, Size/2, Size-50, 2, rgb(0x8a9cc4))
	}
	if l.Zzz >= 0 {
		drawZzz(img, l.Zzz, l.Dim)
	}
	if l.Locked {
		text(img, "LOCKED", Size/2, Size-44, 2, rgb(0xff3040))
	}
	if l.Flash > 0 {
		for i := 0; i < len(img.Pix); i += 4 {
			for k := 0; k < 3; k++ {
				img.Pix[i+k] = uint8(float64(img.Pix[i+k]) + (255-float64(img.Pix[i+k]))*clamp(l.Flash, 0, 1))
			}
		}
	}
	return img
}

// drawZzz: three z's rising up and to the right, growing and fading.
func drawZzz(img *image.RGBA, phase, dim float64) {
	for i := 0; i < 3; i++ {
		t := math.Mod(phase+float64(i)/3, 1) // each letter's own lifetime
		x := 132 + int(t*44) + i*4
		y := 120 - int(t*78)
		alpha := math.Sin(t * math.Pi) // fade in, then out
		size := 2 + int(t*3)
		textAlpha(img, "z", x, y, size, scale(rgb(0xc8d6f0), dim), alpha)
	}
}

// shade is the color of one point of the eye.
func shade(l Look, u, v, cx, cy, irisR, pupilR, px float64) color.RGBA {
	// Socket: dark navy, a little lighter in the middle.
	r := math.Hypot(u, v)
	c := mix(rgb(0x16284a), socket, smooth(0, 1, r))

	// Iris: brand gradient, two thin inner rings, a dark rim and a glow.
	dx, dy := u-cx, v-cy
	d := math.Hypot(dx, dy)
	glow := clamp(l.Glow, 0, 1.6)
	if halo := 1 - smooth(irisR, irisR+0.22, d); halo > 0 { // soft light around it
		c = mix(c, l.Iris.Mid, halo*0.28*glow)
	}
	if in := cover(irisR-d, px); in > 0 {
		t := d / irisR
		var ic color.RGBA
		switch {
		case t < 0.35:
			ic = mix(l.Iris.Center, l.Iris.Mid, t/0.35)
		case t < 0.75:
			ic = mix(l.Iris.Mid, l.Iris.Rim, (t-0.35)/0.40)
		default:
			ic = mix(l.Iris.Rim, l.Iris.Edge, (t-0.75)/0.25)
		}
		// Concentric rings, like the logo's eye.
		for _, ring := range []float64{0.62, 0.80} {
			if k := cover(px*1.1-math.Abs(t-ring)*irisR, px); k > 0 {
				ic = mix(ic, l.Iris.Rim, k*0.6)
			}
		}
		// Fury: flames flickering out from the pupil.
		if l.Fire >= 0 {
			a := math.Atan2(dy, dx)
			f := 0.5 + 0.25*math.Sin(a*7+l.Fire*2*math.Pi*3) + 0.25*math.Sin(a*13-l.Fire*2*math.Pi*5+t*9)
			ic = mix(ic, rgb(0xffd23f), smooth(0.55, 0.95, f)*(1-t)*0.9)
		}
		// Dizzy: a spiral turning inside the iris.
		if l.Swirl >= 0 {
			a := math.Atan2(dy, dx)
			stripe := 0.5 + 0.5*math.Sin(a*2+t*16-l.Swirl*2*math.Pi)
			ic = mix(ic, l.Iris.Edge, smooth(0.45, 0.75, stripe)*0.85)
		}
		if l.Desat > 0 {
			g := uint8(0.3*float64(ic.R) + 0.59*float64(ic.G) + 0.11*float64(ic.B))
			ic = mix(ic, color.RGBA{g, g, g, 255}, l.Desat)
		}
		ic = scale(ic, 0.55+0.45*math.Min(glow, 1)+0.25*math.Max(glow-1, 0))
		c = mix(c, ic, in)
		// Dark rim line.
		if k := cover(px*1.6-math.Abs(d-irisR), px); k > 0 {
			c = mix(c, l.Iris.Edge, k*0.9)
		}
	}
	// Pupil, slightly toward the gaze.
	pdx, pdy := u-(cx+l.X*0.03), v-(cy+l.Y*0.03)
	if l.Heart {
		if in := heart(pdx, pdy, pupilR*1.25, px); in > 0 {
			c = mix(c, pupilC, in)
		}
	} else if in := cover(pupilR-math.Hypot(pdx, pdy), px); in > 0 {
		c = mix(c, pupilC, in)
	}
	// Photo: six aperture blades close over the iris, like a camera.
	if l.Shutter > 0 && d < irisR+px {
		open := irisR * (1 - clamp(l.Shutter, 0, 1))
		rot := l.Shutter * math.Pi / 3
		if hexDist(dx, dy, rot) > open {
			blade := mix(rgb(0x1b2233), rgb(0x2c3753), 0.5+0.5*math.Sin(math.Atan2(dy, dx)*6+rot*6))
			c = mix(c, blade, cover(irisR-d, px))
		}
	}
	// Highlights: a big soft one up-left and a small dot down-right.
	if k := cover(1-math.Hypot((dx+irisR*0.38)/(irisR*0.26), (dy+irisR*0.40)/(irisR*0.17)), px*4); k > 0 {
		c = mix(c, white, k*0.85*math.Min(glow, 1))
	}
	if k := cover(irisR*0.07-math.Hypot(dx-irisR*0.30, dy-irisR*0.28), px); k > 0 {
		c = mix(c, white, k*0.75)
	}

	// Recording: a red dot at the iris' upper right, pulsing.
	if l.Rec > 0 {
		if k := cover(0.075-math.Hypot(u-0.56, v+0.56), px); k > 0 {
			c = mix(c, rgb(0xff3b41), k*l.Rec)
		}
	}
	// Boot progress: an arc around the iris, clockwise from the top.
	if l.Ring >= 0 {
		if k := cover(px*2.4-math.Abs(r-0.88), px); k > 0 {
			a := math.Mod(math.Atan2(u, -v)/(2*math.Pi)+1, 1)
			on := a <= l.Ring
			col := rgb(0x24304d)
			if on {
				col = l.Iris.Mid
			}
			c = mix(c, col, k)
		}
	}
	// Searching: a short arc sweeping around the socket.
	if l.Scanner >= 0 {
		if k := cover(px*2-math.Abs(r-0.86), px); k > 0 {
			a := math.Mod(math.Atan2(u, -v)/(2*math.Pi)+1-l.Scanner+1, 1)
			if a < 0.12 {
				c = mix(c, l.Iris.Mid, k*(1-a/0.12))
			}
		}
	}

	// Thinking: three dots under the iris, lighting up in turn.
	if l.Dots >= 0 {
		for i := 0; i < 3; i++ {
			on := 0.35 + 0.65*math.Max(0, math.Sin((l.Dots-float64(i)/3)*2*math.Pi))
			if k := cover(0.045-math.Hypot(u-(-0.16+0.16*float64(i)), v-0.74), px); k > 0 {
				c = mix(c, scale(rgb(0xc8d6f0), on), k)
			}
		}
	}
	// Tired: a small battery at the bottom, its charge in red.
	if l.Battery >= 0 {
		bx, by := u, v-0.78
		body := math.Max(math.Abs(bx)-0.13, math.Abs(by)-0.065) // box distance
		if k := cover(px*1.4-math.Abs(body), px); k > 0 {
			c = mix(c, rgb(0xc8d6f0), k)
		}
		if k := cover(-math.Max(math.Abs(bx-0.155)-0.018, math.Abs(by)-0.03), px); k > 0 {
			c = mix(c, rgb(0xc8d6f0), k) // the terminal
		}
		fill := -0.11 + 0.22*clamp(l.Battery, 0, 1)
		if k := cover(-math.Max(math.Max(-0.11-bx, bx-fill), math.Abs(by)-0.045), px); k > 0 {
			c = mix(c, rgb(0xff5a5f), k)
		}
	}

	// Upper lid: an ellipse edge that comes down as Open drops; with Frown
	// it slopes down toward the middle (angry).
	open := clamp(l.Open, 0, 1)
	edge := -1.15 + 2.05*(1-open)              // lid edge at the center: above the window when open
	edge += l.Frown * 0.75 * (1 - math.Abs(u)) // lower in the middle
	edge -= 0.18 * u * u                       // curved like a lid
	edge += l.Sad * 0.7 * math.Abs(u)          // sad: drooping at the outer corners
	if k := cover(edge-v, px*1.5); k > 0 {
		lc := mix(lid, lidRim, smooth(edge-0.10, edge, v)) // rim catches light
		c = mix(c, lc, k)
	}
	// Lower lid rising straight (anger, yawning): a flat edge, a bit curved.
	if l.Squint > 0 {
		low := 1.15 - 1.35*l.Squint - 0.10*u*u
		if k := cover(v-low, px*1.5); k > 0 {
			c = mix(c, lid, k)
		}
	}
	// Lower lid for a smile: an arc rising from below.
	if l.Smile > 0 {
		low := 1.15 - 1.25*l.Smile + 0.55*u*u
		if k := cover(v-low, px*1.5); k > 0 {
			c = mix(c, lid, k)
		}
	}
	return c
}

// drawQR fills the window with the pairing QR code (dark on white, as
// phone scanners expect) and the short code under it.
func drawQR(img *image.RGBA, l Look) {
	for y := 0; y < Size; y++ {
		for x := 0; x < Size; x++ {
			img.SetRGBA(x, y, socket)
		}
	}
	code, err := qr.Encode(l.QR, qr.M)
	if err != nil {
		return
	}
	// The 27 mm round window shows a ~19 mm square in full: about 160 px.
	mod := 140 / (code.Size + 2)
	side := (code.Size + 2) * mod
	x0 := (Size - side) / 2
	y0 := 28 // every corner inside the window, the code below too
	for y := 0; y < side; y++ {
		for x := 0; x < side; x++ {
			mx, my := x/mod-1, y/mod-1
			dark := mx >= 0 && my >= 0 && mx < code.Size && my < code.Size && code.Black(mx, my)
			col := white
			if dark {
				col = pupilC
			}
			img.SetRGBA(x0+x, y0+y, col)
		}
	}
	if l.Code != "" {
		text(img, l.Code, Size/2, y0+side+10, 4, white)
	}
}

// text draws s centered on x, from y down, with the OLED's 5x7 font at
// the given scale.
func text(img *image.RGBA, s string, x, y, scale int, c color.RGBA) {
	runes := []rune(s)
	w := len(runes)*6*scale - scale
	left := x - w/2
	for i, r := range runes {
		g := display.Glyph(r)
		for col := 0; col < 5; col++ {
			for row := 0; row < 8; row++ {
				if g[col]&(1<<row) == 0 {
					continue
				}
				for dy := 0; dy < scale; dy++ {
					for dx := 0; dx < scale; dx++ {
						px, py := left+(i*6+col)*scale+dx, y+row*scale+dy
						if image.Pt(px, py).In(img.Rect) {
							img.SetRGBA(px, py, c)
						}
					}
				}
			}
		}
	}
}

// cover turns a signed distance (positive inside) into pixel coverage.
func cover(d, px float64) float64 { return clamp(d/px+0.5, 0, 1) }

func smooth(a, b, x float64) float64 {
	t := clamp((x-a)/(b-a), 0, 1)
	return t * t * (3 - 2*t)
}

func clamp(x, lo, hi float64) float64 { return math.Max(lo, math.Min(hi, x)) }

func mix(a, b color.RGBA, t float64) color.RGBA {
	t = clamp(t, 0, 1)
	f := func(x, y uint8) uint8 { return uint8(float64(x) + (float64(y)-float64(x))*t + 0.5) }
	return color.RGBA{f(a.R, b.R), f(a.G, b.G), f(a.B, b.B), 255}
}

func scale(c color.RGBA, k float64) color.RGBA {
	f := func(x uint8) uint8 { return uint8(clamp(float64(x)*k, 0, 255) + 0.5) }
	return color.RGBA{f(c.R), f(c.G), f(c.B), 255}
}

// heart is the coverage of a heart shape of size s centered at (x, y)
// (2x2 supersampled: the implicit curve is not a distance).
func heart(x, y, s, px float64) float64 {
	in := 0.0
	for _, o := range [][2]float64{{-0.25, -0.25}, {0.25, -0.25}, {-0.25, 0.25}, {0.25, 0.25}} {
		hx := (x + o[0]*px) / s
		hy := -(y+o[1]*px)/s + 0.25
		f := hx*hx + hy*hy - 1
		if f*f*f-hx*hx*hy*hy*hy <= 0 {
			in += 0.25
		}
	}
	return in
}

// hexDist is the distance from the center to a regular hexagon's edge
// along (x, y), rotated by rot: the aperture's opening.
func hexDist(x, y, rot float64) float64 {
	a := math.Atan2(y, x) - rot
	seg := math.Mod(a+math.Pi/6+8*math.Pi, math.Pi/3) - math.Pi/6
	return math.Hypot(x, y) * math.Cos(seg)
}

// textAlpha is text blended over what is there.
func textAlpha(img *image.RGBA, s string, x, y, scl int, c color.RGBA, alpha float64) {
	if alpha <= 0 {
		return
	}
	runes := []rune(s)
	left := x - (len(runes)*6*scl-scl)/2
	for i, r := range runes {
		g := display.Glyph(r)
		for col := 0; col < 5; col++ {
			for row := 0; row < 8; row++ {
				if g[col]&(1<<row) == 0 {
					continue
				}
				for dy := 0; dy < scl; dy++ {
					for dx := 0; dx < scl; dx++ {
						p := image.Pt(left+(i*6+col)*scl+dx, y+row*scl+dy)
						if p.In(img.Rect) {
							img.SetRGBA(p.X, p.Y, mix(img.RGBAAt(p.X, p.Y), c, alpha))
						}
					}
				}
			}
		}
	}
}

// hud turns the eye into a targeting visor: red monochrome, scanlines, a
// rotating segmented ring, ticks, a crosshair and corner brackets.
func hud(l Look, c color.RGBA, u, v float64, row int, px float64) color.RGBA {
	k := clamp(l.Hud, 0, 1)
	lum := (0.3*float64(c.R) + 0.59*float64(c.G) + 0.11*float64(c.B)) / 255
	red := color.RGBA{uint8(clamp(lum*1.35, 0, 1) * 255), uint8(lum * 0.18 * 255), uint8(lum * 0.2 * 255), 255}
	c = mix(c, red, k)
	if row%3 == 0 { // scanlines
		c = scale(c, 1-0.22*k)
	}
	line := rgb(0xff3040)
	r := math.Hypot(u, v)
	a := math.Atan2(v, u)
	turn := l.HudPhase * 2 * math.Pi
	// Segmented outer ring, turning.
	if w := cover(px*1.6-math.Abs(r-0.80), px); w > 0 {
		seg := math.Mod((a+turn)/(2*math.Pi)*12+24, 1)
		if seg < 0.62 {
			c = mix(c, line, w*k)
		}
	}
	// Ticks, turning the other way.
	if r > 0.66 && r < 0.71 {
		tick := math.Mod((a-turn*0.5)/(2*math.Pi)*36+72, 1)
		if w := cover(px*0.9-math.Abs(tick-0.5)*0.17, px); w > 0 {
			c = mix(c, line, w*k*0.8)
		}
	}
	// Crosshair, with a gap around the pupil.
	if r > 0.16 && r < 0.52 {
		if w := cover(px*0.9-math.Min(math.Abs(u), math.Abs(v)), px); w > 0 {
			c = mix(c, line, w*k*0.9)
		}
	}
	// Corner brackets closing in on the center.
	b := 0.88 - 0.42*clamp(l.Lock, 0, 1)
	ax, ay := math.Abs(u), math.Abs(v)
	onX := math.Abs(ax-b) < px*1.4 && ay > b-0.16 && ay < b+px
	onY := math.Abs(ay-b) < px*1.4 && ax > b-0.16 && ax < b+px
	if onX || onY {
		c = mix(c, line, k)
	}
	// A bright dot at the very center: the aim.
	if w := cover(0.03-r, px); w > 0 {
		c = mix(c, rgb(0xffb0b4), w*k)
	}
	return c
}
