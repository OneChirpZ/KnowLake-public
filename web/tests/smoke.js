async () => {
  const reader = window.KnowLakeReader;
  let checks = 0;
  const assert = (condition, message) => { if (!condition) throw new Error(message); checks += 1; };
  const messages = [];
  window.webkit = { messageHandlers: { knowlake: { postMessage: message => messages.push(message) } } };
  const fixture = {
    id: 'fixture', title: '知识与来源', platform: 'bilibili',
    url: 'https://www.bilibili.com/video/BV1fixture',
    content: '# 知识与来源\n\n## 摘要\n\n中文内容可以回溯。\n\n| 平台 | 产物 |\n|---|---|\n| B 站 | 笔记 |\n\n<a id="segment-1"></a>\n\n字幕内容。\n\n[引用](knowlake-source://source-1#segment-1)',
    segments: [{ start: 85, end: 95, text: '字幕内容。' }],
  };
  reader.render(fixture);
  await reader.ready();
  assert(document.querySelectorAll('#article table').length === 1, 'GFM table missing');
  assert(document.querySelector('a.time-link').href.endsWith('t=85'), 'Timestamp not linked');
  document.querySelector('a[href^="knowlake-source:"]').click();
  assert(messages.some(message => message.type === 'openSource' && message.sourceID === 'source-1'), 'Source bridge missing');
  const found = await reader.find('字幕');
  assert(found.found && found.count === 1, 'Full-text find failed');
  assert(await reader.scrollToAnchor('segment-1'), 'Anchor navigation failed');
  const html = await reader.exportHTML();
  assert(html.includes('<style>') && html.includes('知识与来源'), 'HTML export not standalone');
  assert(!html.includes('<script'), 'HTML export executes scripts');
  assert(reader.render(fixture).changed === false, 'Unchanged document rerendered');
  assert(reader.render({ ...fixture, segments: structuredClone(fixture.segments) }).changed === false, 'Equivalent native payload rebuilt the document');

  const wechat = {
    id: 'wechat', sourceID: 'article-1', title: '文章中的知识', platform: 'wechat',
    url: 'https://mp.weixin.qq.com/s/fixture',
    content: '# 文章中的知识\n\n<a id="segment-1"></a>\n\n第一段正文。\n\n<a id="segment-2"></a>\n\n## 方法\n\n第二段论据。\n\n[论据引用](knowlake-source://article-1#segment-2)',
    segments: [{ start: 0, end: 0, text: '第一段正文。' }, { start: 0, end: 0, text: '第二段论据。' }],
  };
  reader.render(wechat);
  await reader.ready();
  assert(!document.querySelector('#article .time-link'), 'Article must not display video timestamps');
  assert(document.getElementById('segment-1')?.textContent === '', 'Article anchor must remain invisible');
  assert(document.getElementById('segment-1')?.parentElement.tagName !== 'P', 'Invisible article anchor leaves a blank paragraph row');
  assert(await reader.scrollToAnchor('segment-2'), 'Article paragraph anchor lost');
  document.querySelector('#article a[href^="knowlake-source:"]').click();
  assert(messages.some(message => message.type === 'openSource' && message.sourceID === 'article-1' && message.anchor === 'segment-2'), 'Article citation bridge missing');
  const articleExport = new DOMParser().parseFromString(await reader.exportHTML(), 'text/html');
  assert(!articleExport.querySelector('a[href*="t=0"]'), 'Article export contains bogus timestamp');
  assert(articleExport.querySelector('a[href="#segment-2"]'), 'Article export must preserve internal paragraph navigation');
  assert(document.getElementById('doc-title').getBoundingClientRect().top < 80, 'Reading header has too much top whitespace');
  const articleNote = { ...wechat, id: 'wechat-note', content: '总结中的证据。[来源](knowlake-source://article-1#segment-2)' };
  reader.render(articleNote);
  await reader.ready();
  const noteExport = new DOMParser().parseFromString(await reader.exportHTML(), 'text/html');
  assert(noteExport.querySelector('#article a').getAttribute('href') === wechat.url, 'Article note citation should link to original article, not t=0');

  reader.render({
    ...wechat, id: 'local-source-links',
    content: '[本地全文](source.md) · [证据](./source.md#segment-2) · [段落](#segment-2) · [附件](notes.md)',
  });
  await reader.ready();
  const localLinks = [...document.querySelectorAll('#article a')];
  assert(localLinks[0].getAttribute('href') === 'knowlake-source://article-1', 'Local source file should open the source, not .reader/source.md');
  assert(localLinks[1].getAttribute('href') === 'knowlake-source://article-1#segment-2', 'Local source fragment not normalized');
  assert(localLinks[3].getAttribute('href') === 'notes.md', 'Unrelated attachment path was rewritten');
  localLinks[0].click();
  assert(messages.some(message => message.type === 'openSource' && message.sourceID === 'article-1' && message.anchor === ''), 'Whole-source link did not open source');
  const beforeFragment = messages.length;
  localLinks[2].click();
  await Promise.resolve();
  assert(messages.slice(beforeFragment).some(message => message.type === 'openSource' && message.anchor === 'segment-2'), 'Missing in-page evidence should open the original paragraph');
  const localExport = new DOMParser().parseFromString(await reader.exportHTML(), 'text/html');
  assert([...localExport.querySelectorAll('#article a')].slice(0,3).every(anchor => anchor.getAttribute('href') === wechat.url), 'Export leaves broken source.md/fragment links');

  const zeroTime = { ...fixture, id: 'zero-time', sourceID: 'source-1', segments: [{start: 0, end: 10, text:'视频开始。'}] };
  reader.render(zeroTime);
  await reader.ready();
  assert(document.querySelector('#article .time-link')?.textContent === '0:00', 'Valid video start at zero must stay visible');
  assert(document.querySelector('#article .time-link')?.href.endsWith('t=0'), 'Valid zero timestamp link missing');
  const videoExport = new DOMParser().parseFromString(await reader.exportHTML(), 'text/html');
  assert(videoExport.querySelector('a[href$="t=0"]'), 'Video timestamp not retained on export');
  reader.render({...zeroTime, id:'invalid-time', segments:[{start:-1,end:10,text:'Invalid'}]});
  await reader.ready();
  assert(!document.querySelector('#article .time-link'), 'Negative video timestamp must not render');

  reader.render({
    id: 'sanitize', title: '内容净化',
    content: '<script>window.__unsafe=true</script>\n\n<img onerror="window.__unsafe=true" src="data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aC3sAAAAASUVORK5CYII=">\n\n[bad](javascript:alert(1))',
  });
  await reader.ready();
  assert(!window.__unsafe && !document.querySelector('#article script'), 'Unsafe HTML executed');
  assert(!document.querySelector('#article [onerror]'), 'Event attribute preserved');
  assert(!document.querySelector('#article a[href^="javascript:"]'), 'Unsafe link preserved');

  const anchorFixture = {
    ...wechat, id: 'chunk-boundary-anchor',
    content: `${'前文布局。'.repeat(260)}\n\n<a id="segment-1"></a>\n\n## 引用目标\n\n![原文图片](data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aC3sAAAAASUVORK5CYII=)\n\n<a id="segment-2"></a>\n\n目标段落。\n\n${'后续内容。\n\n'.repeat(80)}`,
  };
  reader.render(anchorFixture);
  await reader.ready();
  const boundaryAnchor = document.getElementById('segment-1');
  assert(!boundaryAnchor.nextElementSibling, 'Fixture must put anchor at the end of a render chunk');
  assert(await reader.scrollToAnchor('segment-1'), 'Chunk-boundary anchor navigation failed');
  assert(document.querySelector('.anchor-flash')?.textContent === '引用目标', 'Chunk-boundary citation highlighted the preceding chunk');
  const firstAnimation = document.querySelector('.anchor-flash').getAnimations()[0];
  assert(await reader.scrollToAnchor('segment-1'), 'Repeated citation failed');
  assert(document.querySelector('.anchor-flash').getAnimations()[0] !== firstAnimation, 'Repeated citation did not restart highlight');

  const delayedImage = document.querySelector('#article img');
  delayedImage.loading = 'eager';
  await delayedImage.decode().catch(() => {});
  delayedImage.loading = 'lazy';
  Object.defineProperty(delayedImage, 'complete', { configurable: true, get: () => false });
  const delayedJump = reader.scrollToAnchor('segment-2');
  await new Promise(resolve => setTimeout(resolve, 20));
  assert(delayedImage.loading === 'eager', 'Citation did not start loading preceding lazy image');
  delayedImage.height = 1000;
  delayedImage.width = 600;
  delayedImage.dispatchEvent(new Event('load'));
  assert(await delayedJump, 'Citation did not finish after image layout settled');
  const highlighted = document.querySelector('.anchor-flash');
  assert(highlighted?.textContent === '目标段落。', 'Citation highlighted the wrong paragraph');
  const bounds = highlighted.getBoundingClientRect();
  assert(bounds.top >= 0 && bounds.bottom <= innerHeight, `Image layout displaced citation out of viewport ${JSON.stringify({top:bounds.top,bottom:bounds.bottom,scrollY,innerHeight,image:delayedImage.getBoundingClientRect().toJSON()})}`);
  assert(await reader.scrollToAnchor('segment-999') === false, 'Missing citation silently jumped elsewhere');
  assert(await reader.scrollToAnchor('%bad') === false, 'Malformed anchor was not handled');

  const returnCancelledJump = reader.scrollToAnchor('segment-2');
  await Promise.resolve();
  reader.cancelAnchor();
  window.scrollTo({ top: 50, behavior: 'instant' });
  delayedImage.dispatchEvent(new Event('load'));
  assert(await returnCancelledJump === false, 'Pending citation completed after returning');
  assert(Math.abs(window.scrollY - 50) < 2, 'Pending citation displaced return position');

  const staleJump = reader.scrollToAnchor('segment-2');
  await Promise.resolve();
  reader.render({ ...wechat, id: 'after-cancel', content: '<a id="segment-2"></a>\n\n另一篇文章。' });
  delayedImage.dispatchEvent(new Event('load'));
  await reader.ready();
  assert(await staleJump === false, 'Old citation completed after switching documents');
  assert(!document.querySelector('.anchor-flash'), 'Old citation highlighted the replacement document');

  const disposedJump = reader.scrollToAnchor('segment-2');
  reader.dispose();
  assert(await disposedJump === false, 'Disposed reader completed an old citation');

  const longContent = Array.from({ length: 400 }, (_, i) => `## 章节 ${i}\n\n${'知识的来源需要可以回溯，阅读应该清楚而流畅。'.repeat(24)}\n\n`).join('');
  reader.render({ id: 'long', title: '长文样本', content: longContent });
  await reader.ready();
  assert(document.querySelectorAll('#article h2').length === 400, 'Progressive rendering lost blocks');
  assert((await reader.find('章节 399')).found, 'Last chapter not searchable');
  const articleDiagnostics = reader.diagnostics();

  reader.render({ id: 'cancelled', title: '过期任务', content: longContent });
  reader.render({ id: 'latest', title: '当前任务', content: '只保留当前任务。' });
  await reader.ready();
  assert(document.getElementById('article').textContent.trim() === '只保留当前任务。', 'Stale render appended content');

  const tableDocument = {
    id: 'table-tree', sourceID: 'article-1', title: '方案与证据', theme: 'light',
    content: '# 方案与证据\n\n先核对数据，再比较方案。\n\n| 方案 | 收益 | 来源 |\n|---|---|---|\n| 甲\\|乙 | 12 项 | [证据](knowlake-source://article-1#segment-2) |\n| 丙 | 8 项 | [报告](https://example.test/report) |\n\n- 保留原有行动项\n\n```text\n表格之后的代码 | 不转换\n```',
  };
  reader.render(tableDocument);
  await reader.ready();
  assert(document.querySelectorAll('#article table').length === 1, 'Reading mode no longer shows the Markdown table');
  assert(document.querySelector('#article td')?.textContent === '甲|乙', 'Reading mode changed table cell text');
  reader.dispose();
  assert(document.querySelector('#article').textContent === '', 'Article not disposed');
  return { checks, characters: longContent.length, articleDiagnostics };
}
