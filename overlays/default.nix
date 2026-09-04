[
  (final: prev:
    {
      n8n = prev.n8n.overrideAttrs (oldAttrs: {
        NODE_OPTIONS = "--max-old-space-size=4096";
      });

      bulwark-webmail = prev.callPackage ../pkgs/bulwark-webmail { };
    }
    // prev.lib.optionalAttrs (builtins.elem prev.stdenv.hostPlatform.system [
      "x86_64-linux"
      "aarch64-linux"
    ]) {
      kaiten-mcp = prev.callPackage ../pkgs/kaiten-mcp { };
    })
]
