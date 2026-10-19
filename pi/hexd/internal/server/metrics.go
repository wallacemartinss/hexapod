package server

import (
	"bufio"
	"fmt"
	"io"
	"net/http"
	"os"
	"sort"
	"strconv"
	"strings"
	"time"

	pb "github.com/wallacemartinss/hexapod/pi/hexd/gen/hexapod/v1"
)

var sensorNames = [4]string{"front", "right", "rear", "left"}

// handleMetrics writes the Prometheus text exposition format by hand: a few
// gauges do not justify the client library on a Pi 3.
func (s *Server) handleMetrics(w http.ResponseWriter, _ *http.Request) {
	w.Header().Set("Content-Type", "text/plain; version=0.0.4")
	snap := s.dev.Snapshot()
	s.mu.Lock()
	clients, trips, commands, rejected := s.clients, s.deadmanTrips, s.commands, s.rejected
	profile := s.profile
	s.mu.Unlock()

	m := &metricWriter{w: w}
	m.gauge("hexapod_esp32_up", "1 if the serial link to the ESP32 is open", b2f(snap.Connected))
	if !snap.LastRx.IsZero() {
		m.gauge("hexapod_esp32_last_rx_age_seconds", "time since the last frame from the ESP32",
			time.Since(snap.LastRx).Seconds())
	}
	m.counter("hexapod_esp32_reconnects_total", "serial link reopenings", float64(snap.Reconnects))
	m.counter("hexapod_link_frames_total", "valid frames from the ESP32", float64(snap.Stats.Frames))
	m.header("hexapod_link_errors_total", "dropped frames from the ESP32", "counter")
	m.sample("hexapod_link_errors_total", `kind="cobs"`, float64(snap.Stats.COBSErrors))
	m.sample("hexapod_link_errors_total", `kind="crc"`, float64(snap.Stats.CRCErrors))
	m.sample("hexapod_link_errors_total", `kind="overflow"`, float64(snap.Stats.Overflows))
	m.gauge("hexapod_app_clients", "connected WebSocket clients", float64(clients))
	m.counter("hexapod_commands_total", "app commands forwarded to the ESP32", float64(commands))
	m.counter("hexapod_commands_rejected_total", "app commands not forwarded (link not ready)", float64(rejected))
	m.counter("hexapod_deadman_trips_total", "times the app went silent", float64(trips))
	m.gauge("hexapod_link_profile_cellular", "1 if the failsafe uses the 4G timeouts",
		b2f(profile == pb.LinkProfile_LINK_PROFILE_CELLULAR))

	if t := snap.Telemetry; t != nil {
		m.header("hexapod_state", "failsafe state (1 for the current one)", "gauge")
		names := make([]string, 0, len(pb.State_name))
		for _, n := range pb.State_name {
			if n != "STATE_UNSPECIFIED" {
				names = append(names, n)
			}
		}
		sort.Strings(names)
		for _, n := range names {
			m.sample("hexapod_state", fmt.Sprintf("state=%q", strings.TrimPrefix(n, "STATE_")),
				b2f(t.State.String() == n))
		}
		m.gauge("hexapod_fault_flags", "OR of hexapod.v1.Fault bits", float64(t.FaultFlags))
		m.gauge("hexapod_battery_voltage_volts", "battery pack voltage", float64(t.BatteryVoltageV))
		m.gauge("hexapod_battery_current_amperes", "battery current (needs the right INA226 shunt)",
			float64(t.BatteryCurrentA))
		m.header("hexapod_distance_millimeters", "VL53L0X readings", "gauge")
		for i, d := range t.DistancesMm {
			if i < len(sensorNames) {
				m.sample("hexapod_distance_millimeters", fmt.Sprintf("sensor=%q", sensorNames[i]), float64(d))
			}
		}
		m.gauge("hexapod_roll_degrees", "body roll", float64(t.RollDeg))
		m.gauge("hexapod_pitch_degrees", "body pitch", float64(t.PitchDeg))
		m.gauge("hexapod_motion_loop_seconds", "last 50 Hz motion loop duration", float64(t.LoopTimeUs)/1e6)
		m.gauge("hexapod_esp32_temperature_celsius", "ESP32 internal temperature", float64(t.Esp32TemperatureC))
		m.gauge("hexapod_ambient_temperature_celsius", "BME280 temperature", float64(t.TemperatureC))
		m.gauge("hexapod_ambient_humidity_percent", "BME280 humidity", float64(t.HumidityPct))
		m.gauge("hexapod_ambient_pressure_hpa", "BME280 pressure", float64(t.PressureHpa))
		m.gauge("hexapod_gas_level_percent", "MQ-2 level, % of ADC full scale (relative, not ppm)",
			float64(t.GasLevelPct))
		m.gauge("hexapod_gas_alarm", "1 while the MQ-2 level is well above its clean-air baseline",
			boolGauge(t.GasAlarm))
	}
	if s.cfg.Position != nil {
		if p, ok := s.cfg.Position(); ok {
			m.gauge("hexapod_gps_fix", "1 while the GPS has a position", boolGauge(p.Fix))
			m.gauge("hexapod_gps_satellites_used", "satellites in the position fix", float64(p.SatellitesUsed))
			m.gauge("hexapod_gps_satellites_in_view", "satellites the GPS sees", float64(p.SatellitesInView))
		}
	}
	if s.cfg.PiStatus != nil {
		if p := s.cfg.PiStatus(); p != nil {
			m.gauge("hexapod_pi_cpu_percent", "Pi CPU use, all cores", float64(p.CpuPercent))
			m.gauge("hexapod_pi_load1", "Pi 1-minute load average", float64(p.Load_1M))
			m.gauge("hexapod_pi_cpu_frequency_hertz", "Pi core 0 clock", float64(p.CpuFreqMhz)*1e6)
			m.gauge("hexapod_pi_memory_used_bytes", "Pi memory in use (total - available)", float64(p.MemUsedMb)*(1<<20))
			m.gauge("hexapod_pi_memory_total_bytes", "Pi memory", float64(p.MemTotalMb)*(1<<20))
			m.gauge("hexapod_pi_disk_used_bytes", "SD card space used (/opt/hexapod)", float64(p.DiskUsedMb)*(1<<20))
			m.gauge("hexapod_pi_disk_total_bytes", "SD card size (/opt/hexapod)", float64(p.DiskTotalMb)*(1<<20))
			m.gauge("hexapod_pi_under_voltage", "1 while the Pi supply is too low", boolGauge(p.UnderVoltage))
			m.gauge("hexapod_pi_under_voltage_seen", "1 if the supply was too low since hexd started",
				boolGauge(p.UnderVoltageSeen))
			m.gauge("hexapod_pi_uptime_seconds", "time since the Pi booted", float64(p.UptimeS))
			m.gauge("hexapod_pi_read_only", "1 while the root filesystem is the read-only overlay", boolGauge(p.ReadOnly))
		}
	}
	if v, ok := readPiTemperature(s.cfg.PiTemperaturePath); ok {
		m.gauge("hexapod_pi_temperature_celsius", "Raspberry Pi SoC temperature", v)
	}
	if v, ok := readRSSI(s.cfg.WirelessPath, s.cfg.WifiInterface); ok {
		m.gauge("hexapod_wifi_rssi_dbm", "Wi-Fi signal level", v)
	}
}

type metricWriter struct{ w io.Writer }

func (m *metricWriter) header(name, help, typ string) {
	fmt.Fprintf(m.w, "# HELP %s %s\n# TYPE %s %s\n", name, help, name, typ)
}
func (m *metricWriter) sample(name, labels string, v float64) {
	if labels != "" {
		name += "{" + labels + "}"
	}
	fmt.Fprintf(m.w, "%s %s\n", name, strconv.FormatFloat(v, 'g', -1, 64))
}
func (m *metricWriter) gauge(name, help string, v float64) {
	m.header(name, help, "gauge")
	m.sample(name, "", v)
}
func (m *metricWriter) counter(name, help string, v float64) {
	m.header(name, help, "counter")
	m.sample(name, "", v)
}

func b2f(b bool) float64 {
	if b {
		return 1
	}
	return 0
}

// readPiTemperature parses /sys/class/thermal/thermal_zone0/temp (milli-degC).
func readPiTemperature(path string) (float64, bool) {
	if path == "" {
		return 0, false
	}
	b, err := os.ReadFile(path)
	if err != nil {
		return 0, false
	}
	v, err := strconv.ParseFloat(strings.TrimSpace(string(b)), 64)
	return v / 1000, err == nil
}

// readRSSI parses the signal level of iface from /proc/net/wireless:
//
//	wlan0: 0000   55.  -55.  -256        0      0      0      0     12        0
func readRSSI(path, iface string) (float64, bool) {
	if path == "" || iface == "" {
		return 0, false
	}
	f, err := os.Open(path)
	if err != nil {
		return 0, false
	}
	defer f.Close()
	sc := bufio.NewScanner(f)
	for sc.Scan() {
		name, rest, ok := strings.Cut(strings.TrimSpace(sc.Text()), ":")
		if !ok || name != iface {
			continue
		}
		fields := strings.Fields(rest)
		if len(fields) < 3 {
			return 0, false
		}
		v, err := strconv.ParseFloat(strings.TrimSuffix(fields[2], "."), 64)
		return v, err == nil
	}
	return 0, false
}

func boolGauge(b bool) float64 {
	if b {
		return 1
	}
	return 0
}
