// Package link implements the serial framing shared with the ESP32 firmware:
//
//	frame = COBS(payload || CRC16-LE) || 0x00
//
// with CRC-16/CCITT-FALSE. The specification lives in proto/README.md and
// must match firmware/src/link.
package link

import (
	"errors"

	pb "github.com/wallacemartinss/hexapod/pi/hexd/gen/hexapod/v1"
	"google.golang.org/protobuf/proto"
)

// MaxPayload is the largest encoded Envelope (hexapod_v1_Envelope_size in nanopb).
const MaxPayload = 249

// maxEncoded is the largest COBS-encoded frame body (payload + CRC16).
const maxEncoded = MaxPayload + 2 + 1

var (
	ErrTooLarge = errors.New("link: payload too large")
	ErrCOBS     = errors.New("link: malformed COBS")
	ErrCRC      = errors.New("link: CRC mismatch")
	ErrOverflow = errors.New("link: frame overflow")
)

// CRC16 computes CRC-16/CCITT-FALSE ("123456789" -> 0x29B1).
func CRC16(data []byte) uint16 {
	crc := uint16(0xFFFF)
	for _, b := range data {
		crc ^= uint16(b) << 8
		for range 8 {
			if crc&0x8000 != 0 {
				crc = crc<<1 ^ 0x1021
			} else {
				crc <<= 1
			}
		}
	}
	return crc
}

// cobsEncode stuffs data so it contains no zero byte (delimiter not included).
func cobsEncode(data []byte) []byte {
	out := make([]byte, 1, len(data)+len(data)/254+2)
	codePos, code := 0, byte(1)
	for _, b := range data {
		if b == 0 {
			out[codePos] = code
			codePos, code = len(out), 1
			out = append(out, 0)
			continue
		}
		out = append(out, b)
		code++
		if code == 0xFF {
			out[codePos] = code
			codePos, code = len(out), 1
			out = append(out, 0)
		}
	}
	out[codePos] = code
	return out
}

// cobsDecode reverses cobsEncode.
func cobsDecode(data []byte) ([]byte, error) {
	out := make([]byte, 0, len(data))
	for i := 0; i < len(data); {
		code := data[i]
		i++
		if code == 0 || i+int(code)-1 > len(data) {
			return nil, ErrCOBS
		}
		for range int(code) - 1 {
			if data[i] == 0 {
				return nil, ErrCOBS
			}
			out = append(out, data[i])
			i++
		}
		if code != 0xFF && i < len(data) {
			out = append(out, 0)
		}
	}
	return out, nil
}

// EncodeFrame builds one wire frame around payload.
func EncodeFrame(payload []byte) ([]byte, error) {
	if len(payload) > MaxPayload {
		return nil, ErrTooLarge
	}
	crc := CRC16(payload)
	raw := append(append(make([]byte, 0, len(payload)+2), payload...), byte(crc), byte(crc>>8))
	return append(cobsEncode(raw), 0x00), nil
}

// EncodeEnvelope marshals env and frames it.
func EncodeEnvelope(env *pb.Envelope) ([]byte, error) {
	payload, err := proto.Marshal(env)
	if err != nil {
		return nil, err
	}
	return EncodeFrame(payload)
}

// Decoder splits a byte stream into payloads. Invalid frames are dropped and
// counted; parsing resumes after the next 0x00.
type Decoder struct {
	buf      []byte
	overflow bool
	Stats    Stats
}

// Stats counts frames seen by a Decoder.
type Stats struct {
	Frames, COBSErrors, CRCErrors, Overflows uint64
}

// Push feeds one byte. It returns a payload when a valid frame completes, or
// an error when a frame was dropped; (nil, nil) means "need more bytes".
func (d *Decoder) Push(b byte) ([]byte, error) {
	if b != 0x00 {
		if len(d.buf) == maxEncoded {
			d.overflow = true
		} else {
			d.buf = append(d.buf, b)
		}
		return nil, nil
	}
	buf, overflow := d.buf, d.overflow
	d.buf, d.overflow = d.buf[:0:0], false
	switch {
	case overflow:
		d.Stats.Overflows++
		return nil, ErrOverflow
	case len(buf) == 0:
		return nil, nil // idle delimiter
	}
	raw, err := cobsDecode(buf)
	if err != nil || len(raw) < 2 {
		d.Stats.COBSErrors++
		return nil, ErrCOBS
	}
	payload := raw[:len(raw)-2]
	if CRC16(payload) != uint16(raw[len(raw)-2])|uint16(raw[len(raw)-1])<<8 {
		d.Stats.CRCErrors++
		return nil, ErrCRC
	}
	d.Stats.Frames++
	return payload, nil
}
