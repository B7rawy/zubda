// Owns recording state and downloads. Offscreen documents can't use chrome.storage or
// chrome.downloads, and this worker can't record, so the two talk through messages.

const IDLE = { status: 'idle' };

const getState = async () => (await chrome.storage.session.get('state')).state || IDLE;

async function setState(state) {
  await chrome.storage.session.set({ state });
  const recording = state.status === 'recording';
  const saving = state.status === 'saving';
  await chrome.action.setBadgeText({ text: recording ? 'REC' : saving ? '...' : '' });
  await chrome.action.setBadgeBackgroundColor({ color: recording ? '#d93025' : '#5f6368' });
}

async function ensureOffscreen() {
  if (await chrome.offscreen.hasDocument()) return;
  await chrome.offscreen.createDocument({
    url: 'offscreen.html',
    reasons: ['USER_MEDIA'],
    justification: 'Record the Meet tab audio and the microphone.',
  });
}

const toOffscreen = (message) => chrome.runtime.sendMessage({ target: 'offscreen', ...message });

function pad(n) {
  return String(n).padStart(2, '0');
}

function folderName(date, code) {
  const day = `${date.getFullYear()}-${pad(date.getMonth() + 1)}-${pad(date.getDate())}`;
  return `Meetings/${day}_${pad(date.getHours())}-${pad(date.getMinutes())}_${code}`;
}

// mode 'online' records the Meet tab plus the mic; 'room' records only the mic, for a
// meeting held in person in front of the laptop.
async function start({ mode = 'online', tabId, title, url }) {
  const room = mode === 'room';
  const streamId = room ? null : await chrome.tabCapture.getMediaStreamId({ targetTabId: tabId });
  const now = new Date();
  const code = room ? 'in-person' : new URL(url).pathname.match(/[a-z]+-[a-z]+-[a-z]+/)?.[0] || 'meeting';
  const session = {
    id: crypto.randomUUID(),
    folder: folderName(now, code),
    meta: room
      ? { title: 'ميتنج حضوري', mode, meetingCode: code, startedAt: now.toISOString() }
      : { title, mode, meetingCode: code, url: url.split('?')[0], startedAt: now.toISOString() },
  };

  await ensureOffscreen();
  const result = await toOffscreen({ type: 'start', streamId, session });
  if (!result?.ok) {
    await chrome.offscreen.closeDocument().catch(() => {});
    return { ok: false, error: result?.error || 'تعذّر بدء التسجيل.' };
  }
  await setState({
    status: 'recording',
    mode,
    startedAt: now.getTime(),
    tabId,
    micOk: result.micOk,
    micEnabled: result.micOk,
    folder: session.folder,
  });
  return { ok: true };
}

function waitForDownload(id) {
  return new Promise((resolve, reject) => {
    const check = (item) => {
      if (item?.state === 'complete' || item?.state?.current === 'complete') finish(resolve);
      else if (item?.state === 'interrupted' || item?.state?.current === 'interrupted') {
        finish(() => reject(new Error('Download interrupted')));
      }
    };
    const listener = (delta) => {
      if (delta.id === id) check(delta);
    };
    const finish = (settle) => {
      chrome.downloads.onChanged.removeListener(listener);
      settle();
    };
    chrome.downloads.onChanged.addListener(listener);
    chrome.downloads.search({ id }).then(([item]) => check(item));
  });
}

// Returns the real path: another extension listening to onDeterminingFilename makes Chrome
// ignore our filename and save under a random one, and we can't override that from here.
async function save({ url, filename }) {
  const id = await chrome.downloads.download({ url, filename, saveAs: false, conflictAction: 'uniquify' });
  await waitForDownload(id);
  const [item] = await chrome.downloads.search({ id });
  return item.filename;
}

async function recover() {
  await ensureOffscreen();
  await toOffscreen({ type: 'recover' });
}

// A dead offscreen document means the recording stopped without saving (for example Chrome
// discarded it). Its chunks are still in IndexedDB, so save them instead of showing a stuck state.
async function reconcile() {
  const state = await getState();
  if (state.status !== 'idle' && !(await chrome.offscreen.hasDocument())) {
    await setState(IDLE);
    await recover();
  }
  return getState();
}

const handlers = {
  getState: reconcile,
  start,
  stop: async () => {
    const state = await getState();
    if (state.status !== 'recording') return { ok: false };
    await setState({ ...state, status: 'saving' });
    return toOffscreen({ type: 'stop' });
  },
  mic: async ({ enabled }) => {
    await toOffscreen({ type: 'mic', enabled });
    await setState({ ...(await getState()), micEnabled: enabled });
    return { ok: true };
  },
  autoStopped: async () => {
    await setState({ ...(await getState()), status: 'saving' });
    return { ok: true };
  },
  save: async (message) => {
    try {
      return { ok: true, path: await save(message) };
    } catch (error) {
      return { ok: false, error: String(error) };
    }
  },
  finished: async ({ folder, error }) => {
    const state = await getState();
    if (state.status === 'recording') return { ok: true };
    await setState(IDLE);
    await chrome.storage.session.set({ last: { folder, error: error || null } });
    await chrome.offscreen.closeDocument().catch(() => {});
    return { ok: true };
  },
};

chrome.runtime.onMessage.addListener((message, _sender, respond) => {
  if (message.target !== 'background') return false;
  handlers[message.type](message)
    .then(respond)
    .catch((error) => respond({ ok: false, error: String(error) }));
  return true;
});

chrome.runtime.onInstalled.addListener(({ reason }) => {
  if (reason === 'install') chrome.tabs.create({ url: 'welcome.html' });
  recover();
});

chrome.runtime.onStartup.addListener(recover);
