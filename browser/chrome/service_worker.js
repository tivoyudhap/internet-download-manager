const NATIVE_HOST = 'com.tivoyudhap.internet_download_manager';
const MENU_ID = 'idm-download-with-idm';
const STREAM_KEY_PREFIX = 'last-stream-';
const TWITTER_AUDIO_KEY_PREFIX = 'last-twitter-audio-';
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
    if (isDirectVideoResponse(request, contentType, details)) rememberMedia(request);
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
  let audioUrl;
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
      const audioKey = twitterAudioStorageKey(info.tabId);
      const mediaKey = mediaStorageKey(info.tabId);
      const [storedStream, storedAudio, storedMedia] = await Promise.all([
        chrome.storage.session.get(streamKey),
        chrome.storage.session.get(audioKey),
        chrome.storage.session.get(mediaKey),
      ]);
      const stream = storedStream[streamKey];
      const audio = storedAudio[audioKey];
      const media = storedMedia[mediaKey];
      const isRecent = (item) =>
        item && Date.now() - item.observedAt <= MAX_STREAM_AGE_MS;
      const isFacebookPage = isFacebookPageUrl(detectedSource?.pageUrl || info.pageUrl);
      let captured;

      if (isStream) {
        if (isRecent(stream) && stream.url === rawUrl && !isTwitterAudioOnlyManifest(rawUrl)) {
          captured = stream;
        } else if (isTwitterAudioOnlyManifest(rawUrl)) {
          captured = [stream, media]
            .filter((item) =>
              isRecent(item) &&
              !isTwitterAudioOnlyManifest(item.url) &&
              sameTwitterMedia(rawUrl, item.url),
            )
            .sort((a, b) => b.observedAt - a.observedAt)[0];
        }
      } else if (isBlob || !rawUrl) {
        const candidates = isFacebookPage ? [stream] : [stream, media];
        captured = candidates
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
      if (
        isStream &&
        isTwitterVideoManifest(rawUrl) &&
        isRecent(audio) &&
        sameTwitterMedia(rawUrl, audio.url)
      ) {
        audioUrl = audio.url;
      }
    }
  }
  if (detectedSource?.pageUrl && !headers.referer) {
    headers.referer = detectedSource.pageUrl;
  }
  if (isTwitterAudioOnlyManifest(rawUrl)) {
    setStatus('!', 'Twitter supplied an audio-only playlist. Replay the video and try again.');
    return;
  }
  if (!rawUrl || rawUrl.startsWith('blob:')) {
    setStatus(
      '!',
      `IDM ${chrome.runtime.getManifest().version}: no video source found. Reload the extension and page.`,
    );
    return;
  }
  const url = normalizeDownloadUrl(rawUrl);
  if (!url) {
    setStatus('!', 'Only HTTP and HTTPS links can be sent to IDM.');
    return;
  }

  await sendNativeDownload(url, isStream, headers, audioUrl);
});

chrome.runtime.onMessage.addListener((message, sender, sendResponse) => {
  if (message?.type !== 'idm_download_video') return;
  handleFloatingVideoDownload(message.source, sender.tab?.id, sender.tab?.url)
    .then(sendResponse)
    .catch((error) => sendResponse({ ok: false, error: String(error) }));
  return true;
});

async function handleFloatingVideoDownload(source, tabId, senderPageUrl) {
  let rawUrl = source?.url;
  let isStream = source?.kind === 'stream' || isStreamManifest(rawUrl);
  let headers = {};
  let audioUrl;
  if (Number.isInteger(tabId) && tabId >= 0) {
    const streamKey = streamStorageKey(tabId);
    const audioKey = twitterAudioStorageKey(tabId);
    const mediaKey = mediaStorageKey(tabId);
    const [storedStream, storedMedia, storedAudio] = await Promise.all([
      chrome.storage.session.get(streamKey),
      chrome.storage.session.get(mediaKey),
      chrome.storage.session.get(audioKey),
    ]);
    const [stream, media, audio] = [
      storedStream[streamKey],
      storedMedia[mediaKey],
      storedAudio[audioKey],
    ];
    const isFacebookPage = isFacebookPageUrl(source?.pageUrl || senderPageUrl);
    const candidates = isFacebookPage ? [stream] : [stream, media];
    const isRecent = (item) =>
      item && Date.now() - item.observedAt <= MAX_STREAM_AGE_MS;
    const captured = candidates.find(
      (item) =>
        isRecent(item) &&
        item.url === rawUrl &&
        !isTwitterAudioOnlyManifest(item.url),
    );
    if (captured) {
      headers = { ...(captured.headers || {}) };
      isStream = captured.kind === 'stream';
    } else if (isTwitterAudioOnlyManifest(rawUrl)) {
      const videoCandidate = candidates
        .filter((item) =>
          isRecent(item) &&
          !isTwitterAudioOnlyManifest(item.url) &&
          sameTwitterMedia(rawUrl, item.url),
        )
        .sort((a, b) => b.observedAt - a.observedAt)[0];
      if (videoCandidate) {
        rawUrl = videoCandidate.url;
        isStream = videoCandidate.kind === 'stream';
        headers = { ...(videoCandidate.headers || {}) };
      }
    } else if (!rawUrl || rawUrl.startsWith('blob:')) {
      const latest = candidates
        .filter(isRecent)
        .sort((a, b) => b.observedAt - a.observedAt)[0];
      if (latest) {
        rawUrl = latest.url;
        isStream = latest.kind === 'stream';
        headers = { ...(latest.headers || {}) };
      }
    }
    if (
      isStream &&
      isTwitterVideoManifest(rawUrl) &&
      isRecent(audio) &&
      sameTwitterMedia(rawUrl, audio.url)
    ) {
      audioUrl = audio.url;
    }
  }
  if (source?.pageUrl && !headers.referer) headers.referer = source.pageUrl;
  if (isTwitterAudioOnlyManifest(rawUrl)) {
    const error = 'Twitter supplied an audio-only playlist. Replay the video and try again.';
    setStatus('!', error);
    return { ok: false, error };
  }
  if (!rawUrl || rawUrl.startsWith('blob:')) {
    const error = `IDM ${chrome.runtime.getManifest().version}: no video source found.`;
    setStatus('!', error);
    return { ok: false, error };
  }
  const url = normalizeDownloadUrl(rawUrl);
  if (!url) {
    const error = 'Only HTTP and HTTPS video sources can be sent to IDM.';
    setStatus('!', error);
    return { ok: false, error };
  }
  return sendNativeDownload(url, isStream, headers, audioUrl);
}

function sendNativeDownload(url, isStream, headers, audioUrl) {
  return new Promise((resolve) => {
    const message = { type: 'add_download', url, isStream, headers };
    if (audioUrl) message.audioUrl = audioUrl;
    chrome.runtime.sendNativeMessage(
      NATIVE_HOST,
      message,
      (response) => {
        if (chrome.runtime.lastError) {
          const error = 'Could not connect to IDM. Open the desktop app.';
          setStatus('!', error);
          resolve({ ok: false, error });
          return;
        }
        if (!response || response.ok !== true) {
          const error = response?.error || 'Could not add the download.';
          setStatus('!', error);
          resolve({ ok: false, error });
          return;
        }
        setStatus('✓', 'Download added to IDM.');
        resolve(response);
      },
    );
  });
}

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

function twitterAudioStorageKey(tabId) {
  return `${TWITTER_AUDIO_KEY_PREFIX}${tabId}`;
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
      .filter((source) => source.url && !source.url.startsWith('blob:'))
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
  const pageHost = location.hostname.toLowerCase();
  if (isFacebookPage(pageHost)) {
    const playableSource = findFacebookPlayableSource();
    if (playableSource) return playableSource;

    const resources = performance.getEntriesByType('resource');
    for (let index = resources.length - 1; index >= 0; index -= 1) {
      try {
        const url = new URL(resources[index].name);
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
  const candidates = [];
  const scripts = [...document.querySelectorAll('script')];
  for (let scriptIndex = 0; scriptIndex < scripts.length; scriptIndex += 1) {
    const text = scripts[scriptIndex].textContent || '';
    const pattern = /"playable_url_quality_hd"\s*:\s*"((?:\\.|[^"\\])*)"|"playable_url"\s*:\s*"((?:\\.|[^"\\])*)"/g;
    for (const match of text.matchAll(pattern)) {
      try {
        const value = JSON.parse(`"${match[1] || match[2]}"`);
        const url = new URL(value);
        const isFacebookMediaHost =
          url.hostname === 'fbcdn.net' || url.hostname.endsWith('.fbcdn.net');
        if (
          isFacebookMediaHost &&
          /\.mp4$/i.test(url.pathname) &&
          !url.searchParams.has('bytestart') &&
          !url.searchParams.has('byteend')
        ) {
          candidates.push({
            url: url.href,
            quality: match[1] ? 1 : 0,
            scriptIndex,
          });
        }
      } catch (_) {
        // Ignore malformed or non-Facebook embedded media URLs.
      }
    }
  }
  candidates.sort((a, b) => b.quality - a.quality || b.scriptIndex - a.scriptIndex);
  const selected = candidates[0];
  return selected
    ? { url: selected.url, kind: 'media', pageUrl: location.href }
    : null;
}

function isFacebookPage(host) {
  return host === 'facebook.com' || host.endsWith('.facebook.com') || host === 'fb.watch';
}

function isFacebookPageUrl(value) {
  try {
    return isFacebookPage(new URL(value).hostname.toLowerCase());
  } catch (_) {
    return false;
  }
}

function rememberStream(request) {
  const key = isTwitterAudioOnlyManifest(request.url)
    ? twitterAudioStorageKey(request.tabId)
    : streamStorageKey(request.tabId);
  const { tabId, requestType, ...stream } = request;
  stream.kind = 'stream';
  void chrome.storage.session.set({ [key]: stream });
}

function isTwitterAudioOnlyManifest(value) {
  try {
    const url = new URL(value);
    if (url.hostname !== 'video.twimg.com') return false;
    return /\/(?:aud|audio|mp4a)(?:\/|[-_.]|$)/i.test(url.pathname);
  } catch (_) {
    return false;
  }
}

function isTwitterVideoManifest(value) {
  try {
    const url = new URL(value);
    return url.hostname === 'video.twimg.com' &&
      isStreamManifest(value) &&
      !isTwitterAudioOnlyManifest(value);
  } catch (_) {
    return false;
  }
}

function sameTwitterMedia(left, right) {
  const mediaKey = (value) => {
    try {
      const url = new URL(value);
      if (url.hostname !== 'video.twimg.com') return null;
      const match = /^\/([^/]+\/[^/]+)/.exec(url.pathname);
      return match?.[1] || null;
    } catch (_) {
      return null;
    }
  };
  const leftKey = mediaKey(left);
  return leftKey !== null && leftKey === mediaKey(right);
}

function rememberMedia(request) {
  const key = mediaStorageKey(request.tabId);
  const { tabId, requestType, ...media } = request;
  media.kind = 'media';
  void chrome.storage.session.set({ [key]: media });
}

function isDirectVideoResponse(request, contentType, details) {
  const mimeType = typeof contentType === 'string' ? contentType : '';
  if (mimeType === 'video/mp2t' || mimeType.includes('iso.segment')) return false;
  if (mimeType.startsWith('video/')) {
    const contentRange = (details.responseHeaders || [])
      .find((header) => header.name.toLowerCase() === 'content-range')?.value;
    if (details.statusCode === 206 && !isCompleteContentRange(contentRange)) return false;
    return request.requestType === 'media';
  }
  if (request.requestType !== 'media') return false;
  try {
    return /\.(mp4|m4v|webm|mov|avi|mkv|ogv|3gp)$/i.test(
      new URL(request.url).pathname,
    );
  } catch (_) {
    return false;
  }
}

function isCompleteContentRange(value) {
  const match = /^bytes\s+0-(\d+)\/(\d+)$/i.exec(value || '');
  return Boolean(match && Number(match[1]) + 1 === Number(match[2]));
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
