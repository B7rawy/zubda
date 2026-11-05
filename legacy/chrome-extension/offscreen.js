// Does the recording. Every few seconds the audio goes to IndexedDB, so a Chrome crash
// mid-meeting loses seconds rather than the whole recording.

const MIME = 'audio/webm;codecs=opus';
const CHUNK_MS = 5000;
const BITRATE = 64000;

let active = null;

function openDb() {
  return new Promise((resolve, reject) => {
    const request = indexedDB.open('meet-recorder', 1);
    request.onupgradeneeded = () => {
      const db = request.result;
      db.createObjectStore('sessions', { keyPath: 'id' });
      db.createObjectStore('chunks', { autoIncrement: true }).createIndex('session', 'session');
    };
    request.onsuccess = () => resolve(request.result);
    request.onerror = () => reject(request.error);
  });
}

const dbReady = openDb();

function done(request) {
  return new Promise((resolve, reject) => {
    request.onsuccess = () => resolve(request.result);
    request.onerror = () => reject(request.error);
  });
}

async function store(name, mode = 'readonly') {
  return (await dbReady).transaction(name, mode).objectStore(name);
}

const send = (message) => chrome.runtime.sendMessage({ target: 'background', ...message });

function record(stream, track, recording) {
  const recorder = new MediaRecorder(stream, { mimeType: MIME, audioBitsPerSecond: BITRATE });
  recorder.ondataavailable = ({ data }) => {
    if (!data.size) return;
    recording.writes = recording.writes.then(async () => {
      await done((await store('chunks', 'readwrite')).add({ session: recording.session.id, track, blob: data }));
    });
  };
  recording.stopped.push(new Promise((resolve) => { recorder.onstop = resolve; }));
  recording.recorders.push(recorder);
}

async function startRecording({ streamId, session }) {
  if (active) return { ok: false, error: 'فيه تسجيل شغال بالفعل.' };

  // No stream id means an in-person meeting: the mic is the only source, so it must work.
  if (!streamId) {
    let micStream;
    try {
      // Echo cancellation would treat the people across the table as echo and thin them out.
      micStream = await navigator.mediaDevices.getUserMedia({
        audio: { echoCancellation: false, noiseSuppression: true, autoGainControl: true },
      });
    } catch {
      return { ok: false, error: 'المايك مش متاح، ومن غيره مفيش حاجة تتسجل.' };
    }
    return begin({ session, micStream, micTrack: 'room', ender: micStream });
  }

  const tabStream = await navigator.mediaDevices.getUserMedia({
    audio: { mandatory: { chromeMediaSource: 'tab', chromeMediaSourceId: streamId } },
    video: false,
  });

  // Capturing a tab mutes it for the user, so route the audio back to the speakers.
  const context = new AudioContext();
  context.createMediaStreamSource(tabStream).connect(context.destination);

  let micStream = null;
  try {
    micStream = await navigator.mediaDevices.getUserMedia({
      audio: { echoCancellation: true, noiseSuppression: true, autoGainControl: true },
    });
  } catch (error) {
    console.warn('Microphone unavailable', error);
  }
  return begin({ session, tabStream, micStream, context, micTrack: 'me', ender: tabStream });
}

async function begin({ session, tabStream = null, micStream, context = null, micTrack, ender }) {

  await done((await store('sessions', 'readwrite')).put(session));

  const recording = {
    session, tabStream, micStream, context,
    recorders: [], stopped: [], writes: Promise.resolve(), stopping: false,
  };
  if (tabStream) record(tabStream, 'others', recording);
  if (micStream) record(micStream, micTrack, recording);
  recording.recorders.forEach((recorder) => recorder.start(CHUNK_MS));
  active = recording;

  // The tab was closed, or the only mic was unplugged: save what we have.
  ender.getAudioTracks()[0].addEventListener('ended', () => {
    send({ type: 'autoStopped' }).finally(stopRecording);
  });

  return { ok: true, micOk: Boolean(micStream) };
}

async function stopRecording() {
  if (!active || active.stopping) return;
  const recording = active;
  recording.stopping = true;

  recording.recorders.forEach((recorder) => {
    if (recorder.state !== 'inactive') recorder.stop();
  });
  await Promise.all(recording.stopped);
  await recording.writes;

  recording.tabStream?.getTracks().forEach((track) => track.stop());
  recording.micStream?.getTracks().forEach((track) => track.stop());
  await recording.context?.close();
  active = null;

  const error = await finalize(recording.session, { endedAt: new Date().toISOString() });
  await send({ type: 'finished', folder: recording.session.folder, error });
}

async function saveBlob(blob, filename) {
  const url = URL.createObjectURL(blob);
  try {
    const result = await send({ type: 'save', url, filename });
    if (!result?.ok) throw new Error(result?.error || `Could not save ${filename}`);
    return result.path;
  } finally {
    URL.revokeObjectURL(url);
  }
}

// Chunks are only deleted after every file has been saved, so a failed save can be retried later.
async function finalize(session, extra) {
  try {
    const chunks = await done((await store('chunks')).index('session').getAll(session.id));
    const tracks = [...new Set(chunks.map((chunk) => chunk.track))];

    const files = {};
    for (const track of tracks) {
      const parts = chunks.filter((chunk) => chunk.track === track).map((chunk) => chunk.blob);
      files[track] = await saveBlob(new Blob(parts, { type: 'audio/webm' }), `${session.folder}/${track}.webm`);
    }

    if (tracks.length) {
      // Written last: the transcriber treats session.json as "this recording is complete".
      // `app`, `folder` and `files` let it sort out randomly named downloads.
      const meta = JSON.stringify({
        ...session.meta, ...extra, tracks, app: 'meet-recorder', folder: session.folder, files,
      }, null, 2);
      await saveBlob(new Blob([meta], { type: 'application/json' }), `${session.folder}/session.json`);
    }

    const keys = await done((await store('chunks')).index('session').getAllKeys(session.id));
    const chunkStore = await store('chunks', 'readwrite');
    await Promise.all(keys.map((key) => done(chunkStore.delete(key))));
    await done((await store('sessions', 'readwrite')).delete(session.id));
    return null;
  } catch (error) {
    console.error(error);
    return String(error);
  }
}

async function recoverSessions() {
  if (active) return;
  const sessions = await done((await store('sessions')).getAll());
  let folder = null;
  let error = null;
  for (const session of sessions) {
    error = (await finalize(session, { endedAt: null, recovered: true })) || error;
    folder = session.folder;
  }
  await send({ type: 'finished', folder, error });
}

const handlers = {
  start: startRecording,
  stop: async () => {
    stopRecording();
    return { ok: true };
  },
  mic: async ({ enabled }) => {
    // A disabled track records silence, which keeps both files on the same timeline.
    active?.micStream?.getAudioTracks().forEach((track) => { track.enabled = enabled; });
    return { ok: true };
  },
  recover: async () => {
    recoverSessions();
    return { ok: true };
  },
};

chrome.runtime.onMessage.addListener((message, _sender, respond) => {
  if (message.target !== 'offscreen') return false;
  handlers[message.type](message)
    .then(respond)
    .catch((error) => respond({ ok: false, error: String(error) }));
  return true;
});
