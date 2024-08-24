
function FindProxyForURL(url, host) {
    const proxy = "SOCKS 192.168.0.20:1080";

    if (host == "2ip.ru")
        return proxy;

    if (host == "youtube.com" || dnsDomainIs(host, ".youtube.com") || dnsDomainIs(host, ".googlevideo.com") || dnsDomainIs(host, ".ytimg.com"))
        return proxy;

    if (host == "ntc.party")
        return proxy;

    if (host == "chatgpt.com" ||dnsDomainIs(host, ".chatgpt.com") )
        return proxy;

    if (host == "openai.com" || dnsDomainIs(host, ".openai.com"))
        return proxy;

    return "DIRECT";
}