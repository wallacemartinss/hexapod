package display

import (
	"context"
	"log/slog"
	"time"
)

// Options for the status screen (hexd.yaml, display section).
type Options struct {
	Bus      string        // i2c-dev bus, e.g. /dev/i2c-1
	Address  int           // 7-bit address, 0x3C on most SSD1306 boards
	PageTime time.Duration // how long each page stays
	Retry    time.Duration // wait before reopening a missing or failing panel
}

// Opener reaches the panel (Open on the Pi, fakes in tests).
type Opener func(bus string, addr int) (*Panel, error)

// Run refreshes the screen once a second with status() until ctx ends, then
// leaves "hexd parado" on it. A missing panel is logged once and retried:
// the robot works the same without it.
func Run(ctx context.Context, opt Options, open Opener, status func() Status, log *slog.Logger) {
	var panel *Panel
	failing := false
	var retryAt, wokeAt time.Time
	start := time.Now()
	tick := time.NewTicker(time.Second)
	defer tick.Stop()

	show := func(s Status, now time.Time) {
		if panel == nil {
			if now.Before(retryAt) {
				return
			}
			p, err := open(opt.Bus, opt.Address)
			if err == nil {
				err = p.Init()
				if err != nil {
					_ = p.Close()
				}
			}
			if err != nil {
				if !failing {
					log.Warn("status screen unavailable, retrying", "bus", opt.Bus, "addr", opt.Address, "err", err)
				}
				failing, retryAt = true, now.Add(opt.Retry)
				return
			}
			if failing {
				log.Info("status screen back")
			}
			panel, failing = p, false
		}
		if now.Sub(wokeAt) >= 5*time.Second {
			if err := panel.Wake(); err == nil {
				wokeAt = now
			}
		}
		list := Pages(s)
		page := list[int(now.Sub(start)/opt.PageTime)%len(list)]
		shift := int(now.Unix()/60) % 3 // 1 px per minute against burn-in
		if err := panel.Show(Render(s, page, shift)); err != nil {
			log.Warn("status screen lost, retrying", "err", err)
			_ = panel.Close()
			panel, failing, retryAt = nil, true, now.Add(opt.Retry)
		}
	}

	for {
		select {
		case <-ctx.Done():
			s := status()
			s.Stopped = true
			show(s, time.Now())
			if panel != nil {
				_ = panel.Close()
			}
			return
		case now := <-tick.C:
			show(status(), now)
		}
	}
}
