// Package shutdown powers the Pi off when the battery is critical and the
// robot is already down (LOW_BATTERY: the ESP32 sat it down and asked for it).
package shutdown

import (
	"context"
	"log/slog"
	"os/exec"
	"time"

	pb "github.com/wallacemartinss/hexapod/pi/hexd/gen/hexapod/v1"
)

const faultBatteryCritical = uint32(pb.Fault_FAULT_BATTERY_CRITICAL)

// Runner executes the power-off command (replaced in tests).
type Runner func(ctx context.Context, argv []string) error

// Exec runs argv as a process.
func Exec(ctx context.Context, argv []string) error {
	return exec.CommandContext(ctx, argv[0], argv[1:]...).Run()
}

// Watch reads telemetry until ctx ends. When LOW_BATTERY with the critical
// fault holds for `delay` without interruption, it runs `argv` once.
func Watch(ctx context.Context, tel <-chan *pb.Telemetry, delay time.Duration, argv []string,
	run Runner, log *slog.Logger) {
	var since time.Time
	for {
		select {
		case <-ctx.Done():
			return
		case t := <-tel:
			critical := t.State == pb.State_STATE_LOW_BATTERY && t.FaultFlags&faultBatteryCritical != 0
			if !critical {
				if !since.IsZero() {
					log.Info("battery recovered, shutdown cancelled")
				}
				since = time.Time{}
				continue
			}
			if since.IsZero() {
				since = time.Now()
				log.Warn("battery critical, robot seated: powering off soon", "in", delay)
			}
			if time.Since(since) >= delay {
				log.Error("battery critical: powering off", "command", argv)
				if err := run(ctx, argv); err != nil {
					log.Error("power-off failed", "err", err)
					since = time.Time{} // try again after another full delay
					continue
				}
				return
			}
		}
	}
}
