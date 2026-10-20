// Package device keeps the link to the ESP32: it (re)connects, exchanges
// Hello, tracks the latest Telemetry and stamps the seq of outgoing Commands.
package device

import (
	"context"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"net"
	"strings"
	"sync"
	"time"

	pb "github.com/wallacemartinss/hexapod/pi/hexd/gen/hexapod/v1"
	"github.com/wallacemartinss/hexapod/pi/internal/link"
	"go.bug.st/serial"
	"google.golang.org/protobuf/proto"
)

// ProtocolVersion must match firmware config::kProtocolVersion.
const ProtocolVersion = 1

var (
	// ErrNotReady: not connected, or the ESP32 seq is not known yet (the first
	// Telemetry after connecting carries it).
	ErrNotReady = errors.New("device: link not ready")
	// ErrProtocol: the firmware speaks another protocol version.
	ErrProtocol = errors.New("device: protocol version mismatch")
)

// Dialer opens one connection to the ESP32.
type Dialer func(ctx context.Context) (io.ReadWriteCloser, error)

// Dial understands a serial device path, tcp://host:port and unix:///path
// (the last two are for hexsim).
func Dial(address string, baud int) Dialer {
	return func(ctx context.Context) (io.ReadWriteCloser, error) {
		if network, addr, ok := strings.Cut(address, "://"); ok {
			var d net.Dialer
			return d.DialContext(ctx, network, addr)
		}
		return serial.Open(address, &serial.Mode{BaudRate: baud})
	}
}

// Options configure a Device.
type Options struct {
	Dial         Dialer
	HexdVersion  string
	SilenceLimit time.Duration // reconnect when nothing arrives for this long
	Logger       *slog.Logger
}

// Snapshot is a consistent copy of the device state.
type Snapshot struct {
	Connected  bool
	LastRx     time.Time
	Hello      *pb.Hello     // nil until the firmware introduced itself
	Telemetry  *pb.Telemetry // nil until the first one
	Compass    *pb.Compass   // nil until the first one (BNO085 rotation vector)
	CompassAt  time.Time
	Stats      link.Stats
	Reconnects uint64
}

// Device is safe for concurrent use.
type Device struct {
	opt Options

	mu       sync.Mutex
	conn     io.ReadWriteCloser
	seq      uint32
	seqKnown bool
	snap     Snapshot
	subs     map[chan *pb.Telemetry]struct{}
	writeMu  sync.Mutex
}

// New creates a Device; call Run to connect.
func New(opt Options) *Device {
	if opt.SilenceLimit == 0 {
		opt.SilenceLimit = 3 * time.Second
	}
	if opt.Logger == nil {
		opt.Logger = slog.Default()
	}
	return &Device{opt: opt, subs: map[chan *pb.Telemetry]struct{}{}}
}

// Run keeps the link up until ctx ends.
func (d *Device) Run(ctx context.Context) {
	backoff := 250 * time.Millisecond
	for ctx.Err() == nil {
		conn, err := d.opt.Dial(ctx)
		if err != nil {
			d.opt.Logger.Warn("esp32 connect failed", "err", err, "retry_in", backoff)
			select {
			case <-ctx.Done():
				return
			case <-time.After(backoff):
			}
			backoff = min(backoff*2, 5*time.Second)
			continue
		}
		backoff = 250 * time.Millisecond
		d.opt.Logger.Info("esp32 connected")
		err = d.serve(ctx, conn)
		d.opt.Logger.Warn("esp32 disconnected", "err", err)
	}
}

func (d *Device) serve(ctx context.Context, conn io.ReadWriteCloser) error {
	d.mu.Lock()
	d.conn, d.seqKnown = conn, false
	d.snap.Connected, d.snap.LastRx = true, time.Now()
	d.mu.Unlock()
	defer func() {
		d.mu.Lock()
		d.conn, d.seqKnown, d.snap.Connected = nil, false, false
		d.snap.Reconnects++
		d.mu.Unlock()
		conn.Close()
	}()

	// Close the stream on shutdown or silence; the blocked Read then returns.
	done := make(chan struct{})
	defer close(done)
	go func() {
		t := time.NewTicker(d.opt.SilenceLimit / 4)
		defer t.Stop()
		for {
			select {
			case <-done:
				return
			case <-ctx.Done():
				conn.Close()
				return
			case <-t.C:
				d.mu.Lock()
				silent := time.Since(d.snap.LastRx) > d.opt.SilenceLimit
				d.mu.Unlock()
				if silent {
					d.opt.Logger.Warn("esp32 silent, reopening", "limit", d.opt.SilenceLimit)
					conn.Close()
					return
				}
			}
		}
	}()

	if err := d.write(&pb.Envelope{Payload: &pb.Envelope_Hello{Hello: &pb.Hello{
		ProtocolVersion: ProtocolVersion, HexdVersion: d.opt.HexdVersion,
	}}}); err != nil {
		return err
	}

	var dec link.Decoder
	buf := make([]byte, 512)
	for {
		n, err := conn.Read(buf)
		if err != nil {
			return err
		}
		if n == 0 {
			continue // serial read timeout
		}
		for _, b := range buf[:n] {
			payload, err := dec.Push(b)
			if err != nil || payload == nil {
				continue
			}
			var env pb.Envelope
			if proto.Unmarshal(payload, &env) != nil {
				continue
			}
			d.receive(&env, dec.Stats)
		}
	}
}

func (d *Device) receive(env *pb.Envelope, stats link.Stats) {
	d.mu.Lock()
	d.snap.LastRx = time.Now()
	d.snap.Stats = stats
	var tel *pb.Telemetry
	switch m := env.Payload.(type) {
	case *pb.Envelope_Hello:
		d.snap.Hello = m.Hello
		if m.Hello.ProtocolVersion != ProtocolVersion {
			d.opt.Logger.Error("esp32 protocol mismatch", "firmware", m.Hello.ProtocolVersion, "hexd", ProtocolVersion)
		} else {
			d.opt.Logger.Info("esp32 hello", "firmware", m.Hello.FirmwareVersion, "git", m.Hello.GitHash)
		}
	case *pb.Envelope_Compass:
		d.snap.Compass, d.snap.CompassAt = m.Compass, d.snap.LastRx
	case *pb.Envelope_Telemetry:
		tel = m.Telemetry
		d.snap.Telemetry = tel
		if !d.seqKnown {
			// Continue after whatever the ESP32 accepted last: a restarted
			// hexd starting from 1 would have every command rejected.
			d.seq = max(d.seq, tel.LastCommandSeq)
			d.seqKnown = true
		}
	}
	subs := make([]chan *pb.Telemetry, 0, len(d.subs))
	for c := range d.subs {
		subs = append(subs, c)
	}
	d.mu.Unlock()

	if tel != nil {
		for _, c := range subs {
			select { // slow subscribers miss frames, they never block the link
			case c <- tel:
			default:
			}
		}
	}
}

func (d *Device) write(env *pb.Envelope) error {
	frame, err := link.EncodeEnvelope(env)
	if err != nil {
		return err
	}
	d.mu.Lock()
	conn := d.conn
	d.mu.Unlock()
	if conn == nil {
		return ErrNotReady
	}
	d.writeMu.Lock()
	defer d.writeMu.Unlock()
	_, err = conn.Write(frame)
	return err
}

// SendCommand stamps seq and timestamp_ms and forwards cmd to the ESP32.
func (d *Device) SendCommand(cmd *pb.Command) error {
	d.mu.Lock()
	if d.conn == nil || !d.seqKnown {
		d.mu.Unlock()
		return ErrNotReady
	}
	if h := d.snap.Hello; h != nil && h.ProtocolVersion != ProtocolVersion {
		d.mu.Unlock()
		return fmt.Errorf("%w: firmware %d", ErrProtocol, h.ProtocolVersion)
	}
	d.seq++
	out := proto.CloneOf(cmd)
	out.Seq = d.seq
	out.TimestampMs = uint32(time.Now().UnixMilli())
	d.mu.Unlock()
	return d.write(&pb.Envelope{Payload: &pb.Envelope_Command{Command: out}})
}

// SendLinkConfig tells the ESP32 which failsafe timeouts to use.
func (d *Device) SendLinkConfig(p pb.LinkProfile) error {
	return d.write(&pb.Envelope{Payload: &pb.Envelope_LinkConfig{LinkConfig: &pb.LinkConfig{Profile: p}}})
}

// Snapshot returns a copy of the current state.
func (d *Device) Snapshot() Snapshot {
	d.mu.Lock()
	defer d.mu.Unlock()
	return d.snap
}

// Subscribe delivers every Telemetry until cancel is called.
func (d *Device) Subscribe() (<-chan *pb.Telemetry, func()) {
	c := make(chan *pb.Telemetry, 16)
	d.mu.Lock()
	d.subs[c] = struct{}{}
	d.mu.Unlock()
	return c, func() {
		d.mu.Lock()
		delete(d.subs, c)
		d.mu.Unlock()
	}
}
