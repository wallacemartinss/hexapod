// hexprobe is a bench tool: it opens the ESP32 serial port, sends a Hello and
// prints every message received for a while.
//
//	hexprobe -port /dev/hexapod-esp32 -duration 5s
//	hexprobe -failsafe   walk through the failsafe states (all velocities zero)
//	hexprobe -gait       stand, walk, stop and sit "on paper": prints joint
//	                     angles computed by the firmware (servos stay off)
package main

import (
	"flag"
	"fmt"
	"log"
	"os"
	"time"

	pb "github.com/wallacemartinss/hexapod/pi/hexd/gen/hexapod/v1"
	"github.com/wallacemartinss/hexapod/pi/internal/link"
	"go.bug.st/serial"
	"google.golang.org/protobuf/proto"
)

func main() {
	port := flag.String("port", "/dev/hexapod-esp32", "serial device")
	baud := flag.Int("baud", 115200, "baud rate (ignored by native USB)")
	duration := flag.Duration("duration", 5*time.Second, "how long to listen")
	failsafe := flag.Bool("failsafe", false, "run the failsafe scenario instead of listening")
	gait := flag.Bool("gait", false, "run the gait-on-paper scenario instead of listening")
	flag.Parse()

	p, err := serial.Open(*port, &serial.Mode{BaudRate: *baud})
	if err != nil {
		log.Fatalf("open %s: %v", *port, err)
	}
	defer p.Close()
	if err := p.SetReadTimeout(100 * time.Millisecond); err != nil {
		log.Fatal(err)
	}

	// Opening the port may reset a DevKit (DTR/RTS auto-reset): give it time to boot.
	time.Sleep(1500 * time.Millisecond)
	hello, _ := link.EncodeEnvelope(&pb.Envelope{Payload: &pb.Envelope_Hello{Hello: &pb.Hello{
		ProtocolVersion: 1, HexdVersion: "hexprobe",
	}}})
	if _, err := p.Write(hello); err != nil {
		log.Fatal(err)
	}

	if *failsafe {
		os.Exit(runFailsafe(p))
	}
	if *gait {
		os.Exit(runGait(p))
	}

	var dec link.Decoder
	counts := map[string]int{}
	buf := make([]byte, 256)
	deadline := time.Now().Add(*duration)
	for time.Now().Before(deadline) {
		n, err := p.Read(buf)
		if err != nil {
			log.Fatal(err)
		}
		for _, b := range buf[:n] {
			payload, err := dec.Push(b)
			if err != nil || payload == nil {
				continue
			}
			var env pb.Envelope
			if err := proto.Unmarshal(payload, &env); err != nil {
				counts["undecodable"]++
				continue
			}
			report(&env, counts)
		}
	}
	fmt.Printf("\nsummary: %v, link stats %+v\n", counts, dec.Stats)
	if counts["hello"] == 0 || counts["telemetry"] == 0 {
		os.Exit(1)
	}
}

func report(env *pb.Envelope, counts map[string]int) {
	switch m := env.Payload.(type) {
	case *pb.Envelope_Hello:
		counts["hello"]++
		h := m.Hello
		fmt.Printf("HELLO     protocol=%d firmware=%s git=%.12s uptime=%dms\n",
			h.ProtocolVersion, h.FirmwareVersion, h.GitHash, h.UptimeMs)
	case *pb.Envelope_Telemetry:
		counts["telemetry"]++
		t := m.Telemetry
		if counts["telemetry"] <= 3 || counts["telemetry"]%10 == 0 {
			fmt.Printf("TELEMETRY seq=%d uptime=%dms state=%v last_cmd=%d esp32=%.1f°C\n",
				t.Seq, t.UptimeMs, t.State, t.LastCommandSeq, t.Esp32TemperatureC)
		}
	default:
		counts[fmt.Sprintf("%T", m)]++
	}
}

// runFailsafe sends Commands with zero velocity and reports every state change:
// STAND -> NORMAL, silence -> STOPPING -> SAFE_SIT -> RELAXED, STAND, estop.
func runFailsafe(p serial.Port) int {
	start := time.Now()
	var seq uint32
	send := func(mode pb.Mode, estop bool) {
		seq++
		frame, _ := link.EncodeEnvelope(&pb.Envelope{Payload: &pb.Envelope_Command{Command: &pb.Command{
			Seq: seq, TimestampMs: uint32(time.Since(start).Milliseconds()), Mode: mode, Estop: estop,
		}}})
		if _, err := p.Write(frame); err != nil {
			log.Fatal(err)
		}
	}

	// Telemetry reader in the background: prints state changes.
	type change struct {
		at    time.Duration
		state pb.State
	}
	changes := make(chan change, 64)
	go func() {
		var dec link.Decoder
		buf := make([]byte, 256)
		last := pb.State(-1)
		for {
			n, err := p.Read(buf)
			if err != nil {
				return
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
				if t := env.GetTelemetry(); t != nil && t.State != last {
					last = t.State
					changes <- change{time.Since(start), t.State}
				}
			}
		}
	}()

	step := func(name string) { fmt.Printf("%7.2fs  >> %s\n", time.Since(start).Seconds(), name) }
	drain := func(d time.Duration, pilot bool) {
		end := time.Now().Add(d)
		tick := time.NewTicker(50 * time.Millisecond) // 20 Hz like the app
		defer tick.Stop()
		for time.Now().Before(end) {
			select {
			case c := <-changes:
				fmt.Printf("%7.2fs  state %v\n", c.at.Seconds(), c.state)
			case <-tick.C:
				if pilot {
					send(pb.Mode_MODE_WALK, false)
				}
			}
		}
	}

	drain(500*time.Millisecond, false)
	step("STAND, then commands at 20 Hz (zero velocity)")
	send(pb.Mode_MODE_STAND, false)
	drain(2*time.Second, true)
	step("silence: expect STOPPING > 150 ms, SAFE_SIT > 500 ms, RELAXED > 10 s")
	drain(11*time.Second, false)
	step("STAND")
	send(pb.Mode_MODE_STAND, false)
	drain(time.Second, true)
	step("estop")
	send(pb.Mode_MODE_WALK, true)
	drain(time.Second, true)
	return 0
}

// runGait commands STAND, a forward walk, a stop and SIT at 20 Hz and prints
// leg 0 joint angles and the motion loop time from Telemetry.
func runGait(p serial.Port) int {
	start := time.Now()
	latest := make(chan *pb.Telemetry, 1)
	go func() {
		var dec link.Decoder
		buf := make([]byte, 256)
		for {
			n, err := p.Read(buf)
			if err != nil {
				return
			}
			for _, b := range buf[:n] {
				payload, err := dec.Push(b)
				if err != nil || payload == nil {
					continue
				}
				var env pb.Envelope
				if proto.Unmarshal(payload, &env) == nil && env.GetTelemetry() != nil {
					select {
					case <-latest:
					default:
					}
					latest <- env.GetTelemetry()
				}
			}
		}
	}()

	var seq uint32
	var maxLoop uint32
	phase := func(name string, mode pb.Mode, vx float32, d time.Duration) {
		fmt.Printf("%6.2fs >> %s\n", time.Since(start).Seconds(), name)
		tick := time.NewTicker(50 * time.Millisecond)
		defer tick.Stop()
		lastPrint := time.Time{}
		for end := time.Now().Add(d); time.Now().Before(end); {
			<-tick.C
			seq++
			frame, _ := link.EncodeEnvelope(&pb.Envelope{Payload: &pb.Envelope_Command{Command: &pb.Command{
				Seq: seq, Mode: mode, Vx: vx, BodyHeight: 0.5,
			}}})
			if _, err := p.Write(frame); err != nil {
				log.Fatal(err)
			}
			select {
			case t := <-latest:
				maxLoop = max(maxLoop, t.LoopTimeUs)
				if time.Since(lastPrint) >= 250*time.Millisecond && len(t.JointAnglesDeg) >= 3 {
					lastPrint = time.Now()
					a := t.JointAnglesDeg
					fmt.Printf("%6.2fs   %-14v mode=%-10v leg0 coxa=%7.2f femur=%7.2f tibia=%8.2f  loop=%dus\n",
						time.Since(start).Seconds(), t.State, t.Mode, a[0], a[1], a[2], t.LoopTimeUs)
				}
			default:
			}
		}
	}
	phase("STAND", pb.Mode_MODE_STAND, 0, 1500*time.Millisecond)
	phase("WALK forward 50%", pb.Mode_MODE_WALK, 0.5, 4*time.Second)
	phase("WALK, sticks released", pb.Mode_MODE_WALK, 0, 2*time.Second)
	phase("SIT", pb.Mode_MODE_SIT, 0, 2*time.Second)
	fmt.Printf("max motion loop time: %d us (budget %d us)\n", maxLoop, 20000)
	return 0
}
