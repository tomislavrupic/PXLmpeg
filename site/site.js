'use strict';
const pipeline = document.querySelector('.pipeline');
const modeButtons = [...document.querySelectorAll('[data-mode]')];
const descriptions = {
  transcode: 'Decode on hardware, rotate or resize pixels on the GPU, then encode on hardware. Original footage stays untouched.',
  remux: 'Copy supported compressed video and AAC between MOV and MP4. No decoding, GPU processing, or re-encoding; source codec and display transform are retained.'
};
for (const button of modeButtons) {
  button.addEventListener('click', () => {
    const mode = button.dataset.mode;
    if (!Object.hasOwn(descriptions, mode)) return;
    pipeline.dataset.currentMode = mode;
    for (const item of modeButtons) item.setAttribute('aria-pressed', String(item === button));
    for (const label of document.querySelectorAll('.stage-description')) label.textContent = mode === 'remux' ? 'Bypassed · compressed copy' : label.dataset.active;
    document.querySelector('#mode-description').textContent = descriptions[mode];
    document.querySelector('#mode-command').textContent = mode === 'remux' ? 'pxlmpeg remux copy.json' : 'pxlmpeg run job.json';
  });
}
document.querySelector('#copy-command').addEventListener('click', async () => {
  const code = document.querySelector('#clone-command');
  const status = document.querySelector('#copy-status');
  try {
    await navigator.clipboard.writeText(code.textContent);
    status.textContent = 'Commands copied. Paste them into Terminal.';
  } catch {
    const range = document.createRange(); range.selectNodeContents(code);
    const selection = window.getSelection(); selection.removeAllRanges(); selection.addRange(range);
    status.textContent = 'Commands selected. Press ⌘C or Ctrl+C to copy.';
  }
});
