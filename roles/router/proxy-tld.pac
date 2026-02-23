const SS_PROXY = "SOCKS 192.168.0.20:1080";
const SB_PROXY = "SOCKS5 192.168.0.20:1081";

function FindProxyForURL(url, host) {
  host = host.split(":")[0].toLowerCase();

  if (
    dnsDomainIs(host, ".ru") ||
    dnsDomainIs(host, ".su") ||
    dnsDomainIs(host, ".xn--p1ai") ||
    dnsDomainIs(host, ".home") ||
    dnsDomainIs(host, ".local")
  ) {
    return "DIRECT";
  }

  return SB_PROXY;
}
