package link

import (
	"bytes"
	"testing"

	pb "github.com/wallacemartinss/hexapod/pi/hexd/gen/hexapod/v1"
	"google.golang.org/protobuf/proto"
)

func TestCRC16CheckValue(t *testing.T) {
	if got := CRC16([]byte("123456789")); got != 0x29B1 {
		t.Fatalf("CRC16 = %#04x, want 0x29b1", got)
	}
}

// Same vector as firmware/test/test_link: both sides must agree byte for byte.
func TestCOBSKnownVector(t *testing.T) {
	got := cobsEncode([]byte{0x11, 0x22, 0x00, 0x33})
	if want := []byte{0x03, 0x11, 0x22, 0x02, 0x33}; !bytes.Equal(got, want) {
		t.Fatalf("cobsEncode = % x, want % x", got, want)
	}
}

func TestCOBSRoundTrip(t *testing.T) {
	long := make([]byte, 600)
	for i := range long {
		long[i] = byte(i%255 + 1)
	}
	cases := [][]byte{{}, {0, 0, 0}, {0x11, 0, 0x22, 0x33, 0}, long[:253], long[:254], long[:255], long}
	for _, in := range cases {
		enc := cobsEncode(in)
		if bytes.IndexByte(enc, 0) >= 0 {
			t.Fatalf("len %d: encoded contains zero", len(in))
		}
		dec, err := cobsDecode(enc)
		if err != nil || !bytes.Equal(dec, in) {
			t.Fatalf("len %d: round trip failed: %v", len(in), err)
		}
	}
}

func sampleTelemetry() *pb.Envelope {
	angles := make([]float32, 18)
	for i := range angles {
		angles[i] = float32(i) * 1.5
	}
	return &pb.Envelope{Payload: &pb.Envelope_Telemetry{Telemetry: &pb.Telemetry{
		Seq: 42, State: pb.State_STATE_SAFE_SIT, DistancesMm: []uint32{0, 0, 0, 8190}, JointAnglesDeg: angles,
	}}}
}

func feed(d *Decoder, data []byte) (payloads [][]byte) {
	for _, b := range data {
		if p, err := d.Push(b); err == nil && p != nil {
			payloads = append(payloads, append([]byte(nil), p...))
		}
	}
	return payloads
}

func TestEnvelopeRoundTrip(t *testing.T) {
	frame, err := EncodeEnvelope(sampleTelemetry())
	if err != nil {
		t.Fatal(err)
	}
	var d Decoder
	got := feed(&d, frame)
	if len(got) != 1 {
		t.Fatalf("got %d frames, want 1", len(got))
	}
	var env pb.Envelope
	if err := proto.Unmarshal(got[0], &env); err != nil {
		t.Fatal(err)
	}
	if !proto.Equal(&env, sampleTelemetry()) {
		t.Fatalf("decoded envelope differs: %v", &env)
	}
}

func TestCorruptedFramesDropped(t *testing.T) {
	frame, _ := EncodeEnvelope(sampleTelemetry())
	for i := 0; i < len(frame)-1; i++ {
		for bit := range 8 {
			bad := bytes.Clone(frame)
			bad[i] ^= 1 << bit
			var d Decoder
			if n := len(feed(&d, bad)); n != 0 {
				t.Fatalf("byte %d bit %d: corrupted frame accepted", i, bit)
			}
		}
	}
}

func TestResyncAfterGarbageAndOverflow(t *testing.T) {
	frame, _ := EncodeEnvelope(sampleTelemetry())
	stream := append(bytes.Repeat([]byte{0x55}, 3*maxEncoded), 0x00)
	stream = append(stream, []byte("rst:0x1 (POWERON_RESET)\x00")...)
	stream = append(stream, frame...)
	var d Decoder
	if n := len(feed(&d, stream)); n != 1 {
		t.Fatalf("got %d frames, want 1 (stats %+v)", n, d.Stats)
	}
	if d.Stats.Overflows != 1 {
		t.Fatalf("overflows = %d, want 1", d.Stats.Overflows)
	}
}

func TestPayloadLimit(t *testing.T) {
	if _, err := EncodeFrame(make([]byte, MaxPayload)); err != nil {
		t.Fatal(err)
	}
	if _, err := EncodeFrame(make([]byte, MaxPayload+1)); err != ErrTooLarge {
		t.Fatalf("err = %v, want ErrTooLarge", err)
	}
}
