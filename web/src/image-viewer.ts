export function createImageViewer() {
  const app = document.querySelector<HTMLElement>('#app')!;
  const opener = document.querySelector<HTMLButtonElement>('#image-open')!;
  const image = document.querySelector<HTMLImageElement>('#overview-image')!;
  const viewer = document.querySelector<HTMLElement>('#image-viewer')!;
  const viewport = document.querySelector<HTMLElement>('#image-viewport')!;
  const enlarged = document.querySelector<HTMLImageElement>('#viewer-image')!;
  const closeButton = document.querySelector<HTMLButtonElement>('#image-close')!;
  const zoomValue = document.querySelector<HTMLOutputElement>('#image-zoom-value')!;
  let loading: AbortController | undefined;
  let session: AbortController | undefined;
  let resize: ResizeObserver | undefined;
  let previousFocus: HTMLElement | undefined;
  let scale = 1;
  let fitScale = 1;
  let x = 0;
  let y = 0;
  let drag: { id: number; x: number; y: number } | undefined;

  function paint() {
    const maxX = Math.max(0, (image.naturalWidth * scale - viewport.clientWidth) / 2);
    const maxY = Math.max(0, (image.naturalHeight * scale - viewport.clientHeight) / 2);
    x = Math.max(-maxX, Math.min(maxX, x));
    y = Math.max(-maxY, Math.min(maxY, y));
    enlarged.style.transform = `translate(calc(-50% + ${x}px), calc(-50% + ${y}px)) scale(${scale})`;
    zoomValue.value = `${Math.round(scale * 100)}%`;
    viewer.dataset.scale = String(scale);
    viewer.dataset.x = String(x);
    viewer.dataset.y = String(y);
  }

  function fit() {
    fitScale = Math.min(
      (viewport.clientWidth - 32) / image.naturalWidth,
      (viewport.clientHeight - 32) / image.naturalHeight,
    );
    scale = fitScale;
    x = y = 0;
    paint();
  }

  function zoom(next: number, clientX?: number, clientY?: number) {
    next = Math.max(fitScale / 4, Math.min(Math.max(8, fitScale * 4), next));
    const bounds = viewport.getBoundingClientRect();
    const px = (clientX ?? bounds.left + bounds.width / 2) - bounds.left - bounds.width / 2;
    const py = (clientY ?? bounds.top + bounds.height / 2) - bounds.top - bounds.height / 2;
    const ratio = next / scale;
    x = px - (px - x) * ratio;
    y = py - (py - y) * ratio;
    scale = next;
    paint();
  }

  function endDrag() {
    if (drag && viewport.hasPointerCapture(drag.id)) viewport.releasePointerCapture(drag.id);
    drag = undefined;
    viewport.classList.remove('dragging');
  }

  function close(restoreFocus = true) {
    session?.abort();
    session = undefined;
    resize?.disconnect();
    resize = undefined;
    endDrag();
    viewer.hidden = true;
    app.inert = false;
    document.documentElement.classList.remove('image-viewer-open');
    if (restoreFocus && previousFocus?.isConnected) previousFocus.focus({ preventScroll: true });
    else if (viewer.contains(document.activeElement)) (document.activeElement as HTMLElement).blur();
    previousFocus = undefined;
  }

  function open() {
    if (opener.disabled || session) return;
    previousFocus = document.activeElement instanceof HTMLElement && document.activeElement !== document.body
      ? document.activeElement : opener;
    viewer.hidden = false;
    app.inert = true;
    document.documentElement.classList.add('image-viewer-open');
    enlarged.src = image.src;
    enlarged.alt = image.alt;
    enlarged.style.width = `${image.naturalWidth}px`;
    enlarged.style.height = `${image.naturalHeight}px`;
    fit();
    closeButton.focus({ preventScroll: true });
    session = new AbortController();
    const options = { signal: session.signal };
    viewport.addEventListener('wheel', event => {
      event.preventDefault();
      const delta = event.deltaY * (event.deltaMode === 1 ? 16 : event.deltaMode === 2 ? viewport.clientHeight : 1);
      zoom(scale * Math.exp(-delta * .002), event.clientX, event.clientY);
    }, { ...options, passive: false });
    viewport.addEventListener('pointerdown', event => {
      if (event.button !== 0 || !event.isPrimary) return;
      drag = { id: event.pointerId, x: event.clientX, y: event.clientY };
      viewport.setPointerCapture(event.pointerId);
      viewport.classList.add('dragging');
      event.preventDefault();
    }, options);
    viewport.addEventListener('pointermove', event => {
      if (!drag || event.pointerId !== drag.id) return;
      x += event.clientX - drag.x;
      y += event.clientY - drag.y;
      drag.x = event.clientX;
      drag.y = event.clientY;
      paint();
    }, options);
    viewport.addEventListener('pointerup', endDrag, options);
    viewport.addEventListener('pointercancel', endDrag, options);
    viewport.addEventListener('lostpointercapture', endDrag, options);
    viewport.addEventListener('dblclick', event => {
      if (scale > fitScale * 1.02) fit();
      else zoom(Math.max(1, fitScale * 2), event.clientX, event.clientY);
    }, options);
    let gestureScale = scale;
    viewport.addEventListener('gesturestart', event => {
      event.preventDefault();
      gestureScale = scale;
    }, { ...options, passive: false });
    viewport.addEventListener('gesturechange', event => {
      event.preventDefault();
      const gesture = event as Event & { scale: number; clientX: number; clientY: number };
      zoom(gestureScale * gesture.scale, gesture.clientX, gesture.clientY);
    }, { ...options, passive: false });
    viewport.addEventListener('gestureend', event => event.preventDefault(), { ...options, passive: false });
    document.addEventListener('keydown', event => {
      if (event.key === 'Escape') { event.preventDefault(); close(); }
      else if (event.key === '+' || event.key === '=') { event.preventDefault(); zoom(scale * 1.25); }
      else if (event.key === '-') { event.preventDefault(); zoom(scale / 1.25); }
      else if (event.key === '0') { event.preventDefault(); fit(); }
      else if (event.key.startsWith('Arrow')) {
        event.preventDefault();
        if (event.key === 'ArrowLeft') x += 60;
        if (event.key === 'ArrowRight') x -= 60;
        if (event.key === 'ArrowUp') y += 60;
        if (event.key === 'ArrowDown') y -= 60;
        paint();
      } else if (event.key === 'Tab') {
        const buttons = Array.from(viewer.querySelectorAll<HTMLButtonElement>('button'));
        const index = buttons.indexOf(document.activeElement as HTMLButtonElement);
        event.preventDefault();
        buttons[(index + (event.shiftKey ? -1 : 1) + buttons.length) % buttons.length].focus();
      }
    }, options);
    resize = new ResizeObserver(() => {
      const wasFitted = Math.abs(scale - fitScale) < .0001;
      fitScale = Math.min((viewport.clientWidth - 32) / image.naturalWidth, (viewport.clientHeight - 32) / image.naturalHeight);
      if (wasFitted) fit();
      else paint();
    });
    resize.observe(viewport);
  }

  opener.addEventListener('click', open);
  closeButton.addEventListener('click', () => close());
  document.querySelector('#image-zoom-in')!.addEventListener('click', () => zoom(scale * 1.25));
  document.querySelector('#image-zoom-out')!.addEventListener('click', () => zoom(scale / 1.25));
  document.querySelector('#image-fit')!.addEventListener('click', fit);

  function reset() {
    loading?.abort();
    loading = undefined;
    close(false);
    opener.disabled = true;
    image.removeAttribute('src');
    enlarged.removeAttribute('src');
    enlarged.removeAttribute('style');
    delete viewer.dataset.scale;
    delete viewer.dataset.x;
    delete viewer.dataset.y;
  }

  function load(url: string, title: string): Promise<void> {
    reset();
    image.alt = title || '概览图';
    opener.setAttribute('aria-label', `打开图片浏览器：${image.alt}`);
    loading = new AbortController();
    const signal = loading.signal;
    return new Promise((resolve, reject) => {
      signal.addEventListener('abort', () => resolve(), { once: true });
      image.addEventListener('load', () => {
        opener.disabled = false;
        open();
        resolve();
      }, { once: true, signal });
      image.addEventListener('error', () => reject(new Error('图片加载失败')), { once: true, signal });
      image.src = url;
    });
  }

  return { load, reset, image };
}
