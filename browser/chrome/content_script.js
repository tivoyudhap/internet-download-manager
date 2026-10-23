chrome.runtime.onMessage.addListener((message, _sender, sendResponse) => {
  if (message?.type === 'idm_get_video_source') {
    const source = findVideoSource();
    if (source) sendResponse(source);
  }
});

const FLOATING_HOST_ID = 'idm-floating-download-host';

function installFloatingButton() {
  if (!document.querySelector('video') || document.getElementById(FLOATING_HOST_ID)) {
    return;
  }

  const host = document.createElement('div');
  host.id = FLOATING_HOST_ID;
  host.style.cssText =
    'all:initial;position:fixed;z-index:2147483647;pointer-events:none;';
  const shadow = host.attachShadow({ mode: 'closed' });
  const style = document.createElement('style');
  style.textContent = `
    button {
      all: initial;
      box-sizing: border-box;
      display: inline-flex;
      align-items: center;
      gap: 8px;
      min-height: 38px;
      padding: 0 14px;
      border: 1px solid rgba(255,255,255,.24);
      border-radius: 10px;
      background: #1769aa;
      box-shadow: 0 3px 14px rgba(0,0,0,.38);
      color: #fff;
      cursor: pointer;
      font: 600 13px/1 -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
      pointer-events: auto;
      transition: background .15s ease, opacity .15s ease;
    }
    button:hover:not(:disabled) { background: #0f5590; }
    button:disabled { cursor: wait; opacity: .72; }
    button:focus-visible { outline: 2px solid #fff; outline-offset: 2px; }
  `;
  const button = document.createElement('button');
  button.type = 'button';
  button.textContent = '↓  Download with IDM';
  button.title = 'Send this video to Internet Download Manager';
  shadow.append(style, button);
  document.documentElement.append(host);

  const positionButton = () => {
    const video = [...document.querySelectorAll('video')].find((item) => {
      const rect = item.getBoundingClientRect();
      return rect.width > 0 && rect.height > 0;
    });
    if (!video) {
      host.style.display = 'none';
      return;
    }
    const rect = video.getBoundingClientRect();
    host.style.display = '';
    host.style.top = `${Math.max(8, rect.top + 12)}px`;
    host.style.left = `${Math.max(8, rect.right - 194)}px`;
  };
  host.__idmPosition = positionButton;
  positionButton();
  window.addEventListener('resize', positionButton);
  window.addEventListener('scroll', positionButton, true);

  button.addEventListener('click', (event) => {
    event.preventDefault();
    event.stopPropagation();
    const source = findVideoSource();
    button.disabled = true;
    button.textContent = 'Sending to IDM…';
    chrome.runtime.sendMessage(
      { type: 'idm_download_video', source },
      (response) => {
        const error = chrome.runtime.lastError?.message || response?.error;
        button.textContent = error ? 'Could not send to IDM' : 'Added to IDM ✓';
        button.title = error || 'Download added to IDM.';
        setTimeout(() => {
          button.disabled = false;
          button.textContent = '↓  Download with IDM';
        }, 2500);
      },
    );
  });
}

function findVideoSource() {
  const pageHost = location.hostname.toLowerCase();
  if (isFacebookPage(pageHost)) {
    const playableSource = findFacebookPlayableSource();
    if (playableSource) return playableSource;
  }

  const videos = [...document.querySelectorAll('video')].sort(
    (a, b) => Number(a.paused) - Number(b.paused) || b.readyState - a.readyState,
  );

  for (const video of videos) {
    const candidates = [
      { url: video.currentSrc, type: '' },
      { url: video.src, type: '' },
      ...[...video.querySelectorAll('source')].map((source) => ({
        url: source.src || source.getAttribute('data-src') || '',
        type: source.type || '',
      })),
    ].filter((source) => source.url && !source.url.startsWith('blob:'));

    const playableSources = candidates
      .map((source) => ({ ...source, url: normalizeMediaUrl(source.url) }))
      .filter((source) => source.url);
    const selected =
      playableSources.find(isManifestSource) || playableSources[0];
    if (selected) {
      return {
        url: selected.url,
        kind: isManifestSource(selected) ? 'stream' : 'media',
        pageUrl: location.href,
      };
    }
  }

  if (isFacebookPage(pageHost)) {
    if (currentFacebookVideoId()) return null;
    const resources = performance.getEntriesByType('resource');
    for (let index = resources.length - 1; index >= 0; index -= 1) {
      const rawUrl = resources[index].name;
      try {
        const url = new URL(rawUrl);
        const path = url.pathname.toLowerCase();
        const isFacebookMediaHost =
          url.hostname === 'fbcdn.net' || url.hostname.endsWith('.fbcdn.net');
        const isManifest = /\.(m3u8|mpd)$/i.test(path);
        if (isFacebookMediaHost && isManifest) {
          return {
            url: url.href,
            kind: 'stream',
            pageUrl: location.href,
          };
        }
      } catch (_) {
        // Ignore non-URL performance entries.
      }
    }
  }

  return null;
}

function findFacebookPlayableSource() {
  const capturedSources = parseFacebookCapturedSources();
  const videoId = currentFacebookVideoId();
  const matchingSources = videoId
    ? capturedSources.filter((source) => source.videoIds?.includes(videoId))
    : capturedSources;
  matchingSources.sort((a, b) => b.priority - a.priority || b.capturedAt - a.capturedAt);
  const captured = matchingSources[0];
  if (captured && isFacebookPlayableUrl(captured.url)) {
    return {
      url: captured.url,
      kind: /\.mpd(?:$|\?)/i.test(captured.url) ? 'stream' : 'media',
      pageUrl: location.href,
    };
  }

  const candidates = [];
  const scripts = [...document.querySelectorAll('script')];
  for (let scriptIndex = 0; scriptIndex < scripts.length; scriptIndex += 1) {
    const text = scripts[scriptIndex].textContent || '';
    const pattern = /"(playable_url_quality_hd|playable_url|browser_native_hd_url|browser_native_sd_url|progressive_url|playable_url_dash|dash_manifest_url|manifest_url)"\s*:\s*"((?:\\.|[^"\\])*)"/g;
    for (const match of text.matchAll(pattern)) {
      try {
        const value = JSON.parse(`"${match[2]}"`);
        if (isFacebookPlayableUrl(value)) {
          candidates.push({
            url: new URL(value).href,
            quality: /\.mpd(?:$|\?)/i.test(value)
              ? 3
              : match[1].includes('hd') ? 2 : match[1] === 'progressive_url' ? 1 : 0,
            scriptIndex,
          });
        }
      } catch (_) {
        // Ignore malformed or non-Facebook embedded media URLs.
      }
    }
  }
  candidates.sort((a, b) => b.quality - a.quality || b.scriptIndex - a.scriptIndex);
  if (videoId && candidates.length !== 1) return null;
  const selected = candidates[0];
  return selected
    ? {
        url: selected.url,
        kind: /\.mpd(?:$|\?)/i.test(selected.url) ? 'stream' : 'media',
        pageUrl: location.href,
      }
    : null;
}

function parseFacebookCapturedSources() {
  try {
    const value = document.documentElement?.getAttribute(
      'data-idm-facebook-playable-sources',
    );
    const sources = JSON.parse(value || '[]');
    return Array.isArray(sources) ? sources : [];
  } catch (_) {
    return [];
  }
}

function currentFacebookVideoId() {
  const match = /\/reel\/(\d+)/i.exec(location.pathname);
  if (match) return match[1];
  try {
    return new URL(location.href).searchParams.get('v');
  } catch (_) {
    return null;
  }
}

function isFacebookPlayableUrl(value) {
  try {
    const url = new URL(value);
    return (
      url.protocol === 'https:' &&
      (url.hostname === 'fbcdn.net' || url.hostname.endsWith('.fbcdn.net')) &&
      (/\.mp4$/i.test(url.pathname) || /\.mpd$/i.test(url.pathname)) &&
      (!/\.mp4$/i.test(url.pathname) || ![...url.searchParams.keys()].some((key) =>
        /^(?:byte(start|end)|range)$/i.test(key),
      ))
    );
  } catch (_) {
    return false;
  }
}

function isFacebookPage(host) {
  return host === 'facebook.com' || host.endsWith('.facebook.com') || host === 'fb.watch';
}

function normalizeMediaUrl(value) {
  try {
    const url = new URL(value, location.href);
    if (!['http:', 'https:', 'blob:'].includes(url.protocol)) return null;
    return url.href;
  } catch (_) {
    return null;
  }
}

function isManifestSource(source) {
  if (/\.m3u8$|\.mpd$/i.test(new URL(source.url).pathname)) return true;
  return /mpegurl|dash\+xml/i.test(source.type || '');
}

installFloatingButton();
new MutationObserver(() => {
  installFloatingButton();
  document.getElementById(FLOATING_HOST_ID)?.__idmPosition?.();
}).observe(document.documentElement, {
  childList: true,
  subtree: true,
  attributes: true,
  attributeFilter: ['class', 'height', 'src', 'style', 'width'],
});
