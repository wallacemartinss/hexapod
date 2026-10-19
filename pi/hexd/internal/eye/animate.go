package eye

import (
	"math"
	"math/rand/v2"
	"time"
)

// Mood is what the robot "feels", from its state.
type Mood int

const (
	Ready     Mood = iota // standing or walking, all well: calm, curious
	Relaxed               // servos off or sitting: sleepy, half-closed
	Alert                 // stopping, safe sit, obstacle: amber, wide awake
	Danger                // emergency stop, tipped, battery critical: red, frowning
	Gas                   // gas or smoke: amber pulsing
	Happy                 // a gesture, just paired: green "^ ^" smile
	Searching             // no app connected: looks around, scanning
	Sleeping              // shutting down: closes
	Dizzy                 // tipped over: spiral iris, eye rolling around
	Dozing                // relaxed for a long while: closed, "z Z Z"
	Love                  // just paired (and, later, petted): pink, heart pupil
	Surprised             // a sudden obstacle, a push: wide open, tiny pupil
	Sad                   // the app's signal was lost: droopy, looking down
	Thinking              // connecting, switching Wi-Fi, updating: looks up, "..."
	Tired                 // battery low: sleepy, faded, battery icon
	Furious               // really angry: fiery red, squeezed lids, trembling
	Scared                // almost tipping: wide, tiny shaking pupil, darting
	Bored                 // nothing to do for a while: droopy, looks away, yawns
	Hunter                // "eliminate target": red targeting visor locking on
)

// Inputs drive the animation; hexd fills them from the robot's state.
type Inputs struct {
	Mood       Mood
	LookX      float64 // where the pilot steers (-1..1): the eye follows
	LookY      float64
	Steering   bool    // the pilot is moving the sticks
	Recording  bool    // the camera is recording
	Boot       float64 // boot progress (0..1); <0 when booted
	BootLabel  string  // boot step under the iris
	PairQR     string  // pairing QR (no app paired and none connected)
	PairCode   string  // the short code under it
	Brightness float64 // 0..1 (0 = default 1)
	Battery    float64 // charge 0..1 for the tired battery icon

	// One-shot events: bump the number to play it once.
	Wink   int // a happy "^" for a moment (a wave gesture)
	Photo  int // the aperture closes and opens, with a flash (photo taken)
	Sneeze int // squeezing, trembling... "achoo!" (gas detected)
}

// Animator turns Inputs into a Look, frame by frame: blinks, glances
// around, follows the sticks, eases between moods. Not safe for
// concurrent use (one goroutine renders).
type Animator struct {
	rng   *rand.Rand
	t     float64 // seconds since start
	look  Look    // eased state
	gaze  [2]float64
	next  float64 // when to glance somewhere else
	blink float64 // when the next blink starts

	wink, photo, sneeze      int     // last event numbers seen
	winkAt, photoAt, sneezAt float64 // when they started (-1: none)
	yawnAt                   float64 // next yawn (bored)
	lockFrom                 float64 // start of the current lock-on (hunter)
}

// NewAnimator starts with a neutral, open eye.
func NewAnimator(seed uint64) *Animator {
	a := &Animator{rng: rand.New(rand.NewPCG(seed, seed^0x9e3779b97f4a7c15)), look: Neutral(), winkAt: -1, photoAt: -1, sneezAt: -1, yawnAt: 6}
	a.blink = 2 + a.rng.Float64()*3
	return a
}

// blinkDuration: down and up again.
const blinkDuration = 0.20

// Step advances by dt and returns the frame to draw.
func (a *Animator) Step(dt time.Duration, in Inputs) Look {
	s := dt.Seconds()
	a.t += s
	target := moodLook(in.Mood)

	// Where to look: the sticks win; otherwise small glances, wider while
	// searching, none while sleeping.
	switch {
	case in.Mood == Dizzy:
		a.gaze = [2]float64{0.7 * math.Cos(a.t*5), 0.55 * math.Sin(a.t*5)}
	case in.Mood == Thinking:
		a.gaze = [2]float64{-0.55 + 0.08*math.Sin(a.t*0.9), -0.75}
	case in.Mood == Sad:
		a.gaze = [2]float64{0.15 * math.Sin(a.t*0.4), 0.65}
	case in.Mood == Dozing:
		a.gaze = [2]float64{0, 0.2}
	case in.Mood == Bored:
		a.gaze = [2]float64{0.62 + 0.1*math.Sin(a.t*0.3), 0.3}
	case in.Mood == Hunter:
		if a.t-a.lockFrom > 4 { // next target
			a.lockFrom = a.t
			a.gaze = [2]float64{(a.rng.Float64()*2 - 1) * 0.7, (a.rng.Float64()*2 - 1) * 0.45}
		}
	case in.Mood == Scared && a.t >= a.next:
		a.gaze = [2]float64{(a.rng.Float64()*2 - 1) * 0.85, (a.rng.Float64()*2 - 1) * 0.4}
		a.next = a.t + 0.25 + a.rng.Float64()*0.35
	case in.Steering:
		a.gaze = [2]float64{clamp(in.LookX, -1, 1), clamp(in.LookY, -1, 1)}
		a.next = a.t + 1.5
	case a.t >= a.next && in.Mood != Sleeping:
		reach := 0.45
		if in.Mood == Searching {
			reach = 0.95
		}
		if in.Mood == Relaxed {
			reach = 0.25
		}
		a.gaze = [2]float64{(a.rng.Float64()*2 - 1) * reach, (a.rng.Float64()*2 - 1) * reach * 0.6}
		if a.rng.Float64() < 0.35 {
			a.gaze = [2]float64{0, 0} // back to the pilot
		}
		a.next = a.t + 1.2 + a.rng.Float64()*2.8
		if in.Mood == Searching {
			a.next = a.t + 0.8 + a.rng.Float64()*1.2
		}
	}
	target.X, target.Y = a.gaze[0], a.gaze[1]

	// Pulses.
	switch in.Mood {
	case Gas:
		target.Glow = 0.85 + 0.45*(0.5+0.5*math.Sin(a.t*2*math.Pi*1.4))
	case Danger:
		target.Glow = 0.95 + 0.25*(0.5+0.5*math.Sin(a.t*2*math.Pi*0.8))
	case Searching:
		target.Scanner = math.Mod(a.t*0.45, 1)
	case Love: // heartbeat: two quick beats, a pause
		beat := math.Mod(a.t, 1.1)
		target.Pupil = 1.25 + 0.25*(pulse(beat, 0.08)+0.7*pulse(beat, 0.32))
		target.Glow = 1 + 0.2*pulse(beat, 0.08)
	}
	target.Swirl, target.Zzz, target.Dots, target.Fire = -1, -1, -1, -1
	tremble := 0.0
	switch in.Mood {
	case Furious:
		target.Fire = math.Mod(a.t*0.5, 1)
		target.Glow = 1.1 + 0.25*(0.5+0.5*math.Sin(a.t*2*math.Pi*1.8))
		tremble = 0.010
	case Scared:
		tremble = 0.007
	case Hunter:
		lt := a.t - a.lockFrom
		target.HudPhase = math.Mod(a.t*0.12, 1)
		target.Lock = smooth(0.2, 1.6, lt) * (1 - smooth(3.3, 3.9, lt))
		target.Locked = lt > 1.6 && lt < 3.3 && math.Mod(lt, 0.5) < 0.3
	case Dizzy:
		target.Swirl = math.Mod(a.t*0.8, 1)
	case Dozing:
		target.Zzz = math.Mod(a.t*0.35, 1)
	case Thinking:
		target.Dots = math.Mod(a.t*1.2, 1)
	case Tired:
		target.Battery = clamp(in.Battery, 0, 1)
	}
	if in.Recording {
		target.Rec = 0.55 + 0.45*(0.5+0.5*math.Sin(a.t*2*math.Pi*0.9))
	}

	// Ease toward the target (critically damped feel): saccades fast, the
	// rest gentler.
	ease := func(cur, want, rate float64) float64 { return cur + (want-cur)*(1-math.Exp(-rate*s)) }
	l := a.look
	l.X, l.Y = ease(l.X, target.X, 14), ease(l.Y, target.Y, 14)
	l.Open = ease(l.Open, target.Open, 6)
	l.Smile = ease(l.Smile, target.Smile, 7)
	l.Frown = ease(l.Frown, target.Frown, 7)
	l.Pupil = ease(l.Pupil, target.Pupil, 5)
	l.Glow = ease(l.Glow, target.Glow, 8)
	l.Iris = mixPalette(l.Iris, target.Iris, 1-math.Exp(-5*s))
	l.Rec = ease(l.Rec, target.Rec, 10)
	l.Scanner = target.Scanner
	l.IrisScale = ease(l.IrisScale, target.IrisScale, 9)
	l.Sad = ease(l.Sad, target.Sad, 6)
	l.Desat = ease(l.Desat, target.Desat, 4)
	l.Swirl, l.Zzz, l.Dots, l.Battery = target.Swirl, target.Zzz, target.Dots, target.Battery
	l.Heart = target.Heart
	l.Squint = ease(l.Squint, target.Squint, 6)
	l.Hud = ease(l.Hud, target.Hud, 5)
	l.HudPhase, l.Lock, l.Locked, l.Fire = target.HudPhase, target.Lock, target.Locked, target.Fire
	l.Dim = ease(l.Dim, target.Dim, 4)
	a.look = l

	// Blink on top (not stored: the eased lid stays where it was).
	out := l
	busy := a.sneezAt >= 0 || (in.Mood == Bored && a.t >= a.yawnAt && a.t < a.yawnAt+2.4)
	if busy && a.t >= a.blink {
		a.blink = a.t + 1 // no blink in the middle of a yawn or a sneeze
	}
	if in.Mood != Sleeping && in.Mood != Dozing && a.t >= a.blink {
		dur := blinkDuration
		if in.Mood == Tired {
			dur = blinkDuration * 2.5 // heavy lids
		}
		p := (a.t - a.blink) / dur
		if p >= 1 {
			a.blink = a.t + 2.5 + a.rng.Float64()*3.5
			if a.rng.Float64() < 0.15 {
				a.blink = a.t + 0.3 // a double blink now and then
			}
		} else {
			out.Open = l.Open * math.Abs(1-2*p)
		}
	}
	// Trembling: a small random jitter every frame.
	if tremble > 0 {
		out.ShakeX = (a.rng.Float64()*2 - 1) * tremble
		out.ShakeY = (a.rng.Float64()*2 - 1) * tremble
	}
	// Bored: a big yawn now and then.
	if in.Mood == Bored {
		if a.t >= a.yawnAt+2.4 {
			a.yawnAt = a.t + 5 + a.rng.Float64()*4
		}
		if p := (a.t - a.yawnAt) / 2.4; p >= 0 && p < 1 {
			k := math.Sin(p * math.Pi)
			out.Open *= 1 - 0.55*k // a long squeeze, a slit left open
			out.Squint = math.Max(out.Squint, 0.30*k)
			out.Y += 0.3 * k
		}
	}
	// One-shot events on top.
	if in.Wink != a.wink {
		a.wink, a.winkAt = in.Wink, a.t
	}
	if in.Photo != a.photo {
		a.photo, a.photoAt = in.Photo, a.t
	}
	if a.winkAt >= 0 {
		p := (a.t - a.winkAt) / 0.7
		if p >= 1 {
			a.winkAt = -1
		} else {
			k := math.Sin(p * math.Pi)              // in and out
			out.Open = out.Open * (1 - 0.3*k)       // the upper lid barely moves
			out.Smile = math.Max(out.Smile, 1.05*k) // the lower one rises: "^"
		}
	}
	if in.Sneeze != a.sneeze {
		a.sneeze, a.sneezAt = in.Sneeze, a.t
	}
	if a.sneezAt >= 0 {
		t := a.t - a.sneezAt
		switch {
		case t < 1.2: // building up: squeezing, trembling more and more
			k := t / 1.2
			out.Open *= 1 - 0.45*k
			out.Squint = math.Max(out.Squint, 0.28*k)
			out.Pupil *= 1 - 0.3*k
			out.ShakeX += (a.rng.Float64()*2 - 1) * 0.012 * k
			out.ShakeY += (a.rng.Float64()*2 - 1) * 0.012 * k
		case t < 1.5: // achoo! shut, the whole eye jolts
			k := 1 - (t-1.2)/0.3
			out.Open, out.Squint = 0, 0.5
			out.ShakeX += (a.rng.Float64()*2 - 1) * 0.07 * k
			out.ShakeY += 0.06 * k
			out.Flash = math.Max(out.Flash, 0.25*k)
		case t < 2.1: // back
			k := (t - 1.5) / 0.6
			out.Open *= k
			out.Squint = math.Max(out.Squint, 0.5*(1-k))
		default:
			a.sneezAt = -1
		}
	}
	if a.photoAt >= 0 {
		p := (a.t - a.photoAt) / 0.45
		if p >= 1 {
			a.photoAt = -1
		} else {
			out.Shutter = math.Sin(p * math.Pi)
			out.Flash = 0.6 * pulse(p, 0.5) // a quick flash when the aperture is shut
		}
	}
	if in.Brightness > 0 {
		out.Dim *= in.Brightness
	}

	// Screens that are not the eye.
	switch {
	case in.PairQR != "":
		out = Look{QR: in.PairQR, Code: in.PairCode, Dim: 1, Ring: -1, Scanner: -1}
	case in.Boot >= 0 && in.Boot < 1:
		out.Ring, out.Label = in.Boot, in.BootLabel
	}
	return out
}

// moodLook is the resting look of each mood.
func moodLook(m Mood) Look {
	l := Neutral()
	switch m {
	case Relaxed:
		l.Open, l.Pupil, l.Glow, l.Dim = 0.48, 1.15, 0.75, 0.85
	case Alert:
		l.Iris, l.Pupil, l.Open = Amber, 0.75, 1
	case Danger:
		l.Iris, l.Pupil, l.Frown, l.Open = Red, 0.65, 0.8, 0.9
	case Gas:
		l.Iris, l.Pupil = Amber, 0.7
	case Happy:
		l.Iris, l.Smile, l.Pupil, l.Open = Green, 0.75, 1.2, 1
	case Searching:
		l.Glow, l.Pupil, l.Dim = 0.85, 1.05, 0.9
	case Sleeping:
		l.Open, l.Glow, l.Dim = 0, 0.4, 0.5
	case Dizzy:
		l.Iris, l.Pupil, l.Open = Violet, 0.55, 0.95
	case Dozing:
		l.Open, l.Glow, l.Dim = 0, 0.5, 0.75
	case Love:
		l.Iris, l.Heart, l.Pupil, l.Smile = Pink, true, 1.3, 0.3
	case Surprised:
		l.IrisScale, l.Pupil, l.Open, l.Glow = 1.14, 0.42, 1, 1.15
	case Sad:
		l.Sad, l.Open, l.Desat, l.Dim, l.Pupil = 0.9, 0.78, 0.45, 0.85, 1.1
	case Thinking:
		l.Pupil, l.Open = 0.9, 0.92
	case Tired:
		l.Open, l.Desat, l.Dim, l.Pupil, l.Glow = 0.45, 0.55, 0.75, 1.1, 0.8
	case Furious:
		l.Iris, l.Frown, l.Squint, l.Pupil, l.Open = Red, 1.15, 0.36, 0.5, 0.95
	case Scared:
		l.IrisScale, l.Pupil, l.Sad, l.Desat, l.Open = 0.92, 0.32, 0.35, 0.35, 1
	case Bored:
		l.Open, l.Pupil, l.Desat, l.Glow = 0.55, 1.05, 0.25, 0.85
	case Hunter:
		l.Iris, l.Hud, l.Pupil, l.Frown, l.Open = Red, 1, 0.5, 0.35, 0.9
	}
	return l
}

// pulse is a short bump around center c of a 0..1 (or 0..period) clock.
func pulse(t, c float64) float64 {
	d := (t - c) / 0.06
	return math.Exp(-d * d)
}

func mixPalette(a, b Palette, t float64) Palette {
	return Palette{mix(a.Center, b.Center, t), mix(a.Mid, b.Mid, t), mix(a.Rim, b.Rim, t), mix(a.Edge, b.Edge, t)}
}
