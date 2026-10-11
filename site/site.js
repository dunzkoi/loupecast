// Copy buttons on both pages; the wording follows <html lang>.
const say = document.documentElement.lang === 'ko'
  ? { copy: '복사', done: '복사됨', copied: '복사했습니다.', selected: '명령을 선택했습니다. ⌘C로 복사하세요.' }
  : { copy: 'Copy', done: 'Copied', copied: 'Copied.', selected: 'Command selected. Press ⌘C to copy.' };
for (const b of document.querySelectorAll('[data-copy]')) {
  b.addEventListener('click', async () => {
    const text = b.dataset.copy;
    try { await navigator.clipboard.writeText(text); }
    catch {
      // file:// or old browsers: select the command so ⌘C works
      const r = document.createRange(); r.selectNodeContents(b.previousElementSibling);
      getSelection().removeAllRanges(); getSelection().addRange(r);
      document.getElementById('copy-status').textContent = say.selected;
      return;
    }
    b.dataset.done = ''; b.querySelector('span').textContent = say.done;
    document.getElementById('copy-status').textContent = say.copied;
    clearTimeout(b._t); b._t = setTimeout(() => { delete b.dataset.done; b.querySelector('span').textContent = say.copy; }, 1800);
  });
}
