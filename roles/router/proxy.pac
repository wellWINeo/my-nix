const hosts = [
  "2ip.ru", // just to check that it works

  // youtube
  "youtube.com",
  "googlevideo.com",
  "ytimg.com",
  "youtu.be",
  "googleapis.com",
  "gstatic.com",
  "ggpht.com",
  "googleusercontent.com",

  // rutracker
  "rutracker.org",
  "rutracker.cc",

  "ntc.party",

  "chatgpt.com",
  "openai.com",

  "deepl.com",

  // Grok & X
  "grok.com",
  "x.com",

  // linkedin
  "linkedin.com",
  "licdn.com",

  // jetbrains
  "jetbrains.com",
  "jb.gg",

  // whatsapp
  "whatsapp.com",
  "whatsapp.net",
]

function isMatch(host) {
  return hosts.some((h) => host === h || dnsDomainIs(host, "." + h));
}

function FindProxyForURL(url, host) {
  const proxy = "SOCKS 192.168.0.20:1080";

  if (isMatch(host)) return proxy;
  
  return "DIRECT";
}
