import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import test from 'node:test';
import vm from 'node:vm';

const source = await readFile(new URL('./service_worker.js', import.meta.url), 'utf8');
const contentSource = await readFile(new URL('./content_script.js', import.meta.url), 'utf8');

function loadWorker({
  response = { ok: true },
  lastError = null,
  videoSource = null,
  scriptSource = null,
  downloadItem = null,
  downloadPauseError = null,
  cookies = [],
} = {}) {
  const listeners = { beforeSendHeaders: [], headersReceived: [] };
  const menus = [];
  const nativeMessages = [];
  const badges = [];
  const titles = [];
  const session = {};
  const downloadOperations = [];
  const browserDownload = downloadItem || {};
  const chrome = {
    runtime: {
      lastError: null,
      getManifest: () => ({ version: '1.0.1' }),
      onInstalled: { addListener: (listener) => { listeners.installed = listener; } },
      onMessage: { addListener: (listener) => { listeners.runtimeMessage = listener; } },
      sendNativeMessage: (host, message, callback) => {
        nativeMessages.push({ host, message });
        chrome.runtime.lastError = lastError;
        callback(response);
        chrome.runtime.lastError = null;
      },
    },
    tabs: {
      sendMessage: async (_tabId, _message, options) => {
        if (typeof videoSource === 'function') return videoSource(options);
        if (Array.isArray(videoSource)) return videoSource.shift() || null;
        return videoSource;
      },
    },
    scripting: {
      executeScript: async ({ target }) => {
        if (typeof scriptSource === 'function') return scriptSource(target);
        if (Array.isArray(scriptSource)) return scriptSource.shift() || [];
        return scriptSource ? [{ result: scriptSource }] : [];
      },
    },
    webRequest: {
      onBeforeSendHeaders: { addListener: (listener) => listeners.beforeSendHeaders.push(listener) },
      onHeadersReceived: { addListener: (listener) => listeners.headersReceived.push(listener) },
    },
    downloads: {
      onCreated: { addListener: (listener) => { listeners.downloadCreated = listener; } },
      pause: async (id) => {
        downloadOperations.push(['pause', id]);
        if (downloadPauseError) throw downloadPauseError;
      },
      cancel: async (id) => downloadOperations.push(['cancel', id]),
      resume: async (id) => downloadOperations.push(['resume', id]),
      search: async () => [browserDownload],
    },
    cookies: { getAll: async ({ url }) => {
      downloadOperations.push(['cookies', url]);
      return cookies;
    } },
    storage: {
      session: {
        set: async (values) => Object.assign(session, values),
        get: async (key) => key in session ? { [key]: session[key] } : {},
      },
    },
    contextMenus: {
      onClicked: { addListener: (listener) => { listeners.clicked = listener; } },
      removeAll: (callback) => callback(),
      create: (menu) => menus.push(menu),
    },
    action: {
      setBadgeText: (value) => badges.push(value.text),
      setTitle: (value) => titles.push(value.title),
    },
  };
  vm.runInNewContext(source, { chrome, URL, Date, setTimeout: () => 0 });
  return {
    chrome, listeners, menus, nativeMessages, badges, titles, session,
    downloadOperations,
  };
}

function loadContentScript(video, pageUrl) {
  let listener;
  let button;
  let host;
  const makeElement = (tagName) => ({
    tagName,
    style: {},
    children: [],
    append(...children) { this.children.push(...children); },
    addEventListener(type, callback) {
      if (type === 'click') buttonClick = callback;
    },
    attachShadow() {
      return { append: (...children) => this.children.push(...children) };
    },
  });
  let buttonClick;
  const root = {
    append(element) { host = element; },
  };
  const timers = [];
  const chrome = {
    runtime: {
      onMessage: { addListener: (callback) => { listener = callback; } },
      sendMessage: (message, callback) => {
        sentMessages.push(message);
        callback({ ok: true });
      },
      lastError: null,
    },
  };
  const sentMessages = [];
  const window = { addEventListener() {} };
  vm.runInNewContext(contentSource, {
    chrome,
    document: {
      querySelector: () => video,
      querySelectorAll: () => [video],
      getElementById: () => host || null,
      createElement: (tagName) => {
        const element = makeElement(tagName);
        if (tagName === 'button') button = element;
        return element;
      },
      documentElement: root,
    },
    MutationObserver: class { observe() {} },
    window,
    location: { href: pageUrl, hostname: new URL(pageUrl).hostname },
    URL,
    setTimeout: (callback) => timers.push(callback),
  });
  return { listener, button, host, buttonClick, sentMessages, timers };
}

test('registers Download with IDM for links, media elements, and page contexts', () => {
  const worker = loadWorker();
  worker.listeners.installed();
  assert.deepEqual(JSON.parse(JSON.stringify(worker.menus)), [{
    id: 'idm-download-with-idm',
    title: 'Download with IDM',
    contexts: ['link', 'video', 'audio', 'page'],
  }]);
});

test('finds a manifest source inside a video element even before playback', () => {
  const { listener } = loadContentScript({
    paused: true,
    readyState: 0,
    getBoundingClientRect: () => ({ top: 100, right: 700, width: 640, height: 360 }),
    currentSrc: 'blob:https://example.test/video',
    src: '',
    querySelectorAll: () => [{
      src: 'https://hls.example.com/master.m3u8?token=abc',
      type: 'application/vnd.apple.mpegurl',
      getAttribute: () => '',
    }],
  }, 'https://example.test/stream.php');
  let source;

  listener({ type: 'idm_get_video_source' }, {}, (value) => { source = value; });

  assert.deepEqual(JSON.parse(JSON.stringify(source)), {
    url: 'https://hls.example.com/master.m3u8?token=abc',
    kind: 'stream',
    pageUrl: 'https://example.test/stream.php',
  });
});

test('places a floating IDM button over a visible video and sends its source', () => {
  const { button, host, buttonClick, sentMessages } = loadContentScript({
    paused: true,
    readyState: 0,
    currentSrc: 'https://cdn.example.com/movie',
    src: '',
    getBoundingClientRect: () => ({ top: 100, right: 700, width: 640, height: 360 }),
    querySelectorAll: () => [],
  }, 'https://example.test/stream.php');

  assert.equal(button.textContent, '↓  Download with IDM');
  assert.equal(host.style.top, '112px');
  assert.equal(host.style.left, '506px');
  buttonClick({ preventDefault() {}, stopPropagation() {} });
  assert.equal(sentMessages[0].type, 'idm_download_video');
  assert.equal(sentMessages[0].source.url, 'https://cdn.example.com/movie');
});

test('sends an extensionless source from the floating button as a direct download', async () => {
  const worker = loadWorker();
  let response;

  const keepChannelOpen = worker.listeners.runtimeMessage({
    type: 'idm_download_video',
    source: {
      url: 'https://mp4-11.example.com/s/video/token',
      kind: 'media',
      pageUrl: 'https://example.test/stream.php',
    },
  }, { tab: { id: 24 } }, (value) => { response = value; });

  assert.equal(keepChannelOpen, true);
  await new Promise((resolve) => setImmediate(resolve));
  assert.deepEqual(JSON.parse(JSON.stringify(worker.nativeMessages[0].message)), {
    type: 'add_download',
    url: 'https://mp4-11.example.com/s/video/token',
    isStream: false,
    headers: { referer: 'https://example.test/stream.php' },
  });
  assert.equal(response.ok, true);
});

test('uses captured request headers when a floating button sends a manifest', async () => {
  const worker = loadWorker();
  worker.listeners.beforeSendHeaders[0]({
    requestId: 'r-floating-hls', tabId: 25, type: 'media',
    url: 'https://cdn.example.com/master.m3u8?token=player',
    initiator: 'https://example.test/stream.php',
    requestHeaders: [{ name: 'Cookie', value: 'session=player' }],
  });
  let response;

  worker.listeners.runtimeMessage({
    type: 'idm_download_video',
    source: {
      url: 'https://cdn.example.com/master.m3u8?token=player',
      kind: 'stream',
      pageUrl: 'https://example.test/stream.php',
    },
  }, { tab: { id: 25 } }, (value) => { response = value; });
  await new Promise((resolve) => setImmediate(resolve));

  assert.equal(worker.nativeMessages[0].message.isStream, true);
  assert.deepEqual(JSON.parse(JSON.stringify(worker.nativeMessages[0].message.headers)), {
    cookie: 'session=player',
    referer: 'https://example.test/stream.php',
  });
  assert.equal(response.ok, true);
});

test('returns a visible error for missing or unsupported floating video sources', async () => {
  for (const source of [null, { url: 'blob:https://site.example/video', kind: 'media' }]) {
    const worker = loadWorker();
    let response;
    worker.listeners.runtimeMessage({ type: 'idm_download_video', source }, { tab: { id: 26 } }, (value) => {
      response = value;
    });
    await new Promise((resolve) => setImmediate(resolve));
    assert.equal(worker.nativeMessages.length, 0);
    assert.equal(response.ok, false);
    assert.match(response.error, /no video source found/);
  }
});

test('sends a direct link as a regular download', async () => {
  const worker = loadWorker();
  await worker.listeners.clicked({ menuItemId: 'idm-download-with-idm', linkUrl: 'https://example.com/file.zip' });
  assert.deepEqual(JSON.parse(JSON.stringify(worker.nativeMessages)), [{
    host: 'com.tivoyudhap.internet_download_manager',
    message: { type: 'add_download', url: 'https://example.com/file.zip', isStream: false, headers: {} },
  }]);
  assert.equal(worker.badges.at(-1), '✓');
});

test('sends a direct MP4 media source as a regular download', async () => {
  const worker = loadWorker();
  await worker.listeners.clicked({ menuItemId: 'idm-download-with-idm', srcUrl: 'https://cdn.example.com/movie.mp4' });
  assert.equal(worker.nativeMessages[0].message.url, 'https://cdn.example.com/movie.mp4');
  assert.equal(worker.nativeMessages[0].message.isStream, false);
});

test('recognizes HLS and DASH manifest paths regardless of case or query strings', async () => {
  for (const url of [
    'https://cdn.example.com/video.M3U8?token=one',
    'https://cdn.example.com/manifest.MPD?token=two',
  ]) {
    const worker = loadWorker();
    await worker.listeners.clicked({ menuItemId: 'idm-download-with-idm', linkUrl: url });
    assert.equal(worker.nativeMessages[0].message.isStream, true);
  }
});

test('uses the captured stream manifest and selected headers for a blob video', async () => {
  const worker = loadWorker();
  worker.listeners.beforeSendHeaders[0]({
    requestId: 'r1', tabId: 7, type: 'media',
    url: 'https://cdn.example.com/master.m3u8?sig=abc',
    initiator: 'https://site.example/watch/42',
    requestHeaders: [
      { name: 'Cookie', value: 'session=secret' },
      { name: 'Referer', value: 'https://site.example/watch/42' },
      { name: 'X-Tracking', value: 'discard-me' },
    ],
  });
  await worker.listeners.clicked({
    menuItemId: 'idm-download-with-idm', tabId: 7,
    srcUrl: 'blob:https://site.example/asset-id',
  });
  const message = worker.nativeMessages[0].message;
  assert.equal(message.url, 'https://cdn.example.com/master.m3u8?sig=abc');
  assert.equal(message.isStream, true);
  assert.deepEqual(JSON.parse(JSON.stringify(message.headers)), {
    cookie: 'session=secret',
    referer: 'https://site.example/watch/42',
  });
});

test('uses the most recently captured HLS manifest from the page context', async () => {
  const worker = loadWorker();
  worker.listeners.beforeSendHeaders[0]({
    requestId: 'r-page-hls', tabId: 10, type: 'media',
    url: 'https://cdn.example.com/master.m3u8?sig=page-token',
    initiator: 'https://site.example/watch',
    requestHeaders: [{ name: 'Referer', value: 'https://site.example/watch' }],
  });

  await worker.listeners.clicked({
    menuItemId: 'idm-download-with-idm',
    tabId: 10,
  });

  assert.equal(worker.nativeMessages[0].message.url, 'https://cdn.example.com/master.m3u8?sig=page-token');
  assert.equal(worker.nativeMessages[0].message.isStream, true);
  assert.equal(worker.nativeMessages[0].message.headers.referer, 'https://site.example/watch');
});

test('pairs captured Twitter video and audio playlists', async () => {
  const worker = loadWorker();
  worker.listeners.beforeSendHeaders[0]({
    requestId: 'r-twitter-audio', tabId: 52, type: 'media',
    url: 'https://video.twimg.com/ext_tw_video/123/pu/pl/mp4a/64000/audio.m3u8',
    initiator: 'https://x.com/post/123', requestHeaders: [],
  });
  worker.listeners.beforeSendHeaders[0]({
    requestId: 'r-twitter-video', tabId: 52, type: 'media',
    url: 'https://video.twimg.com/ext_tw_video/123/pu/pl/avc1/1280x720/video.m3u8',
    initiator: 'https://x.com/post/123', requestHeaders: [],
  });

  await worker.listeners.clicked({
    menuItemId: 'idm-download-with-idm', tabId: 52, mediaType: 'video',
  });

  assert.equal(
    worker.nativeMessages[0].message.url,
    'https://video.twimg.com/ext_tw_video/123/pu/pl/avc1/1280x720/video.m3u8',
  );
  assert.equal(
    worker.nativeMessages[0].message.audioUrl,
    'https://video.twimg.com/ext_tw_video/123/pu/pl/mp4a/64000/audio.m3u8',
  );
  assert.equal(worker.nativeMessages[0].message.isStream, true);
});

test('replaces an explicit Twitter audio playlist with the captured video playlist', async () => {
  const worker = loadWorker();
  worker.listeners.beforeSendHeaders[0]({
    requestId: 'r-twitter-audio', tabId: 53, type: 'media',
    url: 'https://video.twimg.com/ext_tw_video/456/pu/pl/mp4a/64000/audio.m3u8',
    initiator: 'https://x.com/post/456', requestHeaders: [],
  });
  worker.listeners.beforeSendHeaders[0]({
    requestId: 'r-twitter-video', tabId: 53, type: 'media',
    url: 'https://video.twimg.com/ext_tw_video/456/pu/pl/avc1/640x360/video.m3u8',
    initiator: 'https://x.com/post/456', requestHeaders: [],
  });

  await worker.listeners.clicked({
    menuItemId: 'idm-download-with-idm', tabId: 53, mediaType: 'video',
    srcUrl: 'https://video.twimg.com/ext_tw_video/456/pu/pl/mp4a/64000/audio.m3u8',
  });

  assert.equal(
    worker.nativeMessages[0].message.url,
    'https://video.twimg.com/ext_tw_video/456/pu/pl/avc1/640x360/video.m3u8',
  );
  assert.equal(
    worker.nativeMessages[0].message.audioUrl,
    'https://video.twimg.com/ext_tw_video/456/pu/pl/mp4a/64000/audio.m3u8',
  );
  assert.equal(worker.nativeMessages[0].message.isStream, true);
});

test('uses a video source read from the clicked iframe when no request was captured', async () => {
  const worker = loadWorker({
    videoSource: {
      url: 'https://hls.example.com/master.m3u8?token=frame',
      kind: 'stream',
      pageUrl: 'https://example.test/stream.php',
    },
  });

  await worker.listeners.clicked({
    menuItemId: 'idm-download-with-idm',
    tabId: 14,
    frameId: 3,
  });

  const message = worker.nativeMessages[0].message;
  assert.equal(message.url, 'https://hls.example.com/master.m3u8?token=frame');
  assert.equal(message.isStream, true);
  assert.equal(message.headers.referer, 'https://example.test/stream.php');
});

test('falls back to searching all frames when the clicked frame has no source', async () => {
  const worker = loadWorker({
    videoSource: [null, {
      url: 'https://hls.example.com/master.m3u8?token=other-frame',
      kind: 'stream',
      pageUrl: 'https://example.test/stream.php',
    }],
  });

  await worker.listeners.clicked({
    menuItemId: 'idm-download-with-idm',
    tabId: 15,
    frameId: 2,
  });

  const message = worker.nativeMessages[0].message;
  assert.equal(message.url, 'https://hls.example.com/master.m3u8?token=other-frame');
  assert.equal(message.isStream, true);
});

test('reads an extensionless direct MP4 source from all player frames', async () => {
  const worker = loadWorker({
    scriptSource: (target) => target.allFrames
      ? [{
        result: {
          url: 'https://mp4-11.example.com/s/id/token',
          kind: 'media',
          pageUrl: 'https://example.test/stream.php',
        },
      }]
      : [{ result: null }],
  });

  await worker.listeners.clicked({
    menuItemId: 'idm-download-with-idm',
    tabId: 16,
    frameId: 4,
  });

  const message = worker.nativeMessages[0].message;
  assert.equal(message.url, 'https://mp4-11.example.com/s/id/token');
  assert.equal(message.isStream, false);
  assert.equal(message.headers.referer, 'https://example.test/stream.php');
});

test('uses a captured direct video response from the page context', async () => {
  const worker = loadWorker();
  worker.listeners.beforeSendHeaders[0]({
    requestId: 'r-page-mp4', tabId: 11, type: 'media',
    url: 'https://cdn.example.com/play?id=movie',
    initiator: 'https://site.example/watch',
    requestHeaders: [{ name: 'Cookie', value: 'session=video' }],
  });
  worker.listeners.headersReceived[0]({
    requestId: 'r-page-mp4', tabId: 11,
    responseHeaders: [{ name: 'content-type', value: 'video/mp4' }],
  });

  await worker.listeners.clicked({
    menuItemId: 'idm-download-with-idm',
    tabId: 11,
  });

  assert.equal(worker.nativeMessages[0].message.url, 'https://cdn.example.com/play?id=movie');
  assert.equal(worker.nativeMessages[0].message.isStream, false);
  assert.equal(worker.nativeMessages[0].message.headers.cookie, 'session=video');
});

test('does not treat a segmented video chunk as a complete page video', async () => {
  const worker = loadWorker();
  worker.listeners.beforeSendHeaders[0]({
    requestId: 'r-segment', tabId: 13, type: 'media',
    url: 'https://cdn.example.com/segment.mp4',
    initiator: 'https://site.example/watch',
    requestHeaders: [],
  });
  worker.listeners.headersReceived[0]({
    requestId: 'r-segment', tabId: 13,
    responseHeaders: [{ name: 'content-type', value: 'video/iso.segment' }],
  });

  await worker.listeners.clicked({
    menuItemId: 'idm-download-with-idm',
    tabId: 13,
  });

  assert.equal(worker.nativeMessages.length, 0);
  assert.equal(
    worker.titles.at(-1),
    'IDM 1.0.1: no video source found. Reload the extension and page.',
  );
});

test('asks the user to start playback when the page has no captured video', async () => {
  const worker = loadWorker();

  await worker.listeners.clicked({
    menuItemId: 'idm-download-with-idm',
    tabId: 12,
  });

  assert.equal(worker.nativeMessages.length, 0);
  assert.equal(
    worker.titles.at(-1),
    'IDM 1.0.1: no video source found. Reload the extension and page.',
  );
});

test('recognizes extensionless manifests by HLS or DASH response MIME type', async () => {
  for (const [mime, expectedUrl] of [
    ['application/vnd.apple.mpegurl', 'https://cdn.example.com/play?id=1'],
    ['application/dash+xml', 'https://cdn.example.com/manifest?id=2'],
  ]) {
    const worker = loadWorker();
    worker.listeners.beforeSendHeaders[0]({
      requestId: 'r2', tabId: 9, type: 'xmlhttprequest',
      url: expectedUrl, initiator: 'https://site.example/watch', requestHeaders: [],
    });
    worker.listeners.headersReceived[0]({
      requestId: 'r2', tabId: 9,
      responseHeaders: [{ name: 'content-type', value: mime }],
    });
    await worker.listeners.clicked({
      menuItemId: 'idm-download-with-idm', tabId: 9,
      srcUrl: 'blob:https://site.example/player',
    });
    assert.equal(worker.nativeMessages[0].message.url, expectedUrl);
    assert.equal(worker.nativeMessages[0].message.isStream, true);
  }
});

test('does not send a blob video when no recent manifest was captured', async () => {
  const worker = loadWorker();
  await worker.listeners.clicked({
    menuItemId: 'idm-download-with-idm', tabId: 3,
    srcUrl: 'blob:https://site.example/player',
  });
  assert.equal(worker.nativeMessages.length, 0);
  assert.equal(worker.badges.at(-1), '!');
});

test('ignores a stream manifest after the capture expires', async () => {
  const worker = loadWorker();
  worker.listeners.beforeSendHeaders[0]({
    requestId: 'r3', tabId: 4, type: 'media',
    url: 'https://cdn.example.com/old.m3u8', initiator: '', requestHeaders: [],
  });
  worker.session['last-stream-4'].observedAt = Date.now() - 31 * 60 * 1000;
  await worker.listeners.clicked({
    menuItemId: 'idm-download-with-idm', tabId: 4,
    srcUrl: 'blob:https://site.example/player',
  });
  assert.equal(worker.nativeMessages.length, 0);
});

test('rejects non-HTTP, credentialed, and unrelated blob URLs', async () => {
  for (const url of [
    'file:///tmp/archive.zip',
    'ftp://example.com/archive.zip',
    'https://user:pass@example.com/file.zip',
  ]) {
    const worker = loadWorker();
    await worker.listeners.clicked({ menuItemId: 'idm-download-with-idm', linkUrl: url });
    assert.equal(worker.nativeMessages.length, 0);
    assert.equal(worker.badges.at(-1), '!');
  }
});

test('shows an error when the desktop app or native host rejects a request', async () => {
  const appError = loadWorker({ response: { ok: false, error: 'Open IDM first.' } });
  await appError.listeners.clicked({ menuItemId: 'idm-download-with-idm', linkUrl: 'https://example.com/file.zip' });
  assert.equal(appError.badges.at(-1), '!');
  assert.equal(appError.titles.at(-1), 'Open IDM first.');

  const hostError = loadWorker({ lastError: { message: 'Native host missing.' } });
  await hostError.listeners.clicked({ menuItemId: 'idm-download-with-idm', linkUrl: 'https://example.com/file.zip' });
  assert.equal(hostError.badges.at(-1), '!');
  assert.equal(hostError.titles.at(-1), 'Could not connect to IDM. Open the desktop app.');
});

test('forwards regular browser downloads to IDM with cookies and resumes on rejection', async () => {
  const item = {
    id: 91,
    state: 'in_progress',
    url: 'https://drive.google.com/uc?export=download&id=abc',
    finalUrl: 'https://drive.usercontent.google.com/download?id=abc',
    referrer: 'https://drive.google.com/file/d/abc/view',
    filename: '/Users/test/Downloads/report.pdf',
    tabId: 8,
  };
  const cookieList = [
    { name: 'SID', value: 'session-token' },
    { name: 'HSID', value: 'account-token' },
  ];
  const worker = loadWorker({ downloadItem: item, cookies: cookieList });

  worker.listeners.downloadCreated(item);
  await new Promise((resolve) => setImmediate(resolve));

  assert.deepEqual(worker.downloadOperations.slice(0, 2), [
    ['pause', 91],
    ['cookies', 'https://drive.usercontent.google.com/download?id=abc'],
  ]);
  assert.deepEqual(JSON.parse(JSON.stringify(worker.nativeMessages[0].message)), {
    type: 'add_download',
    url: 'https://drive.usercontent.google.com/download?id=abc',
    isStream: false,
    headers: {
      referer: 'https://drive.google.com/file/d/abc/view',
      cookie: 'SID=session-token; HSID=account-token',
    },
    fileName: 'report.pdf',
  });
  assert.deepEqual(worker.downloadOperations.at(-1), ['cancel', 91]);
});

test('resumes the browser download if IDM rejects it or Chrome cannot pause it', async () => {
  const item = {
    id: 92,
    state: 'in_progress',
    url: 'https://example.com/archive.zip',
    filename: '/Downloads/archive.zip',
  };
  const rejected = loadWorker({ response: { ok: false, error: 'IDM is closed.' }, downloadItem: item });
  rejected.listeners.downloadCreated(item);
  await new Promise((resolve) => setImmediate(resolve));
  assert.deepEqual(rejected.downloadOperations.at(-1), ['resume', 92]);
  assert.equal(rejected.downloadOperations.some(([operation]) => operation === 'cancel'), false);

  const unpausable = loadWorker({ downloadItem: item, downloadPauseError: new Error('not active') });
  unpausable.listeners.downloadCreated(item);
  await new Promise((resolve) => setImmediate(resolve));
  assert.equal(unpausable.nativeMessages.length, 0);
  assert.deepEqual(unpausable.downloadOperations, [['pause', 92]]);
});

test('does not intercept extension, incognito, completed, or non-HTTP downloads', async () => {
  const base = {
    id: 93,
    state: 'in_progress',
    url: 'https://example.com/archive.zip',
    filename: '/Downloads/archive.zip',
  };
  for (const item of [
    { ...base, byExtensionId: 'another-extension' },
    { ...base, incognito: true },
    { ...base, state: 'complete' },
    { ...base, url: 'blob:https://example.com/archive' },
  ]) {
    const worker = loadWorker({ downloadItem: item });
    worker.listeners.downloadCreated(item);
    await new Promise((resolve) => setImmediate(resolve));
    assert.equal(worker.nativeMessages.length, 0);
    assert.equal(worker.downloadOperations.length, 0);
  }
});
