async () => {
  const frame = document.createElement('iframe');
  frame.style.cssText = 'width:900px;height:600px;position:fixed;inset:0';
  document.body.append(frame);
  let checks = 0;
  const assert = (condition, message) => { if (!condition) throw new Error(message); checks += 1; };
  try {
    const win = frame.contentWindow;
    const doc = frame.contentDocument;
    doc.open();
    doc.write(`<!doctype html><html><head><style>html{scroll-behavior:smooth}body{margin:0}.spacer{height:900px}#nested{height:80px;overflow:auto}</style></head><body>
      <main><h1>正文看板</h1><nav><a id="evidence-nav" href="#evidence">来源证据</a><a href="#body">方法</a></nav>
      <section id="body"><h2>方法</h2><p id="claim">正文结论<a id="inline" href="#row">证据</a>，<sup><a id="local" href="./source.md#segment-12">来源</a></sup>。</p>
      <p><a id="external" href="https://example.test/#segment-5">外部资料</a><a id="invalid" href="knowlake-source://source?extra=1#segment-5">非法目标</a></p>
      <div id="nested"><div style="height:500px">嵌套滚动</div></div>
      <details id="expanded"><summary>展开正文</summary><div class="spacer">展开后的内容</div></details><div class="spacer">结论下方</div></section>
      <section id="evidence"><h2>回到原文证据</h2><details id="row"><summary>来源</summary><a href="source.md#segment-5">原文第 5 段</a></details></section>
      <section id="unrelated"><h2>证据方法讨论</h2><p>保留正常的证据内容。</p></section>
      </main></body></html>`);
    doc.close();
    await new Promise((resolve, reject) => {
      const script = doc.createElement('script');
      script.src = '/navigation.js';
      script.onload = resolve;
      script.onerror = reject;
      doc.head.append(script);
    });
    const api = win.KnowLakeNavigation;
    api.initialize({ sourceID: 'source-fixture', board: true });
    assert(!doc.getElementById('evidence'), 'Dedicated legacy evidence appendix remained');
    assert(!doc.getElementById('evidence-nav'), 'Navigation points to removed evidence section');
    assert(doc.getElementById('body') && doc.getElementById('unrelated'), 'Main reading content was removed');
    assert(doc.getElementById('inline').href === 'knowlake-source://source-fixture#segment-5', 'Legacy precise mapping was lost');
    assert(doc.getElementById('inline').textContent === '[5]', 'Inline citation number missing');
    assert(doc.getElementById('local').href === 'knowlake-source://source-fixture#segment-12', 'Local source link not normalized');
    assert(doc.getElementById('local').getAttribute('aria-label') === '查看原文第 12 段', 'Citation accessibility label missing');
    assert(!doc.getElementById('external').classList.contains('knowlake-citation'), 'External URL decorated as citation');
    assert(!doc.getElementById('invalid').classList.contains('knowlake-citation'), 'Malformed native URL decorated as citation');
    api.initialize({ sourceID: 'source-fixture', board: true });
    assert(doc.querySelectorAll('#knowlake-citation-style').length === 1, 'Repeated initialization duplicates styles');
    doc.getElementById('expanded').open = true;
    doc.getElementById('nested').scrollTop = 150;
    win.scrollTo({ top: 700, behavior: 'instant' });
    const state = JSON.parse(JSON.stringify(api.capture()));
    assert(state.y === 700 && state.scrolls.some(value => value.y === 150), 'Scroll snapshot incomplete');
    doc.getElementById('expanded').open = false;
    doc.getElementById('nested').scrollTop = 0;
    win.scrollTo({ top: 0, behavior: 'instant' });
    assert(await api.restore(state), 'Restore failed');
    assert(doc.getElementById('expanded').open, 'Expanded body details not restored');
    assert(win.scrollY === 700, 'Document position not restored');
    assert(doc.getElementById('nested').scrollTop === 150, 'Nested scroll position not restored');
    const pendingImage = doc.createElement('img');
    pendingImage.src = 'data:image/png;base64,invalid';
    doc.body.append(pendingImage);
    const obsoleteRestore = api.restore(state);
    api.initialize({ sourceID: 'source-fixture', board: true });
    assert(await obsoleteRestore === false, 'Old restore changed a newly initialized document');
    Object.defineProperty(pendingImage, 'complete', { configurable: true, get: () => false });
    const earlierReturn = api.restore(state);
    pendingImage.remove();
    const latestPosition = { x: 0, y: 120, scrolls: [], details: state.details };
    assert(await api.restore(latestPosition), 'Latest return did not complete');
    pendingImage.dispatchEvent(new Event('load'));
    assert(await earlierReturn === false, 'Earlier return overrode a newer return');
    assert(win.scrollY === 120, 'Consecutive returns restored an obsolete position');

    doc.body.innerHTML = `<nav id="fixed" style="position:fixed;inset:180px 0 auto;height:100px;z-index:10">浮动工具</nav>
      <article id="article">${Array.from({ length: 6 }, () => '<section class="content-block" style="content-visibility:hidden;contain-intrinsic-size:320px"><div style="height:900px">前文</div></section>').join('')}
      <section class="content-block"><p id="return-passage" style="margin:0;height:100px">返回这里的原文段落</p><div style="height:1400px">下文</div></section></article>`;
    api.initialize({ sourceID: 'source-fixture' });
    const passage = doc.getElementById('return-passage');
    win.scrollTo({ top: win.scrollY + passage.getBoundingClientRect().top - 180, behavior: 'instant' });
    const readingState = JSON.parse(JSON.stringify(api.capture()));
    assert(readingState.anchor?.id === 'return-passage', 'Visible reading passage not captured behind fixed toolbar');
    const oldY = readingState.y;
    const sourceMarkup = doc.getElementById('article').innerHTML;
    doc.getElementById('article').innerHTML = sourceMarkup;
    win.scrollTo({ top: 0, behavior: 'instant' });
    assert(await api.restore(readingState), 'Reader passage restore failed');
    assert([...doc.querySelectorAll('.content-block')].every(block => block.style.contentVisibility === 'visible'), 'Reader chunks still use estimated heights');
    assert(Math.abs(doc.getElementById('return-passage').getBoundingClientRect().top - 180) < 2, 'Reader returned to a different passage after chunk layout changed');
    assert(win.scrollY > oldY + 1000, 'Fixture did not exercise changed preceding chunk heights');
    return { checks, navigation: 'passed' };
  } finally { frame.remove(); }
}
