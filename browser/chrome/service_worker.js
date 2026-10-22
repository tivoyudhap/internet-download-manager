const NATIVE_HOST = 'com.tivoyudhap.internet_download_manager';
const MENU_ID = 'idm-download-with-idm';

chrome.runtime.onInstalled.addListener(() => {
  chrome.contextMenus.removeAll(() => {
    chrome.contextMenus.create({
      id: MENU_ID,
      title: 'Download with IDM',
      contexts: ['link', 'video', 'audio', 'image'],
    });
  });
});

chrome.contextMenus.onClicked.addListener((info) => {
  if (info.menuItemId !== MENU_ID) return;
  const rawUrl = info.linkUrl || info.srcUrl;
  const url = normalizeDownloadUrl(rawUrl);
  if (!url) {
    setStatus('!', 'Only HTTP and HTTPS links can be sent to IDM.');
    return;
  }

  chrome.runtime.sendNativeMessage(
    NATIVE_HOST,
    { type: 'add_download', url },
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

function setStatus(badge, title) {
  chrome.action.setBadgeText({ text: badge });
  chrome.action.setTitle({ title });
  setTimeout(() => chrome.action.setBadgeText({ text: '' }), 4000);
}
