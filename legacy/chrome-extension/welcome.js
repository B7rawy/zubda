// The offscreen document can't show a permission prompt, so the mic is granted from this page.
const result = document.getElementById('result');

document.getElementById('grant').addEventListener('click', async () => {
  result.hidden = false;
  try {
    const stream = await navigator.mediaDevices.getUserMedia({ audio: true });
    stream.getTracks().forEach((track) => track.stop());
    result.className = 'ok';
    result.textContent = 'تمام. افتح الميتنج ودوس على أيقونة الإضافة، وبعدين «ابدأ التسجيل».';
  } catch {
    result.className = 'fail';
    result.textContent = 'الإذن اترفض. اسمح بالمايك من أيقونة القفل جنب العنوان وجرّب تاني.';
  }
});
