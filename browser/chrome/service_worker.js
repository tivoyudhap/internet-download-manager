const NATIVE_HOST = 'com.tivoyudhap.internet_download_manager';
const MENU_ID = 'idm-download-with-idm';
const STREAM_KEY_PREFIX = 'last-stream-';
const MEDIA_KEY_PREFIX = 'last-media-';
const MAX_STREAM_AGE_MS = 30 * 60 * 1000;
const pendingRequests = new Map();

chrome.webRequest.onBeforeSendHeaders.addListener(
  (details) => {
    if (details.tabId < 0) return;
    const request = {
        url: details.url,
        headers: selectedRequestHeaders(details.requestHeaders || []),
        pageUrl: details.initiator || '',
        observedAt: Date.now(),
        tabId: details.tabId,
        requestType: details.type,
      };
    if (isStreamManifest(details.url)) rememberStream(request);
    if (['media', 'xmlhttprequest', 'other'].includes(details.type)) {
      pendingRequests.set(details.requestId, request);
    }
  },
  { urls: ['<all_urls>'] },
  ['requestHeaders', 'extraHeaders'],
);

chrome.webRequest.onHeadersReceived.addListener(
  (details) => {
    if (details.tabId < 0) return;
    const contentType = (details.responseHeaders || [])
      .find((header) => header.name.toLowerCase() === 'content-type')
      ?.value?.split(';')[0]
      .trim()
      .toLowerCase();
    const isManifestType = [
      'application/vnd.apple.mpegurl',
      'application/x-mpegurl',
      'audio/mpegurl',
      'application/dash+xml',
    ].includes(contentType);
    const request = pendingRequests.get(details.requestId);
    pendingRequests.delete(details.requestId);
    if (!request) return;
    if (isManifestType || isStreamManifest(request.url)) {
      rememberStream(request);
      return;
    }
    if (isDirectVideoResponse(request, contentType)) rememberMedia(request);
  },
  { urls: ['<all_urls>'] },
  ['responseHeaders'],
);

chrome.runtime.onInstalled.addListener(() => {
  chrome.contextMenus.removeAll(() => {
    chrome.contextMenus.create({
      id: MENU_ID,
      title: 'Download with IDM',
      contexts: ['link', 'video', 'audio', 'page'],
    });
  });
});

chrome.contextMenus.onClicked.addListener(async (info) => {
  if (info.menuItemId !== MENU_ID) return;
  let rawUrl = info.linkUrl || info.srcUrl;
  let isStream = isStreamManifest(rawUrl);
  let headers = {};
  let detectedSource;
  if (info.tabId >= 0 && (!rawUrl || rawUrl.startsWith('blob:'))) {
    detectedSource = await readVideoSource(info.tabId, info.frameId);
    if (detectedSource?.url) {
      rawUrl = detectedSource.url;
      isStream = detectedSource.kind === 'stream' || isStreamManifest(rawUrl);
    }
  }
  if (info.tabId >= 0) {
    const isBlob = rawUrl?.startsWith('blob:');
    const wantsCapturedMedia =
      Boolean(detectedSource) ||
      !rawUrl ||
      isBlob ||
      isStream ||
      ['video', 'audio'].includes(info.mediaType);
    if (wantsCapturedMedia) {
      const streamKey = streamStorageKey(info.tabId);
      const mediaKey = mediaStorageKey(info.tabId);
      const [storedStream, storedMedia] = await Promise.all([
        chrome.storage.session.get(streamKey),
        chrome.storage.session.get(mediaKey),
      ]);
      const stream = storedStream[streamKey];
      const media = storedMedia[mediaKey];
      const isRecent = (item) =>
        item && Date.now() - item.observedAt <= MAX_STREAM_AGE_MS;
      let captured;

      if (isStream) {
        if (isRecent(stream) && stream.url === rawUrl) captured = stream;
      } else if (isBlob || !rawUrl) {
        captured = [stream, media]
          .filter(isRecent)
          .sort((a, b) => b.observedAt - a.observedAt)[0];
      } else if (isRecent(media) && media.url === rawUrl) {
        captured = media;
      }

      if (captured) {
        rawUrl = captured.url;
        isStream = captured.kind === 'stream';
        headers = { ...(captured.headers || {}) };
        if (captured.pageUrl && !headers.referer) {
          headers.referer = captured.pageUrl;
        }
      }
    }
  }
  if (detectedSource?.pageUrl && !headers.referer) {
    headers.referer = detectedSource.pageUrl;
  }
  if (!rawUrl || rawUrl.startsWith('blob:')) {
    setStatus('!', 'No video stream found. Start playback, then try again.');
    return;
  }
  const url = normalizeDownloadUrl(rawUrl);
  if (!url) {
    setStatus('!', 'Only HTTP and HTTPS links can be sent to IDM.');
    return;
  }

  chrome.runtime.sendNativeMessage(
    NATIVE_HOST,
    { type: 'add_download', url, isStream, headers },
    (response) => {
      if (chrome.runtime.lastError) {
        setStatus('!', 'Could not connect to IDM. Open the desktop app.');
        return;
      }
      if (!response || response.ok !== true) {
        setStatus('!', response?.error || 'Could not add the download.');
        return;
      }
      setStatus('✓', 'Download added to IDM.');
    },
  );
});

function normalizeDownloadUrl(value) {
  if (typeof value !== 'string') return null;
  try {
    const url = new URL(value);
    if (!['http:', 'https:'].includes(url.protocol)) return null;
    if (url.username || url.password) return null;
    return url.href;
  } catch (_) {
    return null;
  }
}

function isStreamManifest(value) {
  if (typeof value !== 'string') return false;
  try {
    const path = new URL(value).pathname.toLowerCase();
    return path.endsWith('.m3u8') || path.endsWith('.mpd');
  } catch (_) {
    return false;
  }
}

function streamStorageKey(tabId) {
  return `${STREAM_KEY_PREFIX}${tabId}`;
}

function mediaStorageKey(tabId) {
  return `${MEDIA_KEY_PREFIX}${tabId}`;
}

async function readVideoSource(tabId, frameId) {
  const message = { type: 'idm_get_video_source' };
  const clickedFrameTarget =
    Number.isInteger(frameId) && frameId > 0
      ? { tabId, frameIds: [frameId] }
      : { tabId, allFrames: true };
  const targets = [clickedFrameTarget];
  if (!clickedFrameTarget.allFrames) targets.push({ tabId, allFrames: true });

  for (const target of targets) {
    try {
      const results = await chrome.scripting.executeScript({
        target,
        func: findVideoSourceInFrame,
      });
      const source = results.map((result) => result.result).find((item) => item?.url);
      if (source) return source;
    } catch (_) {
      // If scripting is unavailable for this page, try the injected content script.
    }
  }

  if (Number.isInteger(frameId) && frameId > 0) {
    try {
      const source = await chrome.tabs.sendMessage(tabId, message, { frameId });
      if (source?.url) return source;
    } catch (_) {
      // The clicked frame may not contain the player; search all frames next.
    }
  }

  try {
    // With no frameId Chrome sends to every injected frame. Frames without a
    // video source stay silent, allowing the frame containing the player to reply.
    return await chrome.tabs.sendMessage(tabId, message);
  } catch (_) {
    return null;
  }
}

function findVideoSourceInFrame() {
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
    ]
      .filter((source) => source.url)
      .map((source) => {
        try {
          const url = new URL(source.url, location.href);
          if (!['http:', 'https:', 'blob:'].includes(url.protocol)) return null;
          return { ...source, url: url.href };
        } catch (_) {
          return null;
        }
      })
      .filter(Boolean);
    const isManifest = (source) =>
      /\.m3u8$|\.mpd$/i.test(new URL(source.url).pathname) ||
      /mpegurl|dash\+xml/i.test(source.type || '');
    const selected = candidates.find(isManifest) || candidates[0];
    if (selected) {
      return {
        url: selected.url,
        kind: isManifest(selected) ? 'stream' : 'media',
        pageUrl: location.href,
      };
    }
  }
  return null;
}

function rememberStream(request) {
  const key = streamStorageKey(request.tabId);
  const { tabId, requestType, ...stream } = request;
  stream.kind = 'stream';
  void chrome.storage.session.set({ [key]: stream });
}

function rememberMedia(request) {
  const key = mediaStorageKey(request.tabId);
  const { tabId, requestType, ...media } = request;
  media.kind = 'media';
  void chrome.storage.session.set({ [key]: media });
}

function isDirectVideoResponse(request, contentType) {
  const mimeType = typeof contentType === 'string' ? contentType : '';
  if (
    request.requestType !== 'media' ||
    mimeType === 'video/mp2t' ||
    mimeType.includes('iso.segment')
  ) return false;
  if (mimeType.startsWith('video/')) return true;
  try {
    return /\.(mp4|m4v|webm|mov|avi|mkv|ogv|3gp)$/i.test(
      new URL(request.url).pathname,
    );
  } catch (_) {
    return false;
  }
}

function selectedRequestHeaders(headers) {
  const allowed = new Set(['accept', 'cookie', 'origin', 'referer', 'user-agent']);
  const selected = {};
  for (const header of headers) {
    const name = header.name.toLowerCase();
    if (!allowed.has(name) || typeof header.value !== 'string') continue;
    selected[name] = header.value;
  }
  return selected;
}

function setStatus(badge, title) {
  chrome.action.setBadgeText({ text: badge });
  chrome.action.setTitle({ title });
  setTimeout(() => chrome.action.setBadgeText({ text: '' }), 4000);
}
