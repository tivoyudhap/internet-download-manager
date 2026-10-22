import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import test from 'node:test';
import vm from 'node:vm';

const source = await readFile(new URL('./service_worker.js', import.meta.url), 'utf8');

function loadWorker({ response = { ok: true }, lastError = null } = {}) {
  const listeners = {};
  const menus = [];
  const nativeMessages = [];
  const badges = [];
  const titles = [];
  const runtime = { lastError: null };
  const chrome = {
    runtime: {
      ...runtime,
      onInstalled: { addListener: (listener) => { listeners.installed = listener; } },
      sendNativeMessage: (host, message, callback) => {
        nativeMessages.push({ host, message });
        chrome.runtime.lastError = lastError;
        callback(response);
        chrome.runtime.lastError = null;
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
  vm.runInNewContext(source, {
    chrome,
    URL,
    setTimeout: () => 0,
  });
  return { chrome, listeners, menus, nativeMessages, badges, titles };
}

test('registers one Download with IDM menu for links and media', () => {
  const worker = loadWorker();
  worker.listeners.installed();

  assert.deepEqual(JSON.parse(JSON.stringify(worker.menus)), [{
    id: 'idm-download-with-idm',
    title: 'Download with IDM',
    contexts: ['link', 'video', 'audio', 'image'],
  }]);
});

test('sends a link URL through the native messaging host', () => {
  const worker = loadWorker();
  worker.listeners.clicked({ menuItemId: 'idm-download-with-idm', linkUrl: 'https://example.com/file.zip' });

  assert.deepEqual(JSON.parse(JSON.stringify(worker.nativeMessages)), [{
    host: 'com.tivoyudhap.internet_download_manager',
    message: { type: 'add_download', url: 'https://example.com/file.zip' },
  }]);
  assert.equal(worker.badges.at(-1), '✓');
});

test('sends a media source URL when the context is not a link', () => {
  const worker = loadWorker();
  worker.listeners.clicked({ menuItemId: 'idm-download-with-idm', srcUrl: 'https://cdn.example.com/movie.mp4' });

  assert.equal(worker.nativeMessages[0].message.url, 'https://cdn.example.com/movie.mp4');
});

test('rejects non-HTTP and credentialed URLs before native messaging', () => {
  for (const url of ['file:///tmp/archive.zip', 'ftp://example.com/archive.zip', 'https://user:pass@example.com/file.zip']) {
    const worker = loadWorker();
    worker.listeners.clicked({ menuItemId: 'idm-download-with-idm', linkUrl: url });
    assert.equal(worker.nativeMessages.length, 0);
    assert.equal(worker.badges.at(-1), '!');
  }
});

test('shows an error when the desktop app rejects a request', () => {
  const worker = loadWorker({ response: { ok: false, error: 'Open IDM first.' } });
  worker.listeners.clicked({ menuItemId: 'idm-download-with-idm', linkUrl: 'https://example.com/file.zip' });

  assert.equal(worker.badges.at(-1), '!');
  assert.equal(worker.titles.at(-1), 'Open IDM first.');
});

test('shows an error when the native host is unavailable', () => {
  const worker = loadWorker({ lastError: { message: 'Specified native messaging host not found.' } });
  worker.listeners.clicked({ menuItemId: 'idm-download-with-idm', linkUrl: 'https://example.com/file.zip' });

  assert.equal(worker.badges.at(-1), '!');
  assert.equal(worker.titles.at(-1), 'Could not connect to IDM. Open the desktop app.');
});
