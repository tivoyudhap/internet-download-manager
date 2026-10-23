import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import test from 'node:test';
import vm from 'node:vm';

const source = await readFile(new URL('./service_worker.js', import.meta.url), 'utf8');
const contentSource = await readFile(new URL('./content_script.js', import.meta.url), 'utf8');

function loadWorker({ response = { ok: true }, lastError = null, videoSource = null } = {}) {
  const listeners = { beforeSendHeaders: [], headersReceived: [] };
  const menus = [];
  const nativeMessages = [];
  const badges = [];
  const titles = [];
  const session = {};
  const chrome = {
    runtime: {
      lastError: null,
      onInstalled: { addListener: (listener) => { listeners.installed = listener; } },
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
    webRequest: {
      onBeforeSendHeaders: { addListener: (listener) => listeners.beforeSendHeaders.push(listener) },
      onHeadersReceived: { addListener: (listener) => listeners.headersReceived.push(listener) },
    },
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
  return { chrome, listeners, menus, nativeMessages, badges, titles, session };
}

function loadContentScript(video, pageUrl) {
  let listener;
  const chrome = {
    runtime: {
      onMessage: { addListener: (callback) => { listener = callback; } },
    },
  };
  vm.runInNewContext(contentSource, {
    chrome,
    document: { querySelectorAll: () => [video] },
    location: { href: pageUrl },
    URL,
  });
  return listener;
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
  const listener = loadContentScript({
    paused: true,
    readyState: 0,
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
  assert.equal(worker.titles.at(-1), 'No video stream found. Start playback, then try again.');
});

test('asks the user to start playback when the page has no captured video', async () => {
  const worker = loadWorker();

  await worker.listeners.clicked({
    menuItemId: 'idm-download-with-idm',
    tabId: 12,
  });

  assert.equal(worker.nativeMessages.length, 0);
  assert.equal(worker.titles.at(-1), 'No video stream found. Start playback, then try again.');
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
