[
  (final: prev: {
    n8n = prev.n8n.overrideAttrs (oldAttrs: {
      buildPhase = ''
        export NODE_OPTIONS="--max-old-space-size=4096"
        ${oldAttrs.buildPhase or "true"}
      '';
    });
  })
]
