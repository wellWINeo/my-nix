
function FindProxyForURL(url, host) {
    const proxy = "SOCKS 192.168.0.20:1080";

    if (host == "2ip.ru")
        return proxy;

    if (host == "youtube.com" || dnsDomainIs(host, ".youtube.com") || dnsDomainIs(host, ".googlevideo.com"))
        return proxy;

    if (host == "ntc.party")
        return proxy;

    return "DIRECT";
}