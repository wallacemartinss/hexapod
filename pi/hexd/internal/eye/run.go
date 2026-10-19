package eye

import (
	"context"
	"log/slog"
	"time"
)

// Options for Run.
type Options struct {
	Open     func() (Bus, error) // the display's wiring (OpenLinuxBus on the Pi)
	Rotation int                 // 0, 90, 180, 270: how the panel sits behind the window
	BGR      bool
	FPS      int           // frames per second (default 15; still frames are skipped)
	Retry    time.Duration // a missing or failing panel is tried again after this
	Log      *slog.Logger
}

// Run keeps the eye alive until ctx ends: inputs() is read every frame. A
// missing panel is logged once and tried again; on the way out the eye
// closes, then the panel sleeps.
func Run(ctx context.Context, opt Options, inputs func() Inputs) {
	if opt.FPS <= 0 {
		opt.FPS = 15
	}
	if opt.Retry <= 0 {
		opt.Retry = 30 * time.Second
	}
	anim := NewAnimator(uint64(time.Now().UnixNano()))
	failing := false
	for ctx.Err() == nil {
		bus, err := opt.Open()
		if err == nil {
			panel := NewPanel(bus, opt.Rotation, opt.BGR)
			if err = panel.Init(); err == nil {
				if failing {
					opt.Log.Info("eye back")
				}
				failing = false
				err = loop(ctx, panel, anim, opt.FPS, inputs)
				if ctx.Err() != nil {
					closeEye(panel, anim, opt.FPS)
				}
			}
			_ = bus.Close()
		}
		if err != nil && ctx.Err() == nil {
			if !failing {
				opt.Log.Warn("eye unavailable, retrying", "err", err, "every", opt.Retry)
				failing = true
			}
			select {
			case <-ctx.Done():
			case <-time.After(opt.Retry):
			}
		}
	}
}

func loop(ctx context.Context, p *Panel, a *Animator, fps int, inputs func() Inputs) error {
	frame := time.Second / time.Duration(fps)
	t := time.NewTicker(frame)
	defer t.Stop()
	last := time.Now()
	var shown *Look
	for {
		select {
		case <-ctx.Done():
			return nil
		case now := <-t.C:
			look := a.Step(now.Sub(last), inputs())
			last = now
			if shown != nil && Same(*shown, look) {
				continue // nothing visible changed: no drawing, no SPI
			}
			if err := p.Draw(Render(look)); err != nil {
				return err
			}
			shown = &look
		}
	}
}

// closeEye plays the eye shutting (half a second), then sleeps the panel.
func closeEye(p *Panel, a *Animator, fps int) {
	frame := time.Second / time.Duration(fps)
	for i := 0; i < fps/2; i++ {
		_ = p.Draw(Render(a.Step(frame, Inputs{Mood: Sleeping, Boot: -1})))
		time.Sleep(frame)
	}
	_ = p.Off()
}
