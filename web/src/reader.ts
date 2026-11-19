import { marked, type Token } from 'marked';
import DOMPurify from 'dompurify';
import { createImageViewer } from './image-viewer';
import readerCSS from './reader.css';

interface Segment { start: number; end?: number; text: string }
interface DocumentInput {
  id: string;
  sourceID?: string;
  title: string;
  url?: string;
  platform?: string;
  content: string;
  segments?: Segment[];
  theme?: 'light' | 'dark';
  assetBase?: string;
  imageURL?: string;
  imageTitle?: string;
}
interface HostMessage { type: string; [key: string]: unknown }
declare global {
  interface Window {
    webkit?: { messageHandlers?: { knowlake?: { postMessage: (message: HostMessage) => void } } };
    KnowLakeReader: typeof api;
  }
}

const article = document.querySelector<HTMLElement>('#article')!;
const outline = document.querySelector<HTMLElement>('#outline')!;
const status = document.querySelector<HTMLElement>('#reader-status')!;
const header = document.querySelector<HTMLElement>('#doc-header')!;
const title = document.querySelector<HTMLElement>('#doc-title')!;
const sourceLink = document.querySelector<HTMLAnchorElement>('#source-link')!;
const sourceLabel = document.querySelector<HTMLElement>('#source-label')!;
const imagePanel = document.querySelector<HTMLElement>('#image-panel')!;
const imageViewer = createImageViewer();

let current: DocumentInput | undefined;
let revision = 0;
let anchorRevision = 0;
let renderReady = Promise.resolve();
let headingCount = 0;
let activeMark: HTMLElement | undefined;
let flashTimer: ReturnType<typeof setTimeout> | undefined;
let observer: IntersectionObserver | undefined;
let renderDuration = 0;
let chunksRendered = 0;

const allowedURI = /^(?:(?:https?|file|mailto|knowlake-source|knowlake-asset):|#|\.{0,2}\/|data:image\/(?:png|jpe?g|gif|webp|avif);base64,|[^:]+$)/i;
const purifierOptions = {
  ALLOWED_URI_REGEXP: allowedURI,
  FORBID_TAGS: ['script', 'style', 'iframe', 'object', 'embed', 'form', 'button'],
  FORBID_ATTR: ['style', 'srcset'],
  ADD_ATTR: ['id'],
};

function post(message: HostMessage) {
  window.webkit?.messageHandlers?.knowlake?.postMessage(message);
}

function nextPaint(): Promise<void> {
  // Timers still complete in a background WKWebView; requestAnimationFrame can stall there.
  return new Promise(resolve => setTimeout(resolve, 0));
}

function assetURL(path: string): string {
  if (!current?.assetBase || /^(?:[a-z][a-z0-9+.-]*:|#)/i.test(path)) return path;
  const base = current.assetBase.startsWith('/')
    ? `file://${encodeURI(current.assetBase)}` : current.assetBase;
  return new URL(path, base.endsWith('/') ? base : `${base}/`).href;
}

function cleanHTML(html: string): string {
  return DOMPurify.sanitize(html, purifierOptions);
}

function clock(seconds: number): string {
  const n = Math.max(0, Math.floor(seconds));
  return n >= 3600
    ? `${Math.floor(n / 3600)}:${String(Math.floor(n / 60) % 60).padStart(2, '0')}:${String(n % 60).padStart(2, '0')}`
    : `${Math.floor(n / 60)}:${String(n % 60).padStart(2, '0')}`;
}

function timedSegment(segment: Segment | undefined): segment is Segment {
  return current?.platform === 'bilibili' && Boolean(current.url)
    && segment !== undefined && Number.isFinite(segment.start) && segment.start >= 0
    && (segment.end === undefined || Number.isFinite(segment.end) && segment.end > segment.start);
}

function timedURL(seconds: number): string {
  const url = new URL(current?.url || 'https://www.bilibili.com');
  url.searchParams.set('t', String(Math.max(0, Math.floor(seconds))));
  return url.href;
}

function decorate(container: HTMLElement) {
  container.querySelectorAll('h1,h2,h3,h4').forEach(heading => {
    if (!heading.id) heading.id = `heading-${++headingCount}`;
    if (heading.matches('h2,h3')) {
      const item = document.createElement('a');
      item.href = `#${heading.id}`;
      item.className = heading.matches('h3') ? 'depth-3' : '';
      item.textContent = heading.textContent;
      outline.append(item);
    }
  });
  container.querySelectorAll('img').forEach(image => {
    image.loading = 'lazy';
    image.decoding = 'async';
    image.src = assetURL(image.getAttribute('src') || '');
  });
  container.querySelectorAll<HTMLAnchorElement>('a[href]').forEach(anchor => {
    const localSource = /^(?:\.\/)?source\.md(?:#(.*))?$/i.exec(anchor.getAttribute('href') || '');
    if (localSource && current?.sourceID) {
      anchor.href = `knowlake-source://${encodeURIComponent(current.sourceID)}${localSource[1] ? `#${localSource[1]}` : ''}`;
    }
  });
  container.querySelectorAll('table').forEach(table => {
    const scroll = document.createElement('div');
    scroll.className = 'table-scroll';
    table.replaceWith(scroll);
    scroll.append(table);
  });
  container.querySelectorAll<HTMLAnchorElement>('a[id^="segment-"]').forEach(anchor => {
    const index = Number(anchor.id.slice('segment-'.length)) - 1;
    const segment = current?.segments?.[index];
    if (!timedSegment(segment)) {
      // Archive paragraphs carry invisible anchors, not separate reading rows.
      const parent = anchor.parentElement;
      if (parent?.tagName === 'P' && parent.children.length === 1 && !parent.textContent?.trim()) parent.replaceWith(anchor);
      anchor.className = 'source-anchor';
      return;
    }
    anchor.href = timedURL(segment.start);
    anchor.className = 'time-link';
    anchor.textContent = clock(segment.start);
    anchor.title = '跳转到视频片段';
  });
}

function chunkTokens(tokens: Token[]): Token[][] {
  const chunks: Token[][] = [];
  let group: Token[] = [];
  let characters = 0;
  for (const token of tokens) {
    if (group.length && (characters > 2600 || token.type === 'heading' && characters > 1000)) {
      chunks.push(group);
      group = [];
      characters = 0;
    }
    group.push(token);
    characters += token.raw.length;
  }
  if (group.length) chunks.push(group);
  return chunks;
}

function markdownText(input: DocumentInput): string {
  if (input.content?.trim()) return input.content;
  return (input.segments || []).map((s, i) => `<a id="segment-${i + 1}"></a>\n\n${s.text}`).join('\n\n');
}

async function renderArticle(input: DocumentInput, generation: number) {
  const start = performance.now();
  // Yield before tokenization so the native selection/header can be displayed immediately.
  await nextPaint();
  if (generation !== revision) return;
  const tokens = marked.lexer(markdownText(input), { gfm: true });
  if (tokens[0]?.type === 'heading' && tokens[0].depth === 1 && tokens[0].text === input.title) tokens.shift();
  const chunks = chunkTokens(tokens);
  let sliceStart = performance.now();
  for (const chunk of chunks) {
    if (generation !== revision) return;
    const block = document.createElement('section');
    block.className = 'content-block';
    block.innerHTML = cleanHTML(marked.parser(chunk));
    decorate(block);
    article.append(block);
    chunksRendered += 1;
    if (performance.now() - sliceStart > 8) {
      await nextPaint();
      sliceStart = performance.now();
    }
  }
  if (generation !== revision) return;
  outline.hidden = outline.children.length < 3;
  observeHeadings();
  renderDuration = performance.now() - start;
  post({ type: 'rendered', id: input.id, duration: renderDuration, blocks: chunksRendered });
}

function observeHeadings() {
  observer?.disconnect();
  observer = new IntersectionObserver(entries => {
    const visible = entries.find(entry => entry.isIntersecting);
    if (!visible) return;
    outline.querySelector('.active')?.classList.remove('active');
    outline.querySelector(`a[href="#${CSS.escape(visible.target.id)}"]`)?.classList.add('active');
  }, { rootMargin: '-8% 0px -75% 0px' });
  article.querySelectorAll('h2,h3').forEach(h => observer!.observe(h));
}

function clearCurrentView() {
  anchorRevision += 1;
  imageViewer.reset();
  imagePanel.hidden = true;
  observer?.disconnect();
  observer = undefined;
  if (flashTimer) clearTimeout(flashTimer);
  activeMark = undefined;
  article.replaceChildren();
  outline.replaceChildren();
  headingCount = 0;
  chunksRendered = 0;
  outline.hidden = true;
  status.textContent = '';
}

function render(input: DocumentInput) {
  document.documentElement.dataset.theme = input.theme || 'light';
  const unchanged = current?.id === input.id && current.content === input.content
    && current.assetBase === input.assetBase
    && current.platform === input.platform && current.url === input.url
    && current.imageURL === input.imageURL && current.imageTitle === input.imageTitle;
  current = input;
  title.textContent = input.title;
  document.title = input.title || 'KnowLake';
  header.hidden = Boolean(input.imageURL) || !input.title;
  sourceLabel.textContent = input.platform === 'bilibili' ? 'Bilibili'
    : input.platform === 'wechat' ? '微信公众号' : input.platform || '来源';
  sourceLink.hidden = !input.url;
  sourceLink.href = /^https?:/i.test(input.url || '') ? input.url! : '#';
  if (unchanged) return { changed: false };
  revision += 1;
  clearCurrentView();
  const isImage = Boolean(input.imageURL);
  document.body.classList.toggle('image-mode', isImage);
  article.hidden = isImage;
  imagePanel.hidden = !isImage;
  window.scrollTo({ top: 0, behavior: 'instant' });
  const generation = revision;
  renderReady = (isImage
    ? imageViewer.load(assetURL(input.imageURL!), input.imageTitle || input.title).then(() => {
      if (generation === revision) post({ type: 'rendered', id: input.id, mode: 'image' });
    })
    : renderArticle(input, revision)).catch(error => {
    if (generation !== revision) return;
    status.textContent = `无法显示内容：${String(error.message || error)}`;
    post({ type: 'readerError', message: String(error.message || error) });
  });
  return { changed: true };
}

function anchorContent(target: HTMLElement): HTMLElement {
  if (!target.matches('a[id^="segment-"]')) return target;
  const parent = target.parentElement;
  // A timestamp can share a paragraph with its transcript text.
  if (parent?.tagName === 'P' && parent.textContent?.trim() !== target.textContent?.trim()) return parent;
  let next: Element | null = target;
  while (next && next !== article) {
    if (!next.nextElementSibling) { next = next.parentElement; continue; }
    next = next.nextElementSibling;
    // Markdown chunks may split an anchor from its paragraph or image.
    while (next?.matches('.content-block')) next = next.firstElementChild;
    if (!next) break;
    if (next.matches('a.source-anchor')) continue;
    return next as HTMLElement;
  }
  return target;
}

async function settleAnchorLayout(target: HTMLElement) {
  const precedes = (element: Element) => Boolean(element.compareDocumentPosition(target) & Node.DOCUMENT_POSITION_FOLLOWING);
  // Reveal skipped chunks before measuring; otherwise their estimated heights shift the destination.
  article.querySelectorAll<HTMLElement>('.content-block').forEach(block => {
    if (block.contains(target) || precedes(block)) block.style.contentVisibility = 'visible';
  });
  const images = [...article.querySelectorAll<HTMLImageElement>('img')]
    .filter(image => target.contains(image) || precedes(image));
  await Promise.all(images.map(image => new Promise<void>(resolve => {
    if (image.complete) { resolve(); return; }
    const done = () => {
      clearTimeout(timer);
      image.removeEventListener('load', done);
      image.removeEventListener('error', done);
      resolve();
    };
    const timer = setTimeout(done, 2000);
    image.addEventListener('load', done, { once: true });
    image.addEventListener('error', done, { once: true });
    image.loading = 'eager';
  })));
}

function cancelAnchor() {
  anchorRevision += 1;
  if (flashTimer) clearTimeout(flashTimer);
  document.querySelector('.anchor-flash')?.classList.remove('anchor-flash');
}

async function scrollToAnchor(anchor: string) {
  const generation = revision;
  const request = ++anchorRevision;
  await renderReady;
  if (generation !== revision || request !== anchorRevision) return false;
  let id: string;
  try { id = decodeURIComponent(anchor.replace(/^#/, '')); } catch { return false; }
  const target = document.getElementById(id);
  if (!target || !article.contains(target)) return false;
  const highlight = anchorContent(target);
  await settleAnchorLayout(highlight);
  if (generation !== revision || request !== anchorRevision) return false;
  if (flashTimer) clearTimeout(flashTimer);
  document.querySelector('.anchor-flash')?.classList.remove('anchor-flash');
  highlight.scrollIntoView({ block: 'center', behavior: 'instant' });
  // Restart the pulse when the same citation is followed again.
  void highlight.offsetWidth;
  highlight.classList.add('anchor-flash');
  flashTimer = setTimeout(() => highlight.classList.remove('anchor-flash'), 1600);
  return true;
}

async function find(query: string) {
  await renderReady;
  if (activeMark) {
    activeMark.replaceWith(document.createTextNode(activeMark.textContent || ''));
    article.normalize();
    activeMark = undefined;
  }
  if (!query.trim()) return { found: false, count: 0 };
  const walker = document.createTreeWalker(article, NodeFilter.SHOW_TEXT);
  let node: Text | null;
  let first: { node: Text; offset: number } | undefined;
  let count = 0;
  const needle = query.toLocaleLowerCase();
  while ((node = walker.nextNode() as Text | null)) {
    const text = node.data.toLocaleLowerCase();
    let offset = text.indexOf(needle);
    while (offset !== -1) {
      first ??= { node, offset };
      count += 1;
      offset = text.indexOf(needle, offset + needle.length);
    }
  }
  if (first) {
    const range = document.createRange();
    range.setStart(first.node, first.offset);
    range.setEnd(first.node, first.offset + query.length);
    activeMark = document.createElement('mark');
    activeMark.className = 'find-match';
    range.surroundContents(activeMark);
    activeMark.scrollIntoView({ block: 'center', behavior: 'smooth' });
  }
  return { found: Boolean(first), count };
}

function escapeText(text: string) {
  const div = document.createElement('div');
  div.textContent = text;
  return div.innerHTML;
}

async function embedImage(image: HTMLImageElement, assetData: Record<string, string>): Promise<void> {
  if (image.src.startsWith('data:')) return;
  if (assetData[image.src]) { image.src = assetData[image.src]; return; }
  const response = await fetch(image.src);
  if (!response.ok) throw new Error(`图片无法导出：${image.src}`);
  const blob = await response.blob();
  image.src = await new Promise<string>((resolve, reject) => {
    const reader = new FileReader();
    reader.onload = () => resolve(String(reader.result));
    reader.onerror = () => reject(reader.error);
    reader.readAsDataURL(blob);
  });
}

async function exportHTML(assetData: Record<string, string> = {}): Promise<string> {
  await renderReady;
  const body = document.createElement('div');
  if (current?.imageURL) {
    const image = imageViewer.image.cloneNode() as HTMLImageElement;
    await embedImage(image, assetData);
    const name = escapeText(current.imageTitle || current.title || '概览图');
    return `<!doctype html><html lang="zh-CN" data-theme="${current.theme || 'light'}"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>${name}</title><style>${readerCSS}</style></head><body class="image-mode"><main id="app"><section id="image-panel">${image.outerHTML}</section></main></body></html>`;
  } else {
    body.innerHTML = article.innerHTML;
    body.querySelectorAll('mark.find-match').forEach(mark => mark.replaceWith(document.createTextNode(mark.textContent || '')));
    await Promise.all(Array.from(body.querySelectorAll('img')).map(image => embedImage(image, assetData)));
    body.querySelectorAll<HTMLAnchorElement>('a[href^="knowlake-source:"]').forEach(anchor => {
      const target = new URL(anchor.href);
      if (!current?.url || target.hostname !== current.sourceID) return;
      const segment = current.segments?.[Number(target.hash.replace('#segment-', '')) - 1];
      if (timedSegment(segment)) anchor.href = timedURL(segment.start);
      else anchor.setAttribute('href', target.hash && body.querySelector(`#${CSS.escape(target.hash.slice(1))}`) ? target.hash : current.url);
    });
  }
  body.querySelectorAll<HTMLAnchorElement>('a[href^="#segment-"]').forEach(anchor => {
    const hash = anchor.getAttribute('href')!;
    if (!current?.url || body.querySelector(`#${CSS.escape(hash.slice(1))}`)) return;
    const segment = current.segments?.[Number(hash.slice('#segment-'.length)) - 1];
    anchor.href = timedSegment(segment) ? timedURL(segment.start) : current.url;
  });
  const name = escapeText(current?.title || 'KnowLake');
  const source = /^https?:/i.test(current?.url || '') ? `<p><a href="${escapeText(current!.url!).replace(/"/g, '&quot;')}">查看来源</a></p>` : '';
  return `<!doctype html><html lang="zh-CN" data-theme="${current?.theme || 'light'}"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>${name}</title><style>${readerCSS}\n.content-block{content-visibility:visible!important}#app{margin-left:auto!important;margin-right:auto!important}</style></head><body><main id="app"><header id="doc-header">${source}<h1 id="doc-title">${name}</h1></header><article id="article">${body.innerHTML}</article></main></body></html>`;
}

function dispose() {
  revision += 1;
  clearCurrentView();
  current = undefined;
  document.body.classList.remove('image-mode');
}

document.addEventListener('click', event => {
  const anchor = (event.target as Element).closest<HTMLAnchorElement>('a[href]');
  if (!anchor) return;
  const href = anchor.getAttribute('href') || '';
  if (href.startsWith('#')) {
    event.preventDefault();
    void renderReady.then(() => {
      if (/^#segment-\d+$/.test(href) && !document.getElementById(href.slice(1)) && current?.sourceID) {
        post({ type: 'openSource', sourceID: current.sourceID, anchor: href.slice(1) });
      } else void scrollToAnchor(href);
    });
  } else if (href.startsWith('knowlake-source:')) {
    event.preventDefault();
    const url = new URL(href);
    post({ type: 'openSource', sourceID: decodeURIComponent(url.hostname), anchor: url.hash.slice(1) });
  } else if (/^https?:|^mailto:/i.test(href)) {
    event.preventDefault();
    post({ type: 'openURL', url: href });
    if (!window.webkit) window.open(href, '_blank', 'noopener,noreferrer');
  }
});
window.addEventListener('pagehide', dispose);

const api = {
  render, find, scrollToAnchor, cancelAnchor, exportHTML, dispose,
  ready: () => renderReady,
  assetURLs: () => (current?.imageURL ? [imageViewer.image.src] : Array.from(article.querySelectorAll('img')).map(image => image.src)).filter(url => !url.startsWith('data:')),
  plainText: () => current?.imageURL ? current.imageTitle || current.title : current ? markdownText(current) : '',
  diagnostics: () => ({ id: current?.id, mode: current?.imageURL ? 'image' : 'article', blocks: chunksRendered, duration: renderDuration }),
};
window.KnowLakeReader = api;
post({ type: 'ready' });
