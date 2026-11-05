// Meet also serves meetings under a prefix, for example /meet/abc-defg-hij.
const MEETING_URL = /^https:\/\/meet\.google\.com\/(?:[^/?#]+\/)*[a-z]+-[a-z]+-[a-z]+(?:[/?#]|$)/;

const main = document.getElementById('main');
const mic = document.getElementById('mic');
const room = document.getElementById('room');
const timer = document.getElementById('timer');
const time = document.getElementById('time');
const message = document.getElementById('message');

let ticker = null;

const toBackground = (payload) => chrome.runtime.sendMessage({ target: 'background', ...payload });

function show(text, warn = false) {
  message.hidden = !text;
  message.textContent = text || '';
  message.classList.toggle('warn', warn);
}

function tick(startedAt) {
  const seconds = Math.floor((Date.now() - startedAt) / 1000);
  const parts = [seconds / 3600, (seconds % 3600) / 60, seconds % 60];
  time.textContent = parts.map((n) => String(Math.floor(n)).padStart(2, '0')).join(':');
}

async function activeTab() {
  const [tab] = await chrome.tabs.query({ active: true, currentWindow: true });
  return tab;
}

async function render() {
  const state = await toBackground({ type: 'getState' });
  const { last } = await chrome.storage.session.get('last');
  clearInterval(ticker);

  const recording = state.status === 'recording';
  const inRoom = state.mode === 'room';
  timer.hidden = !recording;
  mic.hidden = !(recording && state.micOk);
  room.hidden = state.status !== 'idle';
  show('');

  if (recording) {
    tick(state.startedAt);
    ticker = setInterval(() => tick(state.startedAt), 1000);
    main.textContent = 'إيقاف وحفظ';
    main.disabled = false;
    if (inRoom) {
      mic.textContent = state.micEnabled ? 'إيقاف مؤقت' : 'استكمال التسجيل';
      show(state.micEnabled
        ? 'بيتسجل صوت الأوضة كلها من مايك اللابتوب. خلّي اللابتوب في النص، وما تقفلش الغطا.'
        : 'التسجيل واقف مؤقتًا.', !state.micEnabled);
      return;
    }
    mic.textContent = state.micEnabled ? 'وقّف تسجيل مايكي' : 'رجّع تسجيل مايكي';
    if (!state.micOk) show('بيتسجل صوت الميتنج بس، من غير مايكك.', true);
    else if (!state.micEnabled) show('مايكك مش بيتسجل دلوقتي.', true);
    else show('كتم المايك في ميت مش بيوقف تسجيله هنا. استخدم الزرار ده لو هتقول حاجة خاصة.');
    return;
  }

  if (state.status === 'saving') {
    main.textContent = 'جاري الحفظ…';
    main.disabled = true;
    setTimeout(render, 700);
    return;
  }

  const tab = await activeTab();
  const onMeeting = MEETING_URL.test(tab?.url || '');
  main.textContent = 'سجّل ميتنج جوجل ميت';
  main.disabled = !onMeeting;
  room.disabled = false;

  if (last?.error) show(`الحفظ ما كملش، وهيتحاول تاني لما تفتح كروم من جديد. ${last.error}`, true);
  else if (last?.folder) {
    message.hidden = false;
    message.classList.remove('warn');
    message.textContent = 'اتحفظ التسجيل. قول لكلود «شوف آخر ميتنج».';
  } else if (!onMeeting) show('للأونلاين افتح الميتنج في جوجل ميت الأول. للحضوري دوس الزرار التاني من أي صفحة.');
}

async function startRecording(mode) {
  const tab = await activeTab();
  main.disabled = true;
  room.disabled = true;

  const permission = await navigator.permissions.query({ name: 'microphone' });
  if (permission.state !== 'granted') {
    chrome.tabs.create({ url: 'welcome.html' });
    return;
  }

  const result = await toBackground({ type: 'start', mode, tabId: tab.id, title: tab.title, url: tab.url });
  if (!result?.ok) throw new Error(result?.error || 'تعذّر بدء التسجيل.');
  await chrome.storage.session.remove('last');
}

main.addEventListener('click', async () => {
  try {
    const state = await toBackground({ type: 'getState' });
    if (state.status === 'recording') await toBackground({ type: 'stop' });
    else await startRecording('online');
    await render();
  } catch (error) {
    await render();
    show(error.message, true);
  }
});

room.addEventListener('click', async () => {
  try {
    await startRecording('room');
    await render();
  } catch (error) {
    await render();
    show(error.message, true);
  }
});

mic.addEventListener('click', async () => {
  const state = await toBackground({ type: 'getState' });
  await toBackground({ type: 'mic', enabled: !state.micEnabled });
  await render();
});

render();
