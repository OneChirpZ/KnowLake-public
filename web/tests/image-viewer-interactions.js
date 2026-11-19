async page => {
  const assert = (value, message) => { if (!value) throw new Error(message); };
  assert(await page.locator('#image-viewer').isVisible(), 'Viewer controls should be available on entry');
  for (let index = 0; index < 4; index += 1) await page.locator('#image-zoom-in').click();
  const viewport = await page.locator('#image-viewport').boundingBox();
  const center = { x: viewport.x + viewport.width / 2, y: viewport.y + viewport.height / 2 };
  await page.mouse.move(center.x, center.y);
  await page.mouse.down();
  await page.mouse.move(center.x + 90, center.y + 60, { steps: 8 });
  await page.mouse.up();
  const dragged = await page.locator('#image-viewer').evaluate(element => ({
    x: Number(element.dataset.x), y: Number(element.dataset.y), scale: Number(element.dataset.scale),
  }));
  assert(dragged.x > 80 && dragged.y > 50, 'Physical pointer drag did not pan the image');
  assert(!(await page.locator('#image-viewport').evaluate(element => element.classList.contains('dragging'))), 'Pointer release leaves drag active');
  await page.mouse.wheel(0, -180);
  await page.waitForFunction(previous => Number(document.querySelector('#image-viewer').dataset.scale) > previous, dragged.scale);
  await page.locator('#image-fit').click();
  const fitted = await page.locator('#image-viewer').evaluate(element => ({ x: Number(element.dataset.x), y: Number(element.dataset.y) }));
  assert(fitted.x === 0 && fitted.y === 0, 'Fit did not reset a dragged image');
  await page.keyboard.press('Escape');
  assert(await page.locator('#image-viewer').isHidden(), 'Real Escape did not close viewer');
  assert(await page.locator('#image-open').evaluate(element => element === document.activeElement), 'Real close did not restore opener focus');
  await page.locator('#image-open').click();
  await page.locator('#image-close').click();
  assert(await page.locator('#image-viewer').isHidden(), 'Close button did not close viewer');
  return { pointerDrag: dragged, fit: fitted, keyboardAndClose: 'passed' };
}
