// Package sysinfo samples the Raspberry Pi's own health (CPU, memory, SD
// card, power, temperature) from /proc and /sys into a hexapod.v1.PiStatus.
// Everything is read as the unprivileged hexd user: no vcgencmd (/dev/vcio
// is root-only), the under-voltage alarm comes from the rpi_volt hwmon.
package sysinfo

import (
	"bufio"
	"context"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"

	pb "github.com/wallacemartinss/hexapod/pi/hexd/gen/hexapod/v1"
)

// Sampler keeps the latest PiStatus. Safe for concurrent use.
type Sampler struct {
	// Root is prepended to every /proc and /sys path ("" in production;
	// a fake tree in tests).
	Root string
	// DataPath is the filesystem reported as the SD card (/opt/hexapod:
	// the real card even when the root is a RAM overlay).
	DataPath string
	// WifiInterface is the interface whose signal is reported (wlan0).
	WifiInterface string

	mu       sync.Mutex
	latest   *pb.PiStatus
	prevBusy uint64
	prevAll  uint64
	seenLow  bool
}

// Latest is the newest sample (nil before the first one).
func (s *Sampler) Latest() *pb.PiStatus {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.latest
}

// Run samples every period until ctx ends.
func (s *Sampler) Run(ctx context.Context, period time.Duration) {
	s.Sample()
	t := time.NewTicker(period)
	defer t.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-t.C:
			s.Sample()
		}
	}
}

// Sample reads everything once and stores it; sources that are missing
// (not a Pi, no Wi-Fi) are left at zero.
func (s *Sampler) Sample() *pb.PiStatus {
	st := &pb.PiStatus{}
	busy, all, cpuOK := s.cpuTimes()
	if v, ok := s.loadAvg(); ok {
		st.Load_1M = v
	}
	if v, ok := s.readInt("/sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq"); ok {
		st.CpuFreqMhz = uint32(v / 1000) // kHz
	}
	if v, ok := s.readInt("/sys/devices/system/cpu/cpu0/cpufreq/cpuinfo_max_freq"); ok {
		st.CpuMaxFreqMhz = uint32(v / 1000)
	}
	if v, ok := s.readInt("/sys/class/thermal/thermal_zone0/temp"); ok {
		st.TemperatureC = float32(v) / 1000 // milli-degC
	}
	if total, avail, ok := s.memInfo(); ok {
		st.MemTotalMb = uint32(total / 1024) // kB
		st.MemUsedMb = uint32((total - avail) / 1024)
	}
	if s.DataPath != "" {
		var fs syscall.Statfs_t
		if syscall.Statfs(s.DataPath, &fs) == nil {
			bs := uint64(fs.Bsize)
			st.DiskTotalMb = uint32(fs.Blocks * bs >> 20)
			st.DiskUsedMb = uint32((fs.Blocks - fs.Bfree) * bs >> 20)
		}
	}
	st.UnderVoltage = s.underVoltage()
	if v, ok := s.uptime(); ok {
		st.UptimeS = v
	}
	st.WifiRssiDbm = s.rssi()
	st.ReadOnly = s.rootIsOverlay()
	if b, err := os.ReadFile(s.path("/proc/device-tree/model")); err == nil {
		st.Model = strings.TrimRight(string(b), "\x00\n")
	}

	s.mu.Lock()
	defer s.mu.Unlock()
	if cpuOK && s.prevAll != 0 && all > s.prevAll {
		st.CpuPercent = float32(busy-s.prevBusy) / float32(all-s.prevAll) * 100
	}
	if cpuOK {
		s.prevBusy, s.prevAll = busy, all
	}
	s.seenLow = s.seenLow || st.UnderVoltage
	st.UnderVoltageSeen = s.seenLow
	s.latest = st
	return st
}

func (s *Sampler) path(p string) string { return filepath.Join(s.Root, p) }

func (s *Sampler) readInt(p string) (int64, bool) {
	b, err := os.ReadFile(s.path(p))
	if err != nil {
		return 0, false
	}
	v, err := strconv.ParseInt(strings.TrimSpace(string(b)), 10, 64)
	return v, err == nil
}

// cpuTimes sums the "cpu" line of /proc/stat: busy = all - idle - iowait.
func (s *Sampler) cpuTimes() (busy, all uint64, ok bool) {
	f, err := os.Open(s.path("/proc/stat"))
	if err != nil {
		return 0, 0, false
	}
	defer f.Close()
	sc := bufio.NewScanner(f)
	if !sc.Scan() {
		return 0, 0, false
	}
	fields := strings.Fields(sc.Text())
	if len(fields) < 5 || fields[0] != "cpu" {
		return 0, 0, false
	}
	var idle uint64
	for i, f := range fields[1:] {
		v, err := strconv.ParseUint(f, 10, 64)
		if err != nil {
			return 0, 0, false
		}
		all += v
		if i == 3 || i == 4 { // idle, iowait
			idle += v
		}
	}
	return all - idle, all, true
}

func (s *Sampler) loadAvg() (float32, bool) {
	b, err := os.ReadFile(s.path("/proc/loadavg"))
	if err != nil {
		return 0, false
	}
	fields := strings.Fields(string(b))
	if len(fields) == 0 {
		return 0, false
	}
	v, err := strconv.ParseFloat(fields[0], 32)
	return float32(v), err == nil
}

func (s *Sampler) memInfo() (total, avail uint64, ok bool) {
	f, err := os.Open(s.path("/proc/meminfo"))
	if err != nil {
		return 0, 0, false
	}
	defer f.Close()
	var gotTotal, gotAvail bool
	sc := bufio.NewScanner(f)
	for sc.Scan() {
		name, rest, _ := strings.Cut(sc.Text(), ":")
		fields := strings.Fields(rest)
		if len(fields) == 0 {
			continue
		}
		v, err := strconv.ParseUint(fields[0], 10, 64)
		if err != nil {
			continue
		}
		switch name {
		case "MemTotal":
			total, gotTotal = v, true
		case "MemAvailable":
			avail, gotAvail = v, true
		}
	}
	return total, avail, gotTotal && gotAvail && avail <= total
}

// underVoltage reads the alarm of the rpi_volt hwmon (1 while the supply
// is below the firmware's threshold).
func (s *Sampler) underVoltage() bool {
	names, _ := filepath.Glob(s.path("/sys/class/hwmon/hwmon*/name"))
	for _, n := range names {
		b, err := os.ReadFile(n)
		if err != nil || strings.TrimSpace(string(b)) != "rpi_volt" {
			continue
		}
		v, err := os.ReadFile(filepath.Join(filepath.Dir(n), "in0_lcrit_alarm"))
		return err == nil && strings.TrimSpace(string(v)) == "1"
	}
	return false
}

func (s *Sampler) uptime() (uint64, bool) {
	b, err := os.ReadFile(s.path("/proc/uptime"))
	if err != nil {
		return 0, false
	}
	fields := strings.Fields(string(b))
	if len(fields) == 0 {
		return 0, false
	}
	v, err := strconv.ParseFloat(fields[0], 64)
	return uint64(v), err == nil
}

// rssi parses the signal level of the Wi-Fi interface from /proc/net/wireless:
//
//	wlan0: 0000   55.  -55.  -256        0      0      0      0     12        0
func (s *Sampler) rssi() int32 {
	if s.WifiInterface == "" {
		return 0
	}
	f, err := os.Open(s.path("/proc/net/wireless"))
	if err != nil {
		return 0
	}
	defer f.Close()
	sc := bufio.NewScanner(f)
	for sc.Scan() {
		name, rest, ok := strings.Cut(strings.TrimSpace(sc.Text()), ":")
		if !ok || name != s.WifiInterface {
			continue
		}
		fields := strings.Fields(rest)
		if len(fields) < 3 {
			return 0
		}
		v, err := strconv.ParseFloat(strings.TrimSuffix(fields[2], "."), 64)
		if err != nil {
			return 0
		}
		return int32(v)
	}
	return 0
}

// rootIsOverlay: the read-only protection (overlayroot) mounts / as overlay.
func (s *Sampler) rootIsOverlay() bool {
	f, err := os.Open(s.path("/proc/mounts"))
	if err != nil {
		return false
	}
	defer f.Close()
	sc := bufio.NewScanner(f)
	ro := false
	for sc.Scan() {
		fields := strings.Fields(sc.Text())
		if len(fields) >= 3 && fields[1] == "/" {
			ro = fields[2] == "overlay" // the last mount of / wins
		}
	}
	return ro
}
