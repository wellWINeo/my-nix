{ pkgs, config }:

let
  inherit (pkgs.lib) hasInfix;
  summarizerConfig = config.roles.rss.summarizer._configTemplate;
  bloomberg = summarizerConfig.agents.bloomberg-daily;
  technical = summarizerConfig.agents.tech-daily;
  morningService = config.systemd.services.miniflux-summarizer-bloomberg-morning;
  eveningService = config.systemd.services.miniflux-summarizer-bloomberg-evening;
  morningTimer = config.systemd.timers.miniflux-summarizer-bloomberg-morning;
  eveningTimer = config.systemd.timers.miniflux-summarizer-bloomberg-evening;
  weekly = summarizerConfig.agents.tech-weekly;
  monthly = summarizerConfig.agents.tech-monthly;
  expectedGeneratedDigests = {
    type = "generated_digests";
  };
  expectedTechnicalIgnore = [
    {
      type = "subject";
      value = "Sponsored";
    }
    {
      type = "feed_id";
      value = "6";
    }
    {
      type = "category_id";
      value = "3";
    }
    {
      type = "category_id";
      value = "4";
    }
    expectedGeneratedDigests
  ];
  expectedBloombergIgnore = [
    {
      type = "subject";
      value = "Sponsored";
    }
    {
      type = "feed_id";
      value = "6";
    }
    expectedGeneratedDigests
  ];
  validation =
    assert bloomberg.sources == [
      {
        kind = "category";
        id = 4;
      }
    ];
    assert bloomberg.target_feed_id == 57;
    assert bloomberg.ignore == expectedBloombergIgnore;
    assert technical.sources == [
      {
        kind = "all";
      }
    ];
    assert technical.ignore == expectedTechnicalIgnore;
    assert weekly.sources == [
      {
        kind = "feed";
        id = 57;
      }
    ];
    assert monthly.sources == [
      {
        kind = "feed";
        id = 58;
      }
    ];
    assert builtins.elem expectedGeneratedDigests bloomberg.ignore;
    assert builtins.elem expectedGeneratedDigests technical.ignore;
    assert hasInfix "Bloomberg" bloomberg.prompt;
    assert hasInfix "financial" bloomberg.prompt;
    assert hasInfix "--agent bloomberg-daily" morningService.script;
    assert hasInfix "--preset daily-morning" morningService.script;
    assert hasInfix "--agent bloomberg-daily" eveningService.script;
    assert hasInfix "--preset daily-evening" eveningService.script;
    assert morningTimer.timerConfig.OnCalendar == "*-*-* 06:00:00 UTC";
    assert eveningTimer.timerConfig.OnCalendar == "*-*-* 18:00:00 UTC";
    true;
in
assert validation;
pkgs.runCommand "miniflux-summarizer-bloomberg-validation" { } ''
  touch "$out"
''
