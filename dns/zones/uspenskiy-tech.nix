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
      type = "CNAME";
      name = "ebooks";
      target = "mokosh.uspenskiy.tech.";
      proxied = true;
      ttl = "auto";
    }
    {
      type = "CNAME";
      name = "gw";
      target = "mokosh.uspenskiy.tech.";
      proxied = true;
      ttl = "auto";
    }
    {
      type = "CNAME";
      name = "readlater";
      target = "mokosh.uspenskiy.tech.";
      proxied = true;
      ttl = "auto";
    }
    {
      type = "CNAME";
      name = "rss";
      target = "mokosh.uspenskiy.tech.";
      proxied = true;
      ttl = "auto";
    }
    {
      type = "ALIAS";
      name = "@";
      target = "website-63n.pages.dev.";
      proxied = true;
      ttl = "auto";
    }
    {
      type = "CNAME";
      name = "vault";
      target = "mokosh.uspenskiy.su.";
      proxied = true;
      ttl = "auto";
    }
    {
      type = "TXT";
      name = "@";
      text = "google-site-verification=lsPPY-JWZW7_BDMm_n2rMRNpXGC1-W9vNOoI7qJJIi8";
      ttl = 3600;
    }
  ];
}
