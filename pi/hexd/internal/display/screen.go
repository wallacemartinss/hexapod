package display

import (
	"fmt"
	"math"
	"strings"

	pb "github.com/wallacemartinss/hexapod/pi/hexd/gen/hexapod/v1"
)

const (
	Width     = 128
	Height    = 64
	pages     = Height / 8
	charWidth = 6 // 5 columns + 1 of space
	// Columns per text line.
	lineChars = Width / charWidth
)

// Frame is the panel's memory layout: 8 pages of 8 pixel rows, one byte per
// column, bit 0 at the top. A text line is one page.
type Frame [pages][Width]byte

// Text draws s on text line (page) line from pixel column x. Inverted
// draws dark text on a lit band (the caller fills the band first).
func (f *Frame) Text(line, x int, s string, inverted bool) {
	for _, r := range s {
		cols := glyph(r)
		for _, c := range cols {
			if x >= 0 && x < Width {
				if inverted {
					f[line][x] &^= c
				} else {
					f[line][x] |= c
				}
			}
			x++
		}
		x++ // gap between characters
	}
}

// Big draws s twice the size over lines line and line+1, centered.
func (f *Frame) Big(line int, s string, inverted bool) {
	n := len([]rune(s))
	x := (Width - n*charWidth*2) / 2
	for _, r := range s {
		for _, c := range glyph(r) {
			var tall uint16 // each source row becomes two
			for row := 0; row < 8; row++ {
				if c>>row&1 == 1 {
					tall |= 0b11 << (2 * row)
				}
			}
			for dx := 0; dx < 2; dx++ {
				if x+dx >= 0 && x+dx < Width {
					top, bottom := byte(tall), byte(tall>>8)
					if inverted {
						f[line][x+dx] &^= top
						f[line+1][x+dx] &^= bottom
					} else {
						f[line][x+dx] |= top
						f[line+1][x+dx] |= bottom
					}
				}
			}
			x += 2
		}
		x += 2
	}
}

// Fill lights (or clears) whole text lines.
func (f *Frame) Fill(from, to int, on bool) {
	v := byte(0)
	if on {
		v = 0xFF
	}
	for p := from; p <= to; p++ {
		for x := range f[p] {
			f[p][x] = v
		}
	}
}

// Status is everything the screen shows, gathered once per refresh.
type Status struct {
	ESP32     bool          // the ESP32 is talking
	Telemetry *pb.Telemetry // nil before the first one
	Apps      int           // apps connected over the WebSocket
	Network   string        // "Wi-Fi <ssid>", "Cabo de rede" or ""
	IP        string        // main address, "" when offline
	Tailscale string        // tailnet address, "" when not logged in
	Version   string        // hexd version
	Stopped   bool          // hexd is shutting down
}

// Page is one screen of the rotation.
type Page int

const (
	PageAlert Page = iota // only when something needs attention
	PageStatus
	PageNetwork
)

// Pages lists the screens to rotate through, the alert first.
func Pages(s Status) []Page {
	if _, alert := Alert(s); alert {
		return []Page{PageAlert, PageStatus, PageNetwork}
	}
	return []Page{PageStatus, PageNetwork}
}

// Alert is the headline and the detail of what needs attention, if anything.
func Alert(s Status) (headline [2]string, ok bool) {
	t := s.Telemetry
	switch {
	case !s.ESP32:
		return [2]string{"ESP32", "sem resposta"}, true
	case t == nil:
		return [2]string{}, false
	case t.GasAlarm:
		return [2]string{"GÁS!", "gás ou fumaça"}, true
	case t.State == pb.State_STATE_ESTOP:
		return [2]string{"PARADO", "segure LEVANTAR"}, true
	case t.State == pb.State_STATE_TIPPED:
		return [2]string{"TOMBOU", "desvire o robô"}, true
	case t.State == pb.State_STATE_LOW_BATTERY:
		return [2]string{"BATERIA", "carregue a bateria"}, true
	}
	return [2]string{}, false
}

// stateText is the robot's situation in a few capitals, for the header.
func stateText(t *pb.Telemetry) string {
	if t == nil {
		return "..."
	}
	switch t.State {
	case pb.State_STATE_NORMAL:
		switch t.Mode {
		case pb.Mode_MODE_SIT:
			return "SENTADO"
		case pb.Mode_MODE_WALK:
			return "ANDANDO"
		case pb.Mode_MODE_FRONT_LEGS:
			return "PATAS"
		case pb.Mode_MODE_CALIBRATE:
			return "CALIBRANDO"
		default:
			return "EM PÉ"
		}
	case pb.State_STATE_STOPPING:
		return "PARANDO"
	case pb.State_STATE_SAFE_SIT:
		return "SEGURANÇA"
	case pb.State_STATE_RELAXED:
		return "RELAXADO"
	case pb.State_STATE_BLOCKED:
		return "OBSTÁCULO"
	case pb.State_STATE_LOW_BATTERY:
		return "BATERIA"
	case pb.State_STATE_TIPPED:
		return "TOMBOU"
	case pb.State_STATE_ESTOP:
		return "PARADO"
	}
	return "?"
}

// Lines is the text of a page (alert pages use Alert instead), one string
// per text line. Line 0 is the header.
func Lines(s Status, p Page) []string {
	if s.Stopped {
		return []string{header("PARADO"), "", "hexd parado", "", "Reinicia sozinho;", "se não voltar, veja", "o log do Pi."}
	}
	switch p {
	case PageNetwork:
		lines := []string{header("REDE"), ""}
		if s.IP == "" {
			lines = append(lines, "Sem rede")
		} else {
			lines = append(lines, cut(orDash(s.Network)), "IP "+s.IP, "hexapod.local")
		}
		if s.Tailscale != "" {
			lines = append(lines, "TS "+s.Tailscale)
		}
		return append(lines, "", "hexd "+cut(s.Version))
	default:
		t := s.Telemetry
		esp := "ESP32: ok"
		if !s.ESP32 {
			esp = "ESP32: sem resposta"
		}
		return []string{header(stateText(t)), "", apps(s.Apps), esp, battery(t), "", cut(orDash(s.IP))}
	}
}

// header is "HEXAPOD" on the left and right on the right of a full line.
func header(right string) string {
	const left = "HEXAPOD"
	pad := lineChars - len([]rune(left)) - len([]rune(right)) - 1
	if pad < 1 {
		pad = 1
	}
	return " " + left + strings.Repeat(" ", pad) + right
}

func apps(n int) string {
	switch n {
	case 0:
		return "App: nenhum"
	case 1:
		return "App: conectado"
	default:
		return fmt.Sprintf("App: %d conectados", n)
	}
}

// battery reads the pack voltage, or says the meter is missing.
func battery(t *pb.Telemetry) string {
	if t == nil || t.FaultFlags&uint32(pb.Fault_FAULT_POWER_MONITOR) != 0 || t.BatteryVoltageV <= 0 {
		return "Bateria: sem medidor"
	}
	v := float64(t.BatteryVoltageV)
	return fmt.Sprintf("Bateria: %.1fV %d%%", v, batteryPercent(v))
}

// batteryPercent: 3S LiPo resting curve (same as the app's).
func batteryPercent(volts float64) int {
	cell := volts / 3
	curve := []struct {
		v float64
		p int
	}{{3.30, 0}, {3.50, 5}, {3.68, 20}, {3.74, 35}, {3.80, 50}, {3.87, 65}, {3.95, 80}, {4.06, 90}, {4.20, 100}}
	if cell <= curve[0].v {
		return 0
	}
	for i := 1; i < len(curve); i++ {
		if cell <= curve[i].v {
			a, b := curve[i-1], curve[i]
			return a.p + int(math.Round(float64(b.p-a.p)*(cell-a.v)/(b.v-a.v)))
		}
	}
	return 100
}

func orDash(s string) string {
	if s == "" {
		return "-"
	}
	return s
}

// cut keeps s within one text line.
func cut(s string) string {
	r := []rune(s)
	if len(r) <= lineChars {
		return s
	}
	return string(r[:lineChars-1]) + "~"
}

// Render draws page p, shifted right by shift pixels (0-2, moved over time
// so fixed text does not burn into the OLED).
func Render(s Status, p Page, shift int) *Frame {
	var f Frame
	if p == PageAlert && !s.Stopped {
		if a, ok := Alert(s); ok {
			f.Fill(0, pages-1, true)
			f.Big(2, a[0], true)
			f.Text(6, shift+(Width-len([]rune(a[1]))*charWidth)/2, a[1], true)
			return &f
		}
	}
	for i, line := range Lines(s, p) {
		if i >= pages {
			break
		}
		if i == 0 {
			f.Fill(0, 0, true)
			f.Text(0, shift, line, true)
			continue
		}
		f.Text(i, shift+2, line, false)
	}
	return &f
}
