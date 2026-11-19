async () => {
  const reader = window.KnowLakeReader;
  let checks = 0;
  const assert = (value, message) => { if (!value) throw new Error(message); checks += 1; };
  const canvas = document.createElement('canvas');
  canvas.width = 1800;
  canvas.height = 1200;
  const context = canvas.getContext('2d');
  context.fillStyle = '#e7eee5';
  context.fillRect(0, 0, 1800, 1200);
  context.strokeStyle = '#2b614c';
  context.lineWidth = 20;
  context.strokeRect(10, 10, 1780, 1180);
  context.fillStyle = '#244f3d';
  context.font = 'bold 80px sans-serif';
  context.fillText('知识概览 · 图片浏览', 100, 180);
  context.font = '40px sans-serif';
  context.fillText('完整图像适合阅读区，放大后可拖动查看细节。', 100, 280);
  for (let row = 0; row < 2; row += 1) {
    for (let column = 0; column < 3; column += 1) {
      context.fillStyle = ['#3f7560', '#5c8975', '#86a18d'][column];
      context.fillRect(100 + column * 550, 380 + row * 350, 500, 280);
      context.fillStyle = '#fff';
      context.fillText(`${row * 3 + column + 1}  内容与证据`, 130 + column * 550, 450 + row * 350);
    }
  }
  const fixture = {
    id: 'image-fixture', title: '知识概览', imageTitle: '知识概览 · 概览图',
    imageURL: canvas.toDataURL(), content: '', theme: 'light',
    url: 'https://example.test/source',
  };
  reader.render(fixture);
  await reader.ready();
  const image = document.querySelector('#overview-image');
  const opener = document.querySelector('#image-open');
  const viewer = document.querySelector('#image-viewer');
  const viewport = document.querySelector('#image-viewport');
  const app = document.querySelector('#app');
  const scale = () => Number(viewer.dataset.scale);
  const click = id => document.getElementById(id).click();
  const key = value => document.dispatchEvent(new KeyboardEvent('keydown', { key: value, bubbles: true, cancelable: true }));
  const wheel = delta => {
    const event = new WheelEvent('wheel', { deltaY: delta, clientX: innerWidth / 2, clientY: innerHeight / 2, bubbles: true, cancelable: true });
    viewport.dispatchEvent(event);
    return event.defaultPrevented;
  };
  assert(image.naturalWidth === 1800 && image.naturalHeight === 1200, 'Overview image not loaded before ready');
  assert(getComputedStyle(image).objectFit === 'contain', 'Overview must retain the complete image');
  assert(app.getBoundingClientRect().width === innerWidth, 'Image mode retains the article width limit');
  assert(document.querySelector('#doc-header').hidden && document.querySelector('#article').hidden, 'Image mode exposes duplicate article/source header');
  assert(!document.querySelector('#image-panel').hidden, 'Image panel not shown');
  assert(document.documentElement.scrollHeight <= innerHeight, 'Overview creates unnecessary vertical scrolling');
  assert(opener.getAttribute('aria-label').includes(fixture.imageTitle), 'Image opener lacks an accessible title');
  assert(reader.diagnostics().mode === 'image', 'Image diagnostics mode missing');
  const exported = new DOMParser().parseFromString(await reader.exportHTML(), 'text/html');
  assert(exported.querySelector('img')?.src.startsWith('data:image/'), 'Image export is not self-contained');
  assert(!exported.querySelector('header,a,button,script'), 'Image export contains duplicate navigation or controls');

  assert(!viewer.hidden && app.inert, 'Image browser did not open automatically');
  assert(document.activeElement.id === 'image-close', 'Viewer does not receive keyboard focus');
  assert(getComputedStyle(document.documentElement).overflow === 'hidden', 'Viewer does not lock background scrolling');
  const fitted = scale();
  assert(fitted > 0 && fitted <= 1, 'Initial fit is invalid');
  click('image-zoom-in');
  assert(Math.abs(scale() - fitted * 1.25) < .0001, 'Zoom-in does not change scale');
  click('image-zoom-out');
  assert(Math.abs(scale() - fitted) < .0001, 'Zoom-out is not reversible');
  assert(wheel(-250) && scale() > fitted, 'Mouse/trackpad wheel does not zoom');
  click('image-fit');
  assert(Math.abs(scale() - fitted) < .0001 && viewer.dataset.x === '0' && viewer.dataset.y === '0', 'Fit does not recenter');
  key('+');
  assert(scale() > fitted, 'Keyboard zoom missing');
  key('0');
  assert(Math.abs(scale() - fitted) < .0001, 'Keyboard fit missing');
  key('Tab');
  assert(viewer.contains(document.activeElement), 'Focus escaped image browser');
  key('Escape');
  assert(viewer.hidden && !app.inert && document.activeElement === opener, 'Escape does not close and restore focus');
  assert(getComputedStyle(document.documentElement).overflow !== 'hidden', 'Closing leaves scroll locked');
  assert(!wheel(-250), 'Closing leaves wheel handler installed');

  opener.click();
  click('image-zoom-in');
  assert(Math.abs(scale() - fitted * 1.25) < .0001, 'Reopening duplicates event handlers');
  assert(reader.render({ ...fixture, theme: 'dark' }).changed === false, 'Theme update rebuilds unchanged image');
  assert(!viewer.hidden && scale() > fitted, 'Theme update loses image zoom');
  reader.render({ id: 'article-after-image', title: '返回正文', content: '切换后的正文' });
  await reader.ready();
  assert(viewer.hidden && !app.inert && !document.body.classList.contains('image-mode'), 'Switching to text leaves image state active');
  assert(document.querySelector('#article').textContent.includes('切换后的正文'), 'Text does not render after image');
  assert(!viewer.dataset.scale && !document.querySelector('#viewer-image').hasAttribute('src'), 'Switching leaves zoom/image state behind');
  assert(key('+'), 'Switching leaves keyboard shortcuts captured');
  assert(!wheel(-250), 'Switching leaves wheel handlers captured');

  reader.render(fixture);
  await reader.ready();
  key('+');
  reader.render({ ...fixture, id: 'other-image', imageTitle: '另一张概览图' });
  await reader.ready();
  assert(!viewer.hidden && document.querySelector('#viewer-image').alt === '另一张概览图', 'New artifact does not open in the viewer');
  assert(Math.abs(scale() - fitted) < .0001, 'New artifact does not start fitted');
  reader.dispose();
  assert(viewer.hidden && !app.inert && !document.documentElement.classList.contains('image-viewer-open'), 'Dispose leaves modal state');
  assert(key('Escape') && !wheel(-250), 'Dispose leaves global interaction handlers');

  reader.render({ ...fixture, id: 'interrupted-image', imageURL: 'data:image/png;base64,invalid' });
  reader.render({ id: 'current-text', title: '当前正文', content: '只保留当前正文' });
  await reader.ready();
  await new Promise(resolve => setTimeout(resolve, 20));
  assert(!document.querySelector('#reader-status').textContent, 'Old image load error leaks into new content');
  assert(viewer.hidden && document.querySelector('#article').textContent.includes('只保留当前正文'), 'Old image load replaces new content');
  reader.render(fixture);
  await reader.ready();
  window.imageViewerFixture = fixture;
  return { checks, image: [image.naturalWidth, image.naturalHeight], fitScale: fitted };
}
