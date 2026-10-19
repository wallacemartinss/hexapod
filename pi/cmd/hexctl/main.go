// hexctl drives the robot through hexd's WebSocket, like the app will.
//
//	hexctl -url ws://hexapod.local:8080/ws watch      print state changes
//	(paired robots need -token KEY or HEXAPOD_TOKEN=KEY)
//	hexctl -url ws://hexapod.local:8080/ws trace      telemetry at 5 Hz: mode, seq, leg angles
//	hexctl -url ws://hexapod.local:8080/ws demo       STAND, walk, release, SIT, then go silent
//	hexctl -url ws://hexapod.local:8080/ws estop      one emergency stop
//	hexctl -url ws://hexapod.local:8080/ws -for 5s stand   keep it standing
//
// Commands are sent at 20 Hz, as the app does (dead man's switch). hexd stamps
// the seq. While the firmware keeps servo outputs locked, nothing moves.
package main

import (
	"context"
	"flag"
	"fmt"
	"log"
	"net/http"
	"os"
	"time"

	"github.com/coder/websocket"
	pb "github.com/wallacemartinss/hexapod/pi/hexd/gen/hexapod/v1"
	"google.golang.org/protobuf/proto"
)

func main() {
	url := flag.String("url", "ws://hexapod.local:8080/ws", "hexd WebSocket")
	hold := flag.Duration("for", 5*time.Second, "how long `stand` keeps commanding")
	token := flag.String("token", os.Getenv("HEXAPOD_TOKEN"),
		"pairing key (default $HEXAPOD_TOKEN; on the Pi: sudo -u hexapod hexd -pairing)")
	flag.Parse()
	ctx := context.Background()
	var opts *websocket.DialOptions
	if *token != "" {
		opts = &websocket.DialOptions{HTTPHeader: http.Header{"Authorization": []string{"Bearer " + *token}}}
	}
	conn, _, err := websocket.Dial(ctx, *url, opts)
	if err != nil {
		log.Fatalf("connect %s: %v", *url, err)
	}
	defer conn.CloseNow()

	start := time.Now()
	elapsed := func() float64 { return time.Since(start).Seconds() }
	var last pb.State = -1
	trace := flag.Arg(0) == "trace"
	var lastTrace time.Time
	go func() {
		for {
			_, b, err := conn.Read(ctx)
			if err != nil {
				return
			}
			var env pb.Envelope
			if proto.Unmarshal(b, &env) != nil {
				continue
			}
			if h := env.GetHello(); h != nil {
				fmt.Printf("%6.2fs  firmware %s (protocol %d)\n", elapsed(), h.FirmwareVersion, h.ProtocolVersion)
			}
			if t := env.GetTelemetry(); t != nil && trace {
				if time.Since(lastTrace) >= 200*time.Millisecond {
					lastTrace = time.Now()
					printTrace(elapsed(), t)
				}
			} else if t != nil && t.State != last {
				last = t.State
				a := t.JointAnglesDeg
				leg0 := ""
				if len(a) >= 3 {
					leg0 = fmt.Sprintf("leg0 %.1f/%.1f/%.1f", a[0], a[1], a[2])
				}
				fmt.Printf("%6.2fs  state %-16v mode %-11v last_cmd %-5d %s\n", elapsed(), t.State, t.Mode, t.LastCommandSeq, leg0)
			}
		}
	}()

	send := func(c *pb.Command) {
		b, _ := proto.Marshal(&pb.Envelope{Payload: &pb.Envelope_Command{Command: c}})
		if err := conn.Write(ctx, websocket.MessageBinary, b); err != nil {
			log.Fatal(err)
		}
	}
	drive := func(name string, c *pb.Command, d time.Duration) {
		fmt.Printf("%6.2fs  >> %s\n", elapsed(), name)
		t := time.NewTicker(50 * time.Millisecond)
		defer t.Stop()
		for end := time.Now().Add(d); time.Now().Before(end); <-t.C {
			send(proto.CloneOf(c))
		}
	}

	switch flag.Arg(0) {
	case "watch", "trace":
		select {}
	case "stand":
		time.Sleep(300 * time.Millisecond)
		drive("STAND", &pb.Command{Mode: pb.Mode_MODE_STAND, BodyHeight: 0.5}, *hold)
	case "estop":
		send(&pb.Command{Estop: true})
		time.Sleep(500 * time.Millisecond)
	case "demo":
		time.Sleep(500 * time.Millisecond)
		drive("STAND", &pb.Command{Mode: pb.Mode_MODE_STAND, BodyHeight: 0.5}, 1500*time.Millisecond)
		drive("WALK forward 50%", &pb.Command{Mode: pb.Mode_MODE_WALK, Vx: 0.5, BodyHeight: 0.5}, 3*time.Second)
		drive("sticks released", &pb.Command{Mode: pb.Mode_MODE_WALK, BodyHeight: 0.5}, time.Second)
		drive("SIT", &pb.Command{Mode: pb.Mode_MODE_SIT, BodyHeight: 0.5}, 1500*time.Millisecond)
		fmt.Printf("%6.2fs  >> app goes silent (dead man's switch)\n", elapsed())
		time.Sleep(2 * time.Second)
	default:
		fmt.Fprintln(os.Stderr, "usage: hexctl [-url ws://...] [-for 5s] watch|trace|demo|stand|estop")
		os.Exit(2)
	}
}

// printTrace shows what the ESP32 is doing with the commands it gets: mode,
// last accepted seq and the joint angles it computed for the front left
// (leg 0) and front right (leg 3) legs. Read-only: trace sends nothing.
func printTrace(at float64, t *pb.Telemetry) {
	leg := func(i int) string {
		a := t.JointAnglesDeg
		if len(a) < 3*(i+1) {
			return "-"
		}
		return fmt.Sprintf("%6.1f %6.1f %6.1f", a[3*i], a[3*i+1], a[3*i+2])
	}
	fmt.Printf("%6.2fs  %-12v %-17v cmd %-6d leg0 %s  leg3 %s\n",
		at, t.State, t.Mode, t.LastCommandSeq, leg(0), leg(3))
}
