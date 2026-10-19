package sysinfo

import (
	"os"
	"path/filepath"
	"testing"
)

func write(t *testing.T, root, p, content string) {
	t.Helper()
	full := filepath.Join(root, p)
	if err := os.MkdirAll(filepath.Dir(full), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(full, []byte(content), 0o644); err != nil {
		t.Fatal(err)
	}
}

// A fake Pi 3: what the real files look like on the robot.
func fakePi(t *testing.T) string {
	root := t.TempDir()
	write(t, root, "/proc/stat", "cpu  1000 0 500 8000 500 0 0 0 0 0\ncpu0 1 2 3 4 5 0 0 0 0 0\n")
	write(t, root, "/proc/loadavg", "0.42 0.30 0.25 1/180 1234\n")
	write(t, root, "/proc/meminfo", "MemTotal:         926764 kB\nMemFree:  100 kB\nMemAvailable:     665240 kB\n")
	write(t, root, "/proc/uptime", "30843.52 120000.10\n")
	write(t, root, "/proc/net/wireless", "Inter-| sta-|   Quality\n face | tus | link level noise\n  wlan0: 0000   55.  -55.  -256        0      0      0      0     12        0\n")
	write(t, root, "/proc/mounts", "/dev/mmcblk0p2 / ext4 rw 0 0\nproc /proc proc rw 0 0\n")
	write(t, root, "/proc/device-tree/model", "Raspberry Pi 4 Model B Rev 1.5\x00")
	write(t, root, "/sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq", "600000\n")
	write(t, root, "/sys/devices/system/cpu/cpu0/cpufreq/cpuinfo_max_freq", "1200000\n")
	write(t, root, "/sys/class/thermal/thermal_zone0/temp", "53692\n")
	write(t, root, "/sys/class/hwmon/hwmon0/name", "cpu_thermal\n")
	write(t, root, "/sys/class/hwmon/hwmon1/name", "rpi_volt\n")
	write(t, root, "/sys/class/hwmon/hwmon1/in0_lcrit_alarm", "0\n")
	return root
}

func TestSampleReadsThePi(t *testing.T) {
	root := fakePi(t)
	s := &Sampler{Root: root, DataPath: root, WifiInterface: "wlan0"}
	st := s.Sample()
	if st.CpuPercent != 0 {
		t.Errorf("first sample has no CPU delta yet, got %v", st.CpuPercent)
	}
	if st.Load_1M != 0.42 || st.CpuFreqMhz != 600 || st.CpuMaxFreqMhz != 1200 {
		t.Errorf("load/freq: %v %v %v", st.Load_1M, st.CpuFreqMhz, st.CpuMaxFreqMhz)
	}
	if st.TemperatureC < 53.69 || st.TemperatureC > 53.70 {
		t.Errorf("temperature %v", st.TemperatureC)
	}
	if st.MemTotalMb != 905 || st.MemUsedMb != 255 {
		t.Errorf("memory %v of %v MB", st.MemUsedMb, st.MemTotalMb)
	}
	if st.Model != "Raspberry Pi 4 Model B Rev 1.5" {
		t.Errorf("model %q", st.Model)
	}
	if st.DiskTotalMb == 0 {
		t.Error("disk: no size for the data path")
	}
	if st.UptimeS != 30843 || st.WifiRssiDbm != -55 || st.ReadOnly || st.UnderVoltage {
		t.Errorf("uptime %v rssi %v ro %v uv %v", st.UptimeS, st.WifiRssiDbm, st.ReadOnly, st.UnderVoltage)
	}

	// 1000 more jiffies, 250 of them busy: 25 %.
	write(t, root, "/proc/stat", "cpu  1200 0 550 8700 550 0 0 0 0 0\n")
	if st := s.Sample(); st.CpuPercent != 25 {
		t.Errorf("cpu %v %%, want 25", st.CpuPercent)
	}
}

func TestUnderVoltageIsRemembered(t *testing.T) {
	root := fakePi(t)
	s := &Sampler{Root: root}
	write(t, root, "/sys/class/hwmon/hwmon1/in0_lcrit_alarm", "1\n")
	if st := s.Sample(); !st.UnderVoltage || !st.UnderVoltageSeen {
		t.Errorf("low supply now: %v seen: %v", st.UnderVoltage, st.UnderVoltageSeen)
	}
	write(t, root, "/sys/class/hwmon/hwmon1/in0_lcrit_alarm", "0\n")
	if st := s.Sample(); st.UnderVoltage || !st.UnderVoltageSeen {
		t.Errorf("recovered: now %v, but it must stay seen (%v)", st.UnderVoltage, st.UnderVoltageSeen)
	}
	if s.Latest() == nil {
		t.Error("Latest is empty after a sample")
	}
}

func TestReadOnlyRootIsTheOverlay(t *testing.T) {
	root := fakePi(t)
	write(t, root, "/proc/mounts", "/dev/mmcblk0p2 / ext4 ro 0 0\noverlayroot / overlay rw 0 0\n")
	if !(&Sampler{Root: root}).Sample().ReadOnly {
		t.Error("overlay root not reported as read-only")
	}
}

func TestNotAPi(t *testing.T) {
	st := (&Sampler{Root: t.TempDir(), WifiInterface: "wlan0"}).Sample()
	if st.CpuFreqMhz != 0 || st.MemTotalMb != 0 || st.UnderVoltage || st.WifiRssiDbm != 0 {
		t.Errorf("missing sources must read as zero: %v", st)
	}
}
