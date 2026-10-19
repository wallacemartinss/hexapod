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
	Auth struct {
		Required bool   `yaml:"required"` // apps must present the pairing key (QR on the OLED)
		Identity string `yaml:"identity"` // robot id, name and key; created on first start
	} `yaml:"auth"`
	WiFi struct {
		Enabled       bool          `yaml:"enabled"`        // own network + home networks from the app
		Interface     string        `yaml:"interface"`      // wlan0
		Settings      string        `yaml:"settings"`       // mode (home/direct), on the data partition
		FallbackAfter time.Duration `yaml:"fallback_after"` // no home network this long: own network
		OwnBand       string        `yaml:"own_band"`       // own network: auto (5 GHz if the chip has it), 5 or 2.4
	} `yaml:"wifi"`
	GPS struct {
		Enabled  bool    `yaml:"enabled"`
		Device   string  `yaml:"device"`
		Baud     int     `yaml:"baud"`
		Simulate bool    `yaml:"simulate"` // fake walk around the point below (no module needed)
		SimLat   float64 `yaml:"sim_latitude"`
		SimLon   float64 `yaml:"sim_longitude"`
	} `yaml:"gps"`
	Display struct {
		Enabled  bool          `yaml:"enabled"`
		Bus      string        `yaml:"bus"`
		Address  int           `yaml:"address"`
		PageTime time.Duration `yaml:"page_time"`
		Wired    string        `yaml:"wired_interface"`
		Tailnet  string        `yaml:"tailnet_interface"`
	} `yaml:"display"`
	Tailscale struct {
		Enabled bool `yaml:"enabled"` // remote access set up from the app (needs auth.required)
	} `yaml:"tailscale"`
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
	c.Auth.Required = true
	c.Auth.Identity = "/opt/hexapod/shared/config/identity.json"
	c.WiFi.Enabled = true // needs the pairing key (the own network's password comes from it)
	c.WiFi.Interface = "wlan0"
	c.WiFi.Settings = "/opt/hexapod/shared/config/network.json"
	c.WiFi.FallbackAfter = 45 * time.Second
	c.WiFi.OwnBand = "auto"
	c.GPS.Enabled = true // a missing GPS is only logged
	c.GPS.Device = "/dev/serial0"
	c.GPS.Baud = 9600
	c.GPS.SimLat, c.GPS.SimLon = -23.5505, -46.6333
	c.Display.Enabled = true // a missing panel is only logged
	c.Display.Bus = "/dev/i2c-1"
	c.Display.Address = 0x3C
	c.Display.PageTime = 5 * time.Second
	c.Display.Wired = "eth0"
	c.Display.Tailnet = "tailscale0"
	c.Tailscale.Enabled = true // without tailscale installed the app is told so
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
	case c.Display.Enabled && c.Display.PageTime <= 0:
		return fmt.Errorf("display.page_time must be positive")
	case c.Display.Enabled && (c.Display.Address < 0x03 || c.Display.Address > 0x77):
		return fmt.Errorf("display.address 0x%02x is not a 7-bit I2C address", c.Display.Address)
	}
	return nil
}
