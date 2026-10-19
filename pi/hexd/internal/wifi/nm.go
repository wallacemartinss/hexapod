// Package wifi runs the robot's Wi-Fi through NetworkManager (nmcli): its
// own network ("Hexapode-<id>", for the app to connect directly) and the
// home networks the app saves, falling back to its own network whenever no
// home network works.
package wifi

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"strconv"
	"strings"
)

// Runner runs nmcli with args and returns its stdout; on failure the error
// carries stderr (tests replace it).
type Runner func(ctx context.Context, args ...string) (string, error)

// Nmcli runs the real nmcli.
func Nmcli(ctx context.Context, args ...string) (string, error) {
	cmd := exec.CommandContext(ctx, "nmcli", args...)
	// Untranslated messages: joinError reads them (the Pi may run in pt_BR).
	cmd.Env = append(os.Environ(), "LC_ALL=C")
	var out, errOut bytes.Buffer
	cmd.Stdout, cmd.Stderr = &out, &errOut
	if err := cmd.Run(); err != nil {
		return out.String(), fmt.Errorf("nmcli %s: %w: %s", args[0], err, strings.TrimSpace(errOut.String()))
	}
	return out.String(), nil
}

// NM is the subset of NetworkManager the robot needs.
type NM struct {
	Run   Runner
	Iface string // wlan0
}

// apName is the NetworkManager profile of the robot's own network.
const apName = "hexapod-ap"

// homePrefix names the profiles the app creates (the netplan one from the
// SD card image is a home network too).
const homePrefix = "hexapod-home-"

// Network is a Wi-Fi network seen in a scan.
type Network struct {
	SSID   string `json:"ssid"`
	Signal int    `json:"signal"` // 0-100
	Secure bool   `json:"secure"`
}

// Device is the Wi-Fi interface right now.
type Device struct {
	Present    bool   // the chip is up (under-voltage can make it vanish)
	Connection string // active NetworkManager profile, "" when none
	IP         string
}

// splitTerse splits one line of `nmcli -t` output (':' separated, with
// '\:' and '\\' escapes).
func splitTerse(line string) []string {
	var fields []string
	var cur strings.Builder
	for i := 0; i < len(line); i++ {
		switch c := line[i]; {
		case c == '\\' && i+1 < len(line):
			i++
			cur.WriteByte(line[i])
		case c == ':':
			fields = append(fields, cur.String())
			cur.Reset()
		default:
			cur.WriteByte(c)
		}
	}
	return append(fields, cur.String())
}

func lines(s string) []string {
	var out []string
	for _, l := range strings.Split(s, "\n") {
		if l = strings.TrimRight(l, "\r"); l != "" {
			out = append(out, l)
		}
	}
	return out
}

// Device reports the Wi-Fi interface.
func (n NM) Device(ctx context.Context) (Device, error) {
	out, err := n.Run(ctx, "-t", "-f", "DEVICE,TYPE,STATE,CONNECTION", "device")
	if err != nil {
		return Device{}, err
	}
	for _, l := range lines(out) {
		f := splitTerse(l)
		if len(f) < 4 || f[0] != n.Iface {
			continue
		}
		d := Device{Present: f[2] != "unavailable"}
		if f[2] == "connected" {
			d.Connection = f[3]
			d.IP = n.ip(ctx)
		}
		return d, nil
	}
	return Device{}, nil // no wlan0 at all
}

func (n NM) ip(ctx context.Context) string {
	out, err := n.Run(ctx, "-t", "-g", "IP4.ADDRESS", "device", "show", n.Iface)
	if err != nil {
		return ""
	}
	for _, l := range lines(out) {
		if addr, _, ok := strings.Cut(strings.Split(l, " | ")[0], "/"); ok {
			return addr
		}
	}
	return ""
}

// Saved lists the home networks NetworkManager knows: profile name -> SSID.
func (n NM) Saved(ctx context.Context) (map[string]string, error) {
	out, err := n.Run(ctx, "-t", "-f", "NAME,TYPE", "connection", "show")
	if err != nil {
		return nil, err
	}
	saved := map[string]string{}
	for _, l := range lines(out) {
		f := splitTerse(l)
		if len(f) < 2 || f[1] != "802-11-wireless" || f[0] == apName {
			continue
		}
		props, err := n.Run(ctx, "-t", "-g", "802-11-wireless.ssid,802-11-wireless.mode", "connection", "show", f[0])
		if err != nil {
			continue
		}
		p := lines(props)
		if len(p) >= 2 && p[1] == "ap" {
			continue
		}
		if len(p) >= 1 && p[0] != "" {
			saved[f[0]] = p[0]
		}
	}
	return saved, nil
}

// Scan lists the networks in range, strongest first, one entry per SSID.
func (n NM) Scan(ctx context.Context) ([]Network, error) {
	out, err := n.Run(ctx, "-t", "-f", "SSID,SIGNAL,SECURITY", "device", "wifi", "list", "--rescan", "yes", "ifname", n.Iface)
	if err != nil {
		return nil, err
	}
	best := map[string]Network{}
	var order []string
	for _, l := range lines(out) {
		f := splitTerse(l)
		if len(f) < 3 || f[0] == "" {
			continue // hidden network
		}
		signal, _ := strconv.Atoi(f[1])
		nw := Network{SSID: f[0], Signal: signal, Secure: f[2] != "" && f[2] != "--"}
		if old, ok := best[nw.SSID]; !ok || nw.Signal > old.Signal {
			if !ok {
				order = append(order, nw.SSID)
			}
			best[nw.SSID] = nw
		}
	}
	list := make([]Network, 0, len(order))
	for _, s := range order {
		list = append(list, best[s])
	}
	for i := 1; i < len(list); i++ { // strongest first (few entries)
		for j := i; j > 0 && list[j].Signal > list[j-1].Signal; j-- {
			list[j], list[j-1] = list[j-1], list[j]
		}
	}
	return list, nil
}

// EnsureAP creates or updates the robot's own network profile (WPA2, NAT
// and DHCP from NetworkManager, robot at 10.42.0.1). It does not start it.
func (n NM) EnsureAP(ctx context.Context, ssid, password string) error {
	settings := []string{
		"ifname", n.Iface, "ssid", ssid,
		"802-11-wireless.mode", "ap", "802-11-wireless.band", "bg",
		"ipv4.method", "shared", "ipv6.method", "disabled",
		"wifi-sec.key-mgmt", "wpa-psk", "wifi-sec.psk", password,
		"connection.autoconnect", "no",
	}
	if _, err := n.Run(ctx, "-t", "-g", "connection.id", "connection", "show", apName); err == nil {
		_, err = n.Run(ctx, append([]string{"connection", "modify", apName}, settings...)...)
		return err
	}
	_, err := n.Run(ctx, append([]string{"connection", "add", "type", "wifi", "con-name", apName}, settings...)...)
	return err
}

// Up activates a profile, waiting up to wait seconds.
func (n NM) Up(ctx context.Context, name string, wait int) error {
	_, err := n.Run(ctx, "--wait", strconv.Itoa(wait), "connection", "up", name)
	return err
}

// Down deactivates a profile (an already inactive one is fine).
func (n NM) Down(ctx context.Context, name string) error {
	_, err := n.Run(ctx, "connection", "down", name)
	return err
}

// AddHome saves a home network (replacing one with the same SSID made by
// the app) with autoconnect on, and returns its profile name.
func (n NM) AddHome(ctx context.Context, ssid, password string) (string, error) {
	name := homePrefix + ssid
	_, _ = n.Run(ctx, "connection", "delete", name) // replace, never duplicate
	args := []string{
		"connection", "add", "type", "wifi", "con-name", name, "ifname", n.Iface, "ssid", ssid,
		"connection.autoconnect", "yes", "connection.autoconnect-priority", "10",
	}
	if password != "" {
		args = append(args, "wifi-sec.key-mgmt", "wpa-psk", "wifi-sec.psk", password)
	}
	_, err := n.Run(ctx, args...)
	return name, err
}

// Delete removes a saved profile.
func (n NM) Delete(ctx context.Context, name string) error {
	_, err := n.Run(ctx, "connection", "delete", name)
	return err
}

// errBadPassword is how a failed join is told to the app.
var errBadPassword = errors.New("senha incorreta")

// joinError turns nmcli's failure into what the app shows.
func joinError(err error) error {
	msg := strings.ToLower(err.Error())
	switch {
	case strings.Contains(msg, "secrets were required") || strings.Contains(msg, "802-1x") ||
		strings.Contains(msg, "psk"):
		return errBadPassword
	case strings.Contains(msg, "no network with ssid") || strings.Contains(msg, "not found"):
		return errors.New("rede não encontrada")
	default:
		return errors.New("não conectou à rede")
	}
}
