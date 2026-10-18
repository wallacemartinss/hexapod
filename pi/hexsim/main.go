// hexsim simulates the ESP32 firmware for hexd and app tests, without hardware.
//
//	hexsim -listen tcp://127.0.0.1:7777
//	hexsim -listen unix:///tmp/hexsim.sock
//
// To hand hexd a real serial-like device:
//
//	socat pty,raw,echo=0,link=/tmp/hexsim-tty tcp:127.0.0.1:7777
//
// It accepts one connection at a time, like a serial port, and keeps its
// state (seq, failsafe, battery) across connections.
package main

import (
	"context"
	"flag"
	"log"
	"net"
	"os"
	"os/signal"
	"strings"
	"syscall"

	"github.com/wallacemartinss/hexapod/pi/internal/sim"
)

func main() {
	listen := flag.String("listen", "tcp://127.0.0.1:7777", "tcp://host:port or unix:///path")
	noise := flag.Bool("boot-noise", true, "send ROM-like garbage on each connection")
	drain := flag.Float64("drain", 1, "battery drain multiplier (e.g. 200 to reach LOW_BATTERY fast)")
	firmware := flag.String("firmware", "hexsim", "firmware version reported in Hello")
	flag.Parse()

	network, addr, ok := strings.Cut(*listen, "://")
	if !ok || (network != "tcp" && network != "unix") {
		log.Fatalf("bad -listen %q", *listen)
	}
	if network == "unix" {
		_ = os.Remove(addr)
	}
	ln, err := net.Listen(network, addr)
	if err != nil {
		log.Fatal(err)
	}
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	go func() { <-ctx.Done(); ln.Close() }()

	s := sim.New(sim.Options{FirmwareVersion: *firmware, BootNoise: *noise, BatteryDrain: *drain})
	log.Printf("hexsim listening on %s", *listen)
	for {
		conn, err := ln.Accept()
		if err != nil {
			if ctx.Err() != nil {
				return
			}
			log.Fatal(err)
		}
		log.Printf("connected: %s", conn.RemoteAddr())
		err = s.Serve(ctx, conn)
		conn.Close()
		log.Printf("disconnected (%v), state %v", err, s.State())
	}
}
