package display

import (
	"context"
	"net"
	"os/exec"
	"strings"
	"time"
)

// Network finds what the screen says about the network: the label
// ("Wi-Fi <ssid>" or "Cabo de rede"), the main IPv4 and the tailnet one.
// Wi-Fi wins over the cable, as the app usually comes over Wi-Fi.
func Network(wifi, wired, tailnet string) (label, ip, tailscale string) {
	if ip = ipv4(wifi); ip != "" {
		label = "Wi-Fi"
		if ssid := ssidOf(wifi); ssid != "" {
			label += " " + ssid
		}
	} else if ip = ipv4(wired); ip != "" {
		label = "Cabo de rede"
	}
	return label, ip, ipv4(tailnet)
}

func ipv4(iface string) string {
	i, err := net.InterfaceByName(iface)
	if err != nil {
		return ""
	}
	addrs, err := i.Addrs()
	if err != nil {
		return ""
	}
	for _, a := range addrs {
		if n, ok := a.(*net.IPNet); ok && n.IP.To4() != nil {
			return n.IP.String()
		}
	}
	return ""
}

// ssidOf asks iw (no root needed) which network the interface joined.
func ssidOf(iface string) string {
	ctx, cancel := context.WithTimeout(context.Background(), time.Second)
	defer cancel()
	out, err := exec.CommandContext(ctx, "iw", "dev", iface, "link").Output()
	if err != nil {
		return ""
	}
	return parseSSID(string(out))
}

func parseSSID(iwLink string) string {
	for _, line := range strings.Split(iwLink, "\n") {
		if s, ok := strings.CutPrefix(strings.TrimSpace(line), "SSID: "); ok {
			return s
		}
	}
	return ""
}
