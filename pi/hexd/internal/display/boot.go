package display

import (
	"context"
	"fmt"
	"log/slog"
	"strings"
	"time"
)

// Boot is what the boot screen knows while the Pi starts, before hexd runs.
type Boot struct {
	Elapsed time.Duration // since the boot screen started
	IP      string        // "" until the network is up
	ESP32   bool          // its serial device exists
}

// BootLines is the boot checklist, one string per text line.
func BootLines(b Boot) []string {
	row := func(name, state string) string {
		pad := lineChars - 1 - len([]rune(name)) - len([]rune(state))
		return name + strings.Repeat(" ", max(pad, 1)) + state
	}
	pending := strings.Repeat(".", 1+int(b.Elapsed/time.Second)%3) // ".", "..", "..."
	network, esp := pending, pending
	if b.IP != "" {
		network = b.IP
	}
	if b.ESP32 {
		esp = "ok"
	}
	bridge := pending
	if b.IP == "" {
		bridge = "aguarda"
	}
	return []string{
		header("INICIANDO"), "",
		row("Sistema", "ok"),
		row("Rede", network),
		row("ESP32", esp),
		row("Ponte (hexd)", bridge),
		"",
		fmt.Sprintf("%d s", int(b.Elapsed.Seconds())),
	}
}

// RenderBoot draws the boot checklist.
func RenderBoot(b Boot) *Frame {
	var f Frame
	for i, line := range BootLines(b) {
		if i == 0 {
			f.Fill(0, 0, true)
			f.Text(0, 0, line, true)
			continue
		}
		f.Text(i, 2, line, false)
	}
	return &f
}

// RunBoot shows the boot checklist until the network is up (then hexd,
// which starts after it, takes the screen) or until timeout. It never fails
// the boot: without a panel it returns at once.
func RunBoot(ctx context.Context, opt Options, open Opener, probe func() Boot, timeout time.Duration, log *slog.Logger) {
	var panel *Panel
	// The i2c-dev node may appear a moment after this starts.
	for deadline := time.Now().Add(5 * time.Second); ; {
		p, err := open(opt.Bus, opt.Address)
		if err == nil {
			if err = p.Init(); err == nil {
				panel = p
				break
			}
			_ = p.Close()
		}
		if time.Now().After(deadline) || ctx.Err() != nil {
			log.Warn("no status screen for the boot checklist", "err", err)
			return
		}
		time.Sleep(250 * time.Millisecond)
	}
	defer func() { _ = panel.Close() }()

	start := time.Now()
	tick := time.NewTicker(500 * time.Millisecond)
	defer tick.Stop()
	for {
		b := probe()
		b.Elapsed = time.Since(start)
		if err := panel.Show(RenderBoot(b)); err != nil {
			log.Warn("boot screen lost", "err", err)
			return
		}
		if b.IP != "" || b.Elapsed > timeout {
			return // hexd takes over from here
		}
		select {
		case <-ctx.Done():
			return
		case <-tick.C:
		}
	}
}
