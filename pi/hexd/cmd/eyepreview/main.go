// eyepreview renders the cyclops eye's expressions and animations as they
// will look behind the robot's 27 mm round window, without the hardware:
//
//	go run ./hexd/cmd/eyepreview -out ../docs/eye   (from pi/)
//
// It writes moods.png (every expression side by side), one PNG per mood,
// and, when ffmpeg is installed, animated GIF and MP4 clips.
package main

import (
	"flag"
	"fmt"
	"image"
	"image/color"
	"image/draw"
	"image/png"
	"log"
	"math"
	"os"
	"os/exec"
	"path/filepath"
	"time"

	"github.com/wallacemartinss/hexapod/pi/hexd/internal/display"
	"github.com/wallacemartinss/hexapod/pi/hexd/internal/eye"
)

// The face around the window: the panel is 240 px for 27.7 mm, so the
// 27 mm window is a circle of ~117 px radius.
const (
	face    = 300
	windowR = 117.0
)

func main() {
	out := flag.String("out", "eye-preview", "output folder")
	flag.Parse()
	if err := os.MkdirAll(*out, 0o755); err != nil {
		log.Fatal(err)
	}

	stills := []struct {
		name, label string
		in          eye.Inputs
	}{
		{"ready", "Ready / Pronto", eye.Inputs{Mood: eye.Ready, Boot: -1}},
		{"steer-left", "Steering / Manobrando", eye.Inputs{Mood: eye.Ready, Steering: true, LookX: -1, LookY: 0.2, Boot: -1}},
		{"relaxed", "Relaxed / Relaxado", eye.Inputs{Mood: eye.Relaxed, Boot: -1}},
		{"alert", "Alert / Alerta", eye.Inputs{Mood: eye.Alert, Boot: -1}},
		{"danger", "Stop / Parado", eye.Inputs{Mood: eye.Danger, Boot: -1}},
		{"gas", "Gas / Gás", eye.Inputs{Mood: eye.Gas, Boot: -1}},
		{"happy", "Happy / Feliz", eye.Inputs{Mood: eye.Happy, Boot: -1}},
		{"searching", "No app / Sem app", eye.Inputs{Mood: eye.Searching, Boot: -1}},
		{"recording", "Recording / Gravando", eye.Inputs{Mood: eye.Ready, Recording: true, Boot: -1}},
		{"boot", "Booting / Iniciando", eye.Inputs{Mood: eye.Ready, Boot: 0.62, BootLabel: "ESP32"}},
		{"pairing", "Pairing / Pareando", eye.Inputs{Mood: eye.Ready, Boot: -1, PairQR: "HXP2 K7F2 Q8M3D", PairCode: "Q8M3D"}},
		{"sleeping", "Off / Desligando", eye.Inputs{Mood: eye.Sleeping, Boot: -1}},
		{"dizzy", "Dizzy / Tonto", eye.Inputs{Mood: eye.Dizzy, Boot: -1}},
		{"dozing", "Dozing / Dormindo", eye.Inputs{Mood: eye.Dozing, Boot: -1}},
		{"love", "Love / Apaixonado", eye.Inputs{Mood: eye.Love, Boot: -1}},
		{"surprised", "Surprised / Surpreso", eye.Inputs{Mood: eye.Surprised, Boot: -1}},
		{"sad", "Sad / Triste", eye.Inputs{Mood: eye.Sad, Boot: -1}},
		{"thinking", "Thinking / Pensando", eye.Inputs{Mood: eye.Thinking, Boot: -1}},
		{"tired", "Tired / Cansado", eye.Inputs{Mood: eye.Tired, Battery: 0.15, Boot: -1}},
		{"wink", "Wink / Piscadinha", eye.Inputs{Mood: eye.Ready, Wink: 1, Boot: -1}},
		{"photo", "Photo / Foto", eye.Inputs{Mood: eye.Ready, Photo: 1, Boot: -1}},
		{"furious", "Furious / Bravo", eye.Inputs{Mood: eye.Furious, Boot: -1}},
		{"scared", "Scared / Assustado", eye.Inputs{Mood: eye.Scared, Boot: -1}},
		{"bored", "Yawning / Bocejando", eye.Inputs{Mood: eye.Bored, Boot: -1}},
		{"hunter", "Target / Alvo", eye.Inputs{Mood: eye.Hunter, Boot: -1}},
		{"sneeze", "Achoo / Atchim", eye.Inputs{Mood: eye.Ready, Sneeze: 1, Boot: -1}},
	}
	var tiles []*image.RGBA
	for _, s := range stills {
		// Let the eye settle into the mood, then take a frame between blinks.
		a := eye.NewAnimator(7)
		var l eye.Look
		settle := s.in
		settle.Wink, settle.Photo, settle.Sneeze = 0, 0, 0
		frames := 90
		switch s.in.Mood {
		case eye.Bored:
			frames = 6*60 + 40 // into the first yawn
		case eye.Hunter:
			frames = 123 // locked on
		}
		for i := 0; i < frames; i++ {
			l = a.Step(time.Second/60, settle)
		}
		if s.in.Mood != eye.Bored {
			l.Open = settledOpen(s.in.Mood) // never caught mid-blink
		}
		if s.in.Wink > 0 || s.in.Photo > 0 || s.in.Sneeze > 0 { // the event at its peak
			steps := 21 // the wink at its peak
			if s.in.Photo > 0 {
				steps = 9 // the aperture nearly shut, before the flash
			}
			if s.in.Sneeze > 0 {
				steps = 70 // squeezed, right before the "achoo"
			}
			for i := 0; i < steps; i++ {
				l = a.Step(time.Second/60, s.in)
			}
		}
		if s.in.Steering {
			l.X, l.Y = s.in.LookX, s.in.LookY
		} else if s.in.PairQR == "" && s.in.Mood != eye.Hunter && s.in.Mood != eye.Bored {
			l.X, l.Y = 0.15, -0.05
		}
		if s.in.Mood == eye.Searching {
			l.X, l.Y, l.Scanner = 0.7, -0.2, 0.3
		}
		switch s.in.Mood { // the mood's own gaze
		case eye.Thinking:
			l.X, l.Y = -0.55, -0.75
		case eye.Sad:
			l.X, l.Y = 0.05, 0.65
		case eye.Dizzy:
			l.X, l.Y = 0.5, 0.35
		}
		tile := withLabel(faceOf(eye.Render(l)), s.label)
		tiles = append(tiles, tile)
		save(filepath.Join(*out, s.name+".png"), tile)
	}
	save(filepath.Join(*out, "moods.png"), grid(tiles, 4))

	// Clips: 30 fps, frames into a temp folder, then ffmpeg.
	clips := []struct {
		name string
		secs float64
		in   func(t float64) eye.Inputs
	}{
		{"idle", 8, func(float64) eye.Inputs { return eye.Inputs{Mood: eye.Ready, Boot: -1} }},
		{"steer", 6, func(t float64) eye.Inputs {
			a := t * 2 * math.Pi / 3
			return eye.Inputs{Mood: eye.Ready, Steering: true, LookX: math.Cos(a), LookY: 0.6 * math.Sin(a), Boot: -1}
		}},
		{"moods", 38, func(t float64) eye.Inputs {
			seq := []eye.Mood{eye.Ready, eye.Happy, eye.Love, eye.Surprised, eye.Alert, eye.Danger, eye.Dizzy,
				eye.Furious, eye.Scared, eye.Gas, eye.Sad, eye.Thinking, eye.Tired, eye.Bored, eye.Relaxed,
				eye.Dozing, eye.Searching, eye.Hunter, eye.Ready}
			return eye.Inputs{Mood: seq[int(t/2)%len(seq)], Boot: -1}
		}},
		{"boot", 5, func(t float64) eye.Inputs {
			steps := []string{"SISTEMA", "REDE", "ESP32", "PONTE"}
			p := math.Min(t/4.2, 1)
			if p >= 1 {
				return eye.Inputs{Mood: eye.Happy, Boot: -1}
			}
			return eye.Inputs{Mood: eye.Ready, Boot: p, BootLabel: steps[min(int(p*4), 3)]}
		}},
		{"recording", 5, func(float64) eye.Inputs { return eye.Inputs{Mood: eye.Ready, Recording: true, Boot: -1} }},
		{"dizzy", 5, func(float64) eye.Inputs { return eye.Inputs{Mood: eye.Dizzy, Boot: -1} }},
		{"dozing", 6, func(float64) eye.Inputs { return eye.Inputs{Mood: eye.Dozing, Boot: -1} }},
		{"love", 5, func(float64) eye.Inputs { return eye.Inputs{Mood: eye.Love, Boot: -1} }},
		{"thinking", 5, func(float64) eye.Inputs { return eye.Inputs{Mood: eye.Thinking, Boot: -1} }},
		{"furious", 4, func(float64) eye.Inputs { return eye.Inputs{Mood: eye.Furious, Boot: -1} }},
		{"scared", 4, func(float64) eye.Inputs { return eye.Inputs{Mood: eye.Scared, Boot: -1} }},
		{"bored", 10, func(float64) eye.Inputs { return eye.Inputs{Mood: eye.Bored, Boot: -1} }},
		{"hunter", 9, func(float64) eye.Inputs { return eye.Inputs{Mood: eye.Hunter, Boot: -1} }},
		{"sneeze", 3.5, func(t float64) eye.Inputs {
			in := eye.Inputs{Mood: eye.Ready, Boot: -1}
			if t > 0.6 {
				in.Sneeze = 1
			}
			return in
		}},
		{"wink-photo", 5, func(t float64) eye.Inputs {
			in := eye.Inputs{Mood: eye.Ready, Boot: -1}
			if t > 1 {
				in.Wink = 1
			}
			if t > 3 {
				in.Photo = 1
			}
			return in
		}},
	}
	ffmpeg, _ := exec.LookPath("ffmpeg")
	for _, c := range clips {
		dir, err := os.MkdirTemp("", "eye-"+c.name)
		if err != nil {
			log.Fatal(err)
		}
		a := eye.NewAnimator(42)
		n := int(c.secs * 30)
		for i := 0; i < n; i++ {
			l := a.Step(time.Second/30, c.in(float64(i)/30))
			save(filepath.Join(dir, fmt.Sprintf("%04d.png", i)), faceOf(eye.Render(l)))
		}
		if ffmpeg == "" {
			log.Printf("%s: frames in %s (no ffmpeg for GIF/MP4)", c.name, dir)
			continue
		}
		frames := filepath.Join(dir, "%04d.png")
		run(ffmpeg, "-y", "-loglevel", "error", "-framerate", "30", "-i", frames,
			"-c:v", "libx264", "-pix_fmt", "yuv420p", "-crf", "20", filepath.Join(*out, c.name+".mp4"))
		run(ffmpeg, "-y", "-loglevel", "error", "-framerate", "30", "-i", frames,
			"-vf", "fps=20,scale=240:-1:flags=lanczos,split[a][b];[a]palettegen=max_colors=128[p];[b][p]paletteuse=dither=sierra2_4a",
			filepath.Join(*out, c.name+".gif"))
		_ = os.RemoveAll(dir)
		log.Printf("%s: %s.gif and .mp4", c.name, c.name)
	}
}

func settledOpen(m eye.Mood) float64 {
	switch m {
	case eye.Relaxed:
		return 0.48
	case eye.Danger:
		return 0.9
	case eye.Sleeping, eye.Dozing:
		return 0
	case eye.Dizzy:
		return 0.95
	case eye.Sad:
		return 0.78
	case eye.Thinking:
		return 0.92
	case eye.Tired:
		return 0.45
	case eye.Bored:
		return 0.55
	case eye.Furious, eye.Scared:
		return 0.95
	case eye.Hunter:
		return 0.9
	}
	return 1
}

// faceOf puts the panel behind the round window of the robot's face.
func faceOf(panel *image.RGBA) *image.RGBA {
	img := image.NewRGBA(image.Rect(0, 0, face, face))
	c := float64(face) / 2
	off := (face - eye.Size) / 2
	for y := 0; y < face; y++ {
		for x := 0; x < face; x++ {
			dx, dy := float64(x)+0.5-c, float64(y)+0.5-c
			r := math.Hypot(dx, dy)
			// Shell: dark blue-grey, lit from above.
			shell := lerp(color.RGBA{0x26, 0x30, 0x4a, 255}, color.RGBA{0x12, 0x17, 0x26, 255}, (dy/c+1)/2)
			col := shell
			switch {
			case r < windowR:
				col = panel.RGBAAt(x-off, y-off)
				// Glass: a faint sheen on the upper left.
				if g := 1 - math.Hypot(dx+40, dy+52)/70; g > 0 {
					col = lerp(col, color.RGBA{255, 255, 255, 255}, g*0.10)
				}
			case r < windowR+7: // bezel
				col = lerp(color.RGBA{0x07, 0x0a, 0x12, 255}, shell, (r-windowR)/7*0.6)
			}
			// Anti-aliased window edge.
			if e := math.Abs(r - windowR); e < 1 {
				col = lerp(col, color.RGBA{0x07, 0x0a, 0x12, 255}, 1-e)
			}
			img.SetRGBA(x, y, col)
		}
	}
	return img
}

func withLabel(tile *image.RGBA, label string) *image.RGBA {
	img := image.NewRGBA(image.Rect(0, 0, face, face+34))
	draw.Draw(img, img.Bounds(), &image.Uniform{color.RGBA{0x0c, 0x14, 0x28, 255}}, image.Point{}, draw.Src)
	draw.Draw(img, tile.Bounds(), tile, image.Point{}, draw.Src)
	text(img, label, face/2, face+9, 2, color.RGBA{0xc8, 0xd6, 0xf0, 255})
	return img
}

func grid(tiles []*image.RGBA, cols int) *image.RGBA {
	w, h := tiles[0].Bounds().Dx(), tiles[0].Bounds().Dy()
	rows := (len(tiles) + cols - 1) / cols
	const gap = 12
	img := image.NewRGBA(image.Rect(0, 0, cols*w+(cols+1)*gap, rows*h+(rows+1)*gap))
	draw.Draw(img, img.Bounds(), &image.Uniform{color.RGBA{0x06, 0x0a, 0x14, 255}}, image.Point{}, draw.Src)
	for i, t := range tiles {
		x, y := gap+(i%cols)*(w+gap), gap+(i/cols)*(h+gap)
		draw.Draw(img, image.Rect(x, y, x+w, y+h), t, image.Point{}, draw.Src)
	}
	return img
}

func text(img *image.RGBA, s string, x, y, scale int, c color.RGBA) {
	runes := []rune(s)
	left := x - (len(runes)*6*scale-scale)/2
	for i, r := range runes {
		g := display.Glyph(r)
		for col := 0; col < 5; col++ {
			for row := 0; row < 8; row++ {
				if g[col]&(1<<row) == 0 {
					continue
				}
				for dy := 0; dy < scale; dy++ {
					for dx := 0; dx < scale; dx++ {
						img.SetRGBA(left+(i*6+col)*scale+dx, y+row*scale+dy, c)
					}
				}
			}
		}
	}
}

func lerp(a, b color.RGBA, t float64) color.RGBA {
	t = math.Max(0, math.Min(1, t))
	f := func(x, y uint8) uint8 { return uint8(float64(x) + (float64(y)-float64(x))*t + 0.5) }
	return color.RGBA{f(a.R, b.R), f(a.G, b.G), f(a.B, b.B), 255}
}

func save(path string, img image.Image) {
	f, err := os.Create(path)
	if err != nil {
		log.Fatal(err)
	}
	defer f.Close()
	if err := png.Encode(f, img); err != nil {
		log.Fatal(err)
	}
}

func run(name string, args ...string) {
	if out, err := exec.Command(name, args...).CombinedOutput(); err != nil {
		log.Fatalf("%s: %v\n%s", name, err, out)
	}
}
