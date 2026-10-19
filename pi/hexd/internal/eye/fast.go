package eye

import (
	"image/color"
	"math"
	"sync"
)

// The fast path. Most of a frame repeats from the last one: the socket never
// changes, and the iris only moves around (a glance) while its colors, glow
// and size stay the same for many frames. So the socket is drawn once, and
// the iris layer is drawn once per look into a "sprite" that each frame
// places where the gaze is; per pixel only the pupil, highlights, lids and
// marks are left. A Pi 3 then draws a frame several times faster. Looks
// with a moving texture inside the iris (dizzy swirl, fury flames) take the
// reference path, shade.

const px = 2.0 / Size // one pixel in eye units

var (
	socketOnce sync.Once
	socketPix  []color.RGBA // the socket, per pixel
)

func socketCache() []color.RGBA {
	socketOnce.Do(func() {
		socketPix = make([]color.RGBA, Size*Size)
		for y := 0; y < Size; y++ {
			for x := 0; x < Size; x++ {
				u, v := (float64(x)+0.5)*px-1, (float64(y)+0.5)*px-1
				socketPix[y*Size+x] = socketAt(hyp(u, v))
			}
		}
	})
	return socketPix
}

// sprite is the iris layer around its center, as "over" blending:
// result = background*A + P (A and P per pixel, P premultiplied).
type sprite struct {
	half int // the center pixel; the sprite is 2*half+1 wide
	a    []uint8
	p    []color.RGBA
}

type spriteKey struct {
	pal   Palette
	glow  int16 // in 1/64 steps: pulses reuse a handful of sprites
	desat int16
	radiu int16 // iris radius in 1/4 pixels
}

var (
	spriteMu    sync.Mutex
	sprites     = map[spriteKey]*sprite{}
	spriteOrder []spriteKey // oldest first, for a small cache
)

const maxSprites = 24

func spriteFor(l Look, irisR float64) (*sprite, float64) {
	glow := math.Round(clamp(l.Glow, 0, 1.6)*64) / 64
	desat := math.Round(clamp(l.Desat, 0, 1)*64) / 64
	r := math.Round(irisR/px*4) / 4 * px
	key := spriteKey{l.Iris, int16(glow * 64), int16(desat * 64), int16(math.Round(r / px * 4))}
	spriteMu.Lock()
	defer spriteMu.Unlock()
	if s, ok := sprites[key]; ok {
		return s, r
	}
	s := buildSprite(l, r, glow, desat)
	sprites[key] = s
	spriteOrder = append(spriteOrder, key)
	if len(spriteOrder) > maxSprites {
		delete(sprites, spriteOrder[0])
		spriteOrder = spriteOrder[1:]
	}
	return s, r
}

func buildSprite(l Look, irisR, glow, desat float64) *sprite {
	half := int(math.Ceil((irisR+0.24)/px)) + 1
	n := 2*half + 1
	s := &sprite{half: half, a: make([]uint8, n*n), p: make([]color.RGBA, n*n)}
	look := l
	look.Glow, look.Desat, look.Swirl, look.Fire = glow, desat, -1, -1
	black, whiteBg := color.RGBA{0, 0, 0, 255}, color.RGBA{255, 255, 255, 255}
	for j := 0; j < n; j++ {
		for i := 0; i < n; i++ {
			dx, dy := float64(i-half)*px, float64(j-half)*px
			d := hyp(dx, dy)
			// The layer is linear in what is under it: drawing it over black
			// gives P, over white gives P + 255*A.
			p := irisLayer(look, black, dx, dy, d, irisR, px, glow)
			w := irisLayer(look, whiteBg, dx, dy, d, irisR, px, glow)
			a := (int(w.R) - int(p.R) + int(w.G) - int(p.G) + int(w.B) - int(p.B)) / 3
			s.a[j*n+i] = uint8(max(0, min(255, a)))
			s.p[j*n+i] = p
		}
	}
	return s
}

// over lays the sprite pixel at (sx, sy) on c (the iris sits on the pixel
// grid, so no interpolation): result = c*A + P.
func (s *sprite) over(c color.RGBA, sx, sy int) color.RGBA {
	n := 2*s.half + 1
	if sx < 0 || sy < 0 || sx >= n || sy >= n {
		return c
	}
	i := sy*n + sx
	a, p := uint32(s.a[i]), s.p[i]
	ch := func(bg, pc uint8) uint8 { // inlined by the compiler
		v := (uint32(bg)*a+127)/255 + uint32(pc)
		if v > 255 {
			v = 255
		}
		return uint8(v)
	}
	return color.RGBA{ch(c.R, p.R), ch(c.G, p.G), ch(c.B, p.B), 255}
}

// shadeFast is shade with the socket and iris layer from the caches.
func shadeFast(l Look, x, y int, u, v, cx, cy, irisR, pupilR float64, s *sprite, bg []color.RGBA) color.RGBA {
	c := bg[y*Size+x]
	dx, dy := u-cx, v-cy
	// dx, dy are whole pixels give or take rounding (snap).
	c = s.over(c, int(math.Round(dx/px))+s.half, int(math.Round(dy/px))+s.half)
	if d2 := dx*dx + dy*dy; d2 < (irisR+2*px)*(irisR+2*px) {
		c = innerIris(l, c, u, v, dx, dy, math.Sqrt(d2), cx, cy, irisR, pupilR, px, clamp(l.Glow, 0, 1.6))
	}
	r := 0.0
	if l.Ring >= 0 || l.Scanner >= 0 || l.Rec > 0 || l.Battery >= 0 || l.Dots >= 0 {
		r = hyp(u, v)
	}
	return lidsAndMarks(l, c, u, v, r, px)
}

// Same is whether two looks would draw the same picture (within what the
// eye can show): the animation eases forever toward its target, and frames
// that change nothing visible are skipped.
func Same(a, b Look) bool {
	near := func(x, y, tol float64) bool { return math.Abs(x-y) < tol }
	return a.QR == b.QR && a.Code == b.Code && a.Label == b.Label && a.Iris == b.Iris &&
		a.Heart == b.Heart && a.Locked == b.Locked &&
		near(a.X, b.X, 0.002) && near(a.Y, b.Y, 0.002) && near(a.Open, b.Open, 0.003) &&
		near(a.Smile, b.Smile, 0.003) && near(a.Frown, b.Frown, 0.003) && near(a.Sad, b.Sad, 0.003) &&
		near(a.Squint, b.Squint, 0.003) && near(a.Pupil, b.Pupil, 0.004) && near(a.Glow, b.Glow, 0.008) &&
		near(a.Rec, b.Rec, 0.01) && near(a.Ring, b.Ring, 0.002) && near(a.Dim, b.Dim, 0.004) &&
		a.Scanner == b.Scanner && near(a.IrisScale, b.IrisScale, 0.002) && a.Swirl == b.Swirl &&
		near(a.Shutter, b.Shutter, 0.004) && near(a.Flash, b.Flash, 0.004) && a.Zzz == b.Zzz &&
		a.Dots == b.Dots && near(a.Desat, b.Desat, 0.008) && a.Battery == b.Battery &&
		a.ShakeX == b.ShakeX && a.ShakeY == b.ShakeY && near(a.Hud, b.Hud, 0.004) &&
		a.HudPhase == b.HudPhase && near(a.Lock, b.Lock, 0.004) && a.Fire == b.Fire
}
