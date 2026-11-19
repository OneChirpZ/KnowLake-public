/* App-owned navigation, evaluated only in KnowLake's isolated WebKit content world. */
(() => {
  'use strict';

  const citationClass = 'knowlake-citation';
  let revision = 0;

  function citation(href) {
    try {
      const url = new URL(href);
      const match = /^#segment-([1-9]\d*)$/.exec(url.hash);
      if (url.protocol !== 'knowlake-source:' || !url.hostname || !match
        || url.username || url.password || url.port || url.search || (url.pathname && url.pathname !== '/')) return null;
      return { href: url.href, number: match[1] };
    } catch { return null; }
  }

  function evidenceContainer(heading) {
    const level = Number(heading.tagName.slice(1));
    let candidate = null;
    for (let node = heading.parentElement; node && !node.matches('body,main,article'); node = node.parentElement) {
      const headings = [...node.querySelectorAll('h1,h2,h3,h4,h5,h6')];
      if (headings[0] !== heading || headings.some(item => item !== heading && Number(item.tagName.slice(1)) <= level)) break;
      const beforeHeading = document.createRange();
      beforeHeading.selectNodeContents(node);
      beforeHeading.setEndBefore(heading);
      const leading = beforeHeading.cloneContents();
      if (leading.textContent.trim() || leading.querySelector('img,video,table')) break;
      if (node.matches('section,aside,details,div')) candidate = node;
      if (node.matches('section,aside,details')) break;
    }
    return candidate;
  }

  function removeLegacyEvidence() {
    const headings = [...document.querySelectorAll('h1,h2,h3,h4,h5,h6')]
      .filter(heading => ['回到原文证据', '来源证据'].includes(heading.textContent.replace(/\s+/g, '').trim()));
    for (const heading of headings) {
      const section = evidenceContainer(heading);
      if (!section || !section.isConnected) continue;
      // Preserve an existing precise mapping before removing its old appendix.
      for (const link of [...document.querySelectorAll('a[href^="#"]')]) {
        let target;
        try { target = document.getElementById(decodeURIComponent(link.getAttribute('href').slice(1))); }
        catch { continue; }
        if (!target || !section.contains(target) || section.contains(link)) continue;
        const references = target.matches('a[href]') ? [target] : [...target.querySelectorAll('a[href]')];
        const urls = [...new Set(references.map(item => citation(item.getAttribute('href'))?.href).filter(Boolean))];
        if (target !== section && target !== heading && urls.length === 1) link.href = urls[0];
        else if (target === section || target === heading || link.closest('nav,[role="navigation"]')) link.remove();
        else link.replaceWith(...link.childNodes);
      }
      section.remove();
    }
  }

  function initialize({ sourceID, board = false } = {}) {
    revision += 1;
    if (board && sourceID) {
      for (const link of document.querySelectorAll('a[href]')) {
        const href = link.getAttribute('href');
        const local = /^(?:\.\/)?source\.md(?:#(segment-[1-9]\d*))?$/.exec(href);
        if (local) link.href = `knowlake-source://${encodeURIComponent(sourceID)}${local[1] ? `#${local[1]}` : ''}`;
      }
      removeLegacyEvidence();
    }
    if (!document.getElementById('knowlake-citation-style')) {
      const style = document.createElement('style');
      style.id = 'knowlake-citation-style';
      style.textContent = `a.${citationClass}{display:inline!important;vertical-align:super!important;font:600 .72em/1 system-ui,sans-serif!important;white-space:nowrap!important;text-decoration:none!important;padding:0 .16em!important;margin:0 .1em!important;border:0!important;border-radius:3px!important;color:var(--accent,#6155ae)!important;background:transparent!important;cursor:pointer!important}sup:has(>a.${citationClass}){font-size:inherit!important;vertical-align:baseline!important}a.${citationClass}:hover{background:color-mix(in srgb,currentColor,transparent 90%)!important}a.${citationClass}:focus-visible{outline:2px solid currentColor!important;outline-offset:3px!important}`;
      document.head.append(style);
    }
    for (const link of document.querySelectorAll('a[href]')) {
      const reference = citation(link.getAttribute('href'));
      if (!reference) continue;
      link.classList.add(citationClass);
      link.textContent = `[${reference.number}]`;
      link.title = `查看原文第 ${reference.number} 段`;
      link.setAttribute('aria-label', link.title);
    }
    return true;
  }

  function readingAnchor(elements) {
    const root = document.querySelector('#article') || document.querySelector('main') || document.body;
    const bounds = root.getBoundingClientRect();
    const x = Math.max(1, Math.min(innerWidth - 1, (Math.max(0, bounds.left) + Math.min(innerWidth, bounds.right)) / 2));
    for (const fraction of [0.35, 0.6, 0.85]) {
      for (const hit of document.elementsFromPoint(x, innerHeight * fraction)) {
        if (hit === root || !root.contains(hit)) continue;
        let fixed = false;
        for (let parent = hit; parent && parent !== document.body; parent = parent.parentElement) {
          if (['fixed', 'sticky'].includes(getComputedStyle(parent).position)) { fixed = true; break; }
        }
        if (fixed) continue;
        const element = hit.closest('p,li,pre,blockquote,figure,img,h1,h2,h3,h4,td') || hit;
        if (!root.contains(element)) continue;
        return { id: element.id, index: elements.indexOf(element), tag: element.tagName, top: element.getBoundingClientRect().top };
      }
    }
    return null;
  }

  function capture() {
    const scrolls = [];
    const elements = [...document.querySelectorAll('*')];
    elements.forEach((element, index) => {
      if (element !== document.scrollingElement && (element.scrollTop || element.scrollLeft)) {
        scrolls.push({ index, x: element.scrollLeft, y: element.scrollTop });
      }
    });
    return {
      x: window.scrollX, y: window.scrollY, scrolls, anchor: readingAnchor(elements),
      details: [...document.querySelectorAll('details')].map(element => element.open),
    };
  }

  async function restore(state) {
    if (!state) return false;
    const expected = ++revision;
    const details = [...document.querySelectorAll('details')];
    (state.details || []).forEach((open, index) => { if (details[index]) details[index].open = Boolean(open); });
    // The reader recreates offscreen chunks with estimated heights. Resolve their real
    // layout before restoring the visible passage rather than its old absolute offset.
    document.querySelectorAll('#article .content-block').forEach(block => { block.style.contentVisibility = 'visible'; });
    const images = [...document.images].filter(image => !image.complete);
    // Loading images above the return point must settle before restoring its pixel offset.
    // Bound the wait so a missing/remote image cannot trap navigation.
    const cleanups = [];
    const loaded = images.map(image => new Promise(resolve => {
      const finish = () => { image.removeEventListener('load', finish); image.removeEventListener('error', finish); resolve(); };
      image.addEventListener('load', finish, { once: true });
      image.addEventListener('error', finish, { once: true });
      cleanups.push(finish);
      image.loading = 'eager';
    }));
    let timer;
    await Promise.race([Promise.all(loaded), new Promise(resolve => { timer = setTimeout(resolve, 1200); })]);
    clearTimeout(timer);
    cleanups.forEach(finish => finish());
    if (expected !== revision) return false;
    const elements = [...document.querySelectorAll('*')];
    for (const scroll of state.scrolls || []) {
      const element = elements[scroll.index];
      if (element) element.scrollTo({ left: scroll.x, top: scroll.y, behavior: 'instant' });
    }
    const anchor = state.anchor;
    const target = anchor && ((anchor.id && document.getElementById(anchor.id)) || elements[anchor.index]);
    const top = target && target.tagName === anchor.tag && target.getClientRects().length
      ? window.scrollY + target.getBoundingClientRect().top - anchor.top : state.y;
    window.scrollTo({ left: state.x, top, behavior: 'instant' });
    return true;
  }

  window.KnowLakeNavigation = { initialize, capture, restore };
})();
