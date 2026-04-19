{
  config,
  lib,
  pkgs,
  ...
}:

with lib;

let
  cfg = config.roles.rss.summarizer;
in
{
  options.roles.rss.summarizer = {
    enable = mkEnableOption "Miniflux RSS Summarizer";

    llmApiKeyFile = mkOption {
      type = types.str;
      description = "Path to file containing the LLM API key";
    };

    minifluxApiKeyFile = mkOption {
      type = types.str;
      description = "Path to file containing the Miniflux API key";
    };

    dailyTargetFeedId = mkOption {
      type = types.int;
      description = "Miniflux feed ID for daily digest output";
    };

    weeklySourceFeedId = mkOption {
      type = types.int;
      default = cfg.dailyTargetFeedId;
      description = "Miniflux feed ID used as source for weekly digest";
    };

    weeklyTargetFeedId = mkOption {
      type = types.int;
      description = "Miniflux feed ID for weekly digest output";
    };

    monthlySourceFeedId = mkOption {
      type = types.int;
      default = cfg.weeklyTargetFeedId;
      description = "Miniflux feed ID used as source for monthly digest";
    };

    monthlyTargetFeedId = mkOption {
      type = types.int;
      description = "Miniflux feed ID for monthly digest output";
    };
  };

  config = mkIf cfg.enable (
    let
      dailyPrompt = builtins.readFile ./prompts/daily.md;
      weeklyPrompt = builtins.readFile ./prompts/weekly.md;
      monthlyPrompt = builtins.readFile ./prompts/monthly.md;

      configTemplate = {
        miniflux = {
          base_url = "https://rss.${config.roles.rss.baseDomain}";
          api_key = "PLACEHOLDER";
        };
        llm = {
          model = "x-ai/grok-4.1-fast";
          base_url = "https://openrouter.ai/api/v1";
          api_key = "PLACEHOLDER";
        };
        agents = {
          tech-daily = {
            source = "raw_entries";
            target_feed_id = cfg.dailyTargetFeedId;
            prompt = dailyPrompt;
            ignore = [
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
            ];
            presets = {
              daily-morning = {
                title = "Daily morning digest for {{date}}";
                from = "-12h";
                to = null;
              };
              daily-evening = {
                title = "Daily evening digest for {{date}}";
                from = "-12h";
                to = null;
              };
            };
          };
          tech-weekly = {
            source = "digests";
            source_feed_id = cfg.weeklySourceFeedId;
            target_feed_id = cfg.weeklyTargetFeedId;
            prompt = weeklyPrompt;
            ignore = [ ];
            presets = {
              weekly = {
                title = "Weekly tech newsletter for {{date}}";
                from = "-7d";
                to = null;
              };
            };
          };
          tech-monthly = {
            source = "digests";
            source_feed_id = cfg.monthlySourceFeedId;
            target_feed_id = cfg.monthlyTargetFeedId;
            prompt = monthlyPrompt;
            ignore = [ ];
            presets = {
              monthly = {
                title = "Monthly tech newsletter for {{date}}";
                from = "-30d";
                to = null;
              };
            };
          };
        };
      };

      templateFile = pkgs.writeText "summarizer-config-template.json" (builtins.toJSON configTemplate);

      injectSecrets = ''
        cat ${templateFile} \
          | jq --arg llm_key "$(cat "$CREDENTIALS_DIRECTORY/llm-api-key")" \
               --arg mf_key "$(cat "$CREDENTIALS_DIRECTORY/miniflux-api-key")" \
               '.llm.api_key = $llm_key | .miniflux.api_key = $mf_key' \
          > /tmp/summarizer-config.json
      '';

      commonServiceConfig = {
        path = [
          pkgs.miniflux-summarizer
          pkgs.jq
        ];
        after = [ "network.target" ];
        serviceConfig = {
          Type = "oneshot";
          PrivateTmp = true;
          LoadCredential = [
            "llm-api-key:${cfg.llmApiKeyFile}"
            "miniflux-api-key:${cfg.minifluxApiKeyFile}"
          ];
        };
      };
    in
    {
      assertions = [
        {
          assertion = config.roles.rss.enable;
          message = "roles.rss.summarizer requires roles.rss to be enabled";
        }
      ];

      systemd.services.miniflux-summarizer-morning = commonServiceConfig // {
        description = "Miniflux Summarizer — Morning Digest";
        script = ''
          ${injectSecrets}
          exec miniflux-summarizer \
            --config /tmp/summarizer-config.json \
            --agent tech-daily \
            --preset daily-morning
        '';
      };

      systemd.services.miniflux-summarizer-evening = commonServiceConfig // {
        description = "Miniflux Summarizer — Evening Digest";
        script = ''
          ${injectSecrets}
          exec miniflux-summarizer \
            --config /tmp/summarizer-config.json \
            --agent tech-daily \
            --preset daily-evening
        '';
      };

      systemd.services.miniflux-summarizer-weekly = commonServiceConfig // {
        description = "Miniflux Summarizer — Weekly Newsletter";
        script = ''
          ${injectSecrets}
          exec miniflux-summarizer \
            --config /tmp/summarizer-config.json \
            --agent tech-weekly \
            --preset weekly
        '';
      };

      systemd.services.miniflux-summarizer-monthly = commonServiceConfig // {
        description = "Miniflux Summarizer — Monthly Newsletter";
        script = ''
          ${injectSecrets}
          exec miniflux-summarizer \
            --config /tmp/summarizer-config.json \
            --agent tech-monthly \
            --preset monthly
        '';
      };

      systemd.timers.miniflux-summarizer-morning = {
        wantedBy = [ "timers.target" ];
        timerConfig = {
          OnCalendar = "*-*-* 06:00:00 UTC";
          Persistent = true;
        };
      };

      systemd.timers.miniflux-summarizer-evening = {
        wantedBy = [ "timers.target" ];
        timerConfig = {
          OnCalendar = "*-*-* 18:00:00 UTC";
          Persistent = true;
        };
      };

      systemd.timers.miniflux-summarizer-weekly = {
        wantedBy = [ "timers.target" ];
        timerConfig = {
          OnCalendar = "Sun *-*-* 06:00:00 UTC";
          Persistent = true;
        };
      };

      systemd.timers.miniflux-summarizer-monthly = {
        wantedBy = [ "timers.target" ];
        timerConfig = {
          OnCalendar = "*-*-01 06:00:00 UTC";
          Persistent = true;
        };
      };
    }
  );
}
