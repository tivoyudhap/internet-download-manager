chrome.runtime.onMessage.addListener((message, _sender, sendResponse) => {
  if (message?.type !== 'idm_get_video_source') return;
  sendResponse(findVideoSource());
});

function findVideoSource() {
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
    ].filter((source) => source.url);

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

  return null;
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
