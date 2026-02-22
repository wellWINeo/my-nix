[
  (final: prev: {
    n8n = prev.n8n.overrideAttrs (oldAttrs: {
      NODE_OPTIONS = "--max-old-space-size=4096";
    });
  })
]
