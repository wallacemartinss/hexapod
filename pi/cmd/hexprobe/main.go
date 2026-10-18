// hexprobe is a bench tool: it opens the ESP32 serial port, sends a Hello and
// prints every message received for a while. It never sends motion commands.
//
//	hexprobe -port /dev/hexapod-esp32 -duration 5s
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
