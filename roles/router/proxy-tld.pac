function FindProxyForURL(url, host) {
  host = host.split(":")[0].toLowerCase();

  if (
    dnsDomainIs(host, ".ru") ||
    dnsDomainIs(host, ".su") ||
    dnsDomainIs(host, ".xn--p1ai")
  ) {
    // .рф
    return "DIRECT";
  }

  return "SOCKS 192.168.0.20:1080";
}
