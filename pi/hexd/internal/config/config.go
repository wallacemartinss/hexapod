// Package config loads hexd.yaml (/opt/hexapod/shared/config/hexd.yaml on the
// Pi). Every field has a default, so an empty file is a valid configuration.
package config

import (
	"bytes"
	"errors"
	"fmt"
	"io"
	"os"
	"time"

	"go.yaml.in/yaml/v3"
)

// Config mirrors pi/hexd/hexd.yaml. Durations use Go syntax ("150ms", "10s").
type Config struct {
	Listen string `yaml:"listen"`
	Serial struct {
		Device       string        `yaml:"device"` // path, tcp://host:port or unix:///path
		Baud         int           `yaml:"baud"`
		SilenceLimit time.Duration `yaml:"silence_limit"`
	} `yaml:"serial"`
	Deadman struct {
		Wifi               time.Duration `yaml:"wifi"`
		Cellular           time.Duration `yaml:"cellular"`
		CellularInterfaces []string      `yaml:"cellular_interfaces"`
	} `yaml:"deadman"`
	HealthMaxAge time.Duration `yaml:"health_max_age"`
	Metrics      struct {
		PiTemperaturePath string `yaml:"pi_temperature_path"`
		WirelessPath      string `yaml:"wireless_path"`
		WifiInterface     string `yaml:"wifi_interface"`
	} `yaml:"metrics"`
	Shutdown struct {
		Enabled bool          `yaml:"enabled"`
		Delay   time.Duration `yaml:"delay"`
		Command []string      `yaml:"command"`
	} `yaml:"shutdown"`
}

// Default returns the configuration used when a key is missing.
func Default() Config {
	var c Config
	c.Listen = ":8080"
	c.Serial.Device = "/dev/hexapod-esp32"
	c.Serial.Baud = 115200
	c.Serial.SilenceLimit = 3 * time.Second
	c.Deadman.Wifi = 150 * time.Millisecond
	c.Deadman.Cellular = 400 * time.Millisecond
	c.Deadman.CellularInterfaces = []string{"wwan", "ppp"}
	c.HealthMaxAge = 2 * time.Second
	c.Metrics.PiTemperaturePath = "/sys/class/thermal/thermal_zone0/temp"
	c.Metrics.WirelessPath = "/proc/net/wireless"
	c.Metrics.WifiInterface = "wlan0"
	c.Shutdown.Enabled = true
	c.Shutdown.Delay = 10 * time.Second
	c.Shutdown.Command = []string{"systemctl", "poweroff"}
	return c
}

// Load reads path over the defaults. A missing file means all defaults;
// unknown keys are an error (typos must not silently fall back).
func Load(path string) (Config, error) {
	c := Default()
	b, err := os.ReadFile(path)
	if os.IsNotExist(err) {
		return c, nil
	}
	if err != nil {
		return c, err
	}
	dec := yaml.NewDecoder(bytes.NewReader(b))
	dec.KnownFields(true)
	if err := dec.Decode(&c); err != nil && !errors.Is(err, io.EOF) { // EOF: empty file
		return c, fmt.Errorf("%s: %w", path, err)
	}
	return c, c.validate()
}

func (c Config) validate() error {
	switch {
	case c.Serial.Device == "":
		return fmt.Errorf("serial.device is empty")
	case c.Deadman.Wifi <= 0 || c.Deadman.Cellular <= 0:
		return fmt.Errorf("deadman timeouts must be positive")
	case c.Shutdown.Enabled && len(c.Shutdown.Command) == 0:
		return fmt.Errorf("shutdown.command is empty")
	}
	return nil
}
