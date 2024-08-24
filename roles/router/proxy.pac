
function FindProxyForURL(url, host) {
    const proxy = "SOCKS 192.168.0.20:1080";

    if (isPlainHostName(host) || host == "2ip.ru")
        return proxy;

    return "DIRECT";
}