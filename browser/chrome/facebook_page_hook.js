(() => {
  const sourceAttribute = 'data-idm-facebook-playable-url';
  const sourceKeys = new Set([
    'playable_url_quality_hd',
    'playable_url',
    'browser_native_hd_url',
    'browser_native_sd_url',
    'progressive_url',
    'playable_url_dash',
    'dash_manifest_url',
    'manifest_url',
  ]);
  let currentPriority = 0;

  function parseFacebookResponse(value) {
    if (typeof value !== 'string') return value;
    const start = value.indexOf('{');
    if (start < 0) return null;
    try {
      return JSON.parse(value.slice(start));
    } catch (_) {
      return null;
    }
  }

  function isPlayableUrl(value) {
    try {
      const url = new URL(value);
      const isMp4 = /\.mp4$/i.test(url.pathname);
      const isMpd = /\.mpd$/i.test(url.pathname);
      return (
        url.protocol === 'https:' &&
        (url.hostname === 'fbcdn.net' || url.hostname.endsWith('.fbcdn.net')) &&
        (isMp4 || isMpd) &&
        (!isMp4 || ![...url.searchParams.keys()].some((key) =>
          /^(?:byte(start|end)|range)$/i.test(key),
        ))
      );
    } catch (_) {
      return false;
    }
  }

  function writeSource(value) {
    if (!isPlayableUrl(value)) return;
    const priority = /\.mpd(?:$|\?)/i.test(value) ? 3 : 2;
    if (priority < currentPriority) return;
    currentPriority = priority;
    const root = document.documentElement;
    if (root) root.setAttribute(sourceAttribute, value);
  }

  function inspect(value, depth = 0) {
    if (!value || typeof value !== 'object' || depth > 24) return;
    if (Array.isArray(value)) {
      for (const child of value) inspect(child, depth + 1);
      return;
    }
    for (const [key, child] of Object.entries(value)) {
      if (sourceKeys.has(key) && typeof child === 'string') writeSource(child);
      if (child && typeof child === 'object') inspect(child, depth + 1);
    }
  }

  function inspectResponse(response, requestUrl) {
    if (!/\/api\/graphql\//i.test(requestUrl)) return;
    void response.text()
      .then((text) => inspect(parseFacebookResponse(text)))
      .catch(() => {});
  }

  const originalFetch = window.fetch;
  if (typeof originalFetch === 'function') {
    window.fetch = function (...args) {
      const requestUrl = String(args[0]?.url || args[0] || '');
      return originalFetch.apply(this, args).then((response) => {
        try {
          inspectResponse(response.clone(), requestUrl);
        } catch (_) {
          // Preserve the page's fetch behavior if response inspection fails.
        }
        return response;
      });
    };
  }

  const originalOpen = XMLHttpRequest.prototype.open;
  XMLHttpRequest.prototype.open = function (method, url, ...rest) {
    this.__idmRequestUrl = String(url || '');
    return originalOpen.call(this, method, url, ...rest);
  };

  const originalSend = XMLHttpRequest.prototype.send;
  XMLHttpRequest.prototype.send = function (...args) {
    this.addEventListener('load', () => {
      if (!/\/api\/graphql\//i.test(this.__idmRequestUrl || '')) return;
      try {
        const response = this.responseType === 'json'
          ? this.response
          : parseFacebookResponse(this.responseText);
        inspect(response);
      } catch (_) {
        // Ignore responses the page does not expose as readable text or JSON.
      }
    }, { once: true });
    return originalSend.apply(this, args);
  };
})();
