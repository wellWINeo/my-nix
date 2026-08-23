{
  records = [
    {
      type = "A";
      name = "mokosh";
      address = "104.248.201.56";
      proxied = false;
      ttl = "auto";
    }
    {
      type = "A";
      name = "@";
      address = "104.248.201.56";
      proxied = true;
      ttl = "auto";
    }
    {
      type = "A";
      name = "veles";
      address = "85.239.58.14";
      proxied = false;
      ttl = "auto";
    }
    {
      type = "CNAME";
      name = "blog";
      target = "uspenskiy.tech.";
      proxied = true;
      ttl = "auto";
    }
    {
      type = "CNAME";
      name = "gw";
      target = "mokosh.uspenskiy.su.";
      proxied = false;
      ttl = "auto";
    }
    {
      type = "CNAME";
      name = "mail";
      target = "mokosh.uspenskiy.su.";
      proxied = false;
      ttl = "auto";
    }
    {
      type = "MX";
      name = "@";
      priority = 0;
      exchange = "mokosh.uspenskiy.su.";
      ttl = "auto";
    }
    {
      type = "TXT";
      name = "default._domainkey";
      text = "v=DKIM1; k=ed25519; p=dxYWpcOjJWVR7BHdEpIIq2pfua4mgLVI+LoBbixRxqE=";
      ttl = "auto";
    }
    {
      type = "TXT";
      name = "_dmarc";
      text = "v=DMARC1;  p=quarantine; rua=mailto:048649a56a38489db9976224f65ef9a1@dmarc-reports.cloudflare.net";
      ttl = "auto";
    }
    {
      type = "TXT";
      name = "rsa._domainkey";
      text = "v=DKIM1; k=rsa; p=MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAkJF0Phngwj2pFOkSi20Et2QY+ZYYhrYh2GvtPFE8dWVPF6U15tvY+VCnPcEMJKew5x1x6sX8xWjKcdcLhiXvlfHic9grfFp2rhwJAWK3c3RTNXmdQG9dka7d8lwm/0WO9wWat3+p5QZuXDHfgu5B5Vg7YONadoUvmX9iO26szPMB+1QrmJF/RXZtJ+KpK95V0eCOWw8kTF4IDcZ1AxWKfjJnESxg34bLQ8kLkpEOsLmTkbW6xUlFuY+aj6rhW1ggyB8JIfxo6dQ+MCAWlfLhaCgX1VFA01C38g11r+mg+i49K0gkReofHEDwp+boc4ytewtob09sqhPFgqEnl9pxHwIDAQAB";
      ttl = "auto";
    }
    {
      type = "TXT";
      name = "@";
      text = "v=spf1 mx -all";
      ttl = "auto";
    }
  ];
}
