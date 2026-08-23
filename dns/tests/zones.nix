{
  "example.test" = {
    records = [
      {
        type = "A";
        name = "@";
        address = "192.0.2.10";
        proxied = true;
        ttl = "auto";
      }
      {
        type = "CNAME";
        name = "www";
        target = "origin.example.net.";
        proxied = false;
        ttl = 300;
      }
      {
        type = "ALIAS";
        name = "@";
        target = "pages.example.net.";
        proxied = true;
        ttl = "auto";
      }
      {
        type = "MX";
        name = "@";
        priority = 10;
        exchange = "mail.example.test.";
        ttl = 3600;
      }
      {
        type = "TXT";
        name = "@";
        text = "v=spf1 -all";
        ttl = 3600;
      }
    ];
  };
}
