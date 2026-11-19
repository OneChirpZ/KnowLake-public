import { createServer } from 'node:http';
import { readFile, mkdtemp, readdir, writeFile, mkdir } from 'node:fs/promises';
import { existsSync } from 'node:fs';
import { resolve, join, extname, dirname } from 'node:path';
import { homedir, tmpdir } from 'node:os';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';

const exec = promisify(execFile);
const root = resolve('../Sources/KnowLake/Resources/Reader');
const temp = await mkdtemp(join(tmpdir(), 'knowlake-reader-test-'));
const session = `knowlake-reader-test-${process.pid}`;
let executablePath = process.env.KNOWLAKE_CHROMIUM;
if (!executablePath && process.platform === 'darwin') {
  const cache = join(homedir(), 'Library/Caches/ms-playwright');
  if (existsSync(cache)) {
    const candidates = (await readdir(cache)).filter(name => /^chromium-\d+$/.test(name)).sort().reverse();
    executablePath = candidates.map(name => join(cache, name, 'chrome-mac-arm64/Google Chrome for Testing.app/Contents/MacOS/Google Chrome for Testing')).find(existsSync);
  }
}
const config = join(temp, 'browser.json');
await writeFile(config, JSON.stringify({ browser: { browserName: 'chromium', isolated: true, launchOptions: { headless: true, ...(executablePath ? { executablePath } : {}) }, contextOptions: { viewport: { width: 1280, height: 900 } } } }));
const server = createServer(async (request, response) => {
  const pathname = decodeURIComponent(new URL(request.url, 'http://localhost').pathname);
  const file = resolve(root, `.${pathname === '/' ? '/index.html' : pathname}`);
  if (!file.startsWith(`${root}/`)) { response.writeHead(403).end(); return; }
  try {
    const data = await readFile(file);
    response.setHeader('Content-Type', { '.html': 'text/html', '.js': 'text/javascript', '.css': 'text/css' }[extname(file)] || 'application/octet-stream');
    response.end(data);
  } catch { response.writeHead(404).end(); }
});
await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
const cli = (...args) => exec('npx', ['--yes', '--package', '@playwright/cli', 'playwright-cli', '--session', session, ...args], { maxBuffer: 1024 * 1024 });
try {
  await cli('open', `http://127.0.0.1:${server.address().port}`, '--config', config);
  const navigation = await cli('eval', await readFile('tests/navigation.js', 'utf8'));
  console.log(navigation.stdout.slice(0, navigation.stdout.indexOf('### Ran Playwright code')));
  if (navigation.stdout.includes('### Error')) throw new Error(navigation.stdout);
  const result = await cli('eval', await readFile('tests/smoke.js', 'utf8'));
  console.log(result.stdout.slice(0, result.stdout.indexOf('### Ran Playwright code')));
  if (result.stdout.includes('### Error')) throw new Error(result.stdout);
  const imageResult = await cli('eval', await readFile('tests/image-viewer.js', 'utf8'));
  console.log(imageResult.stdout.slice(0, imageResult.stdout.indexOf('### Ran Playwright code')));
  if (imageResult.stdout.includes('### Error')) throw new Error(imageResult.stdout);
  const interactions = await cli('run-code', await readFile('tests/image-viewer-interactions.js', 'utf8'));
  console.log(interactions.stdout.slice(0, interactions.stdout.indexOf('### Ran Playwright code')));
  if (interactions.stdout.includes('### Error')) throw new Error(interactions.stdout);
  if (process.env.KNOWLAKE_IMAGE_SCREENSHOT) {
    await cli('eval', `async () => {
      window.KnowLakeReader.render({ ...window.imageViewerFixture, id: 'image-screenshot' });
      await window.KnowLakeReader.ready();
    }`);
    const destination = resolve(process.env.KNOWLAKE_IMAGE_SCREENSHOT);
    await mkdir(dirname(destination), { recursive: true });
    await cli('screenshot', '--filename', destination);
    console.log(`Image screenshot: ${destination}`);
    await cli('eval', '() => { document.querySelector("#image-zoom-in").click(); }');
    const viewerDestination = destination.replace(/\.png$/i, '-viewer.png');
    await cli('screenshot', '--filename', viewerDestination);
    console.log(`Image viewer screenshot: ${viewerDestination}`);
  }
} catch (error) {
  console.error(error.stdout || error.stderr || error.message);
  process.exitCode = 1;
} finally {
  await cli('close').then(() => console.log(`Browser session closed: ${session}`)).catch(error => {
    console.error(`Browser session did not close: ${session}: ${error.message}`);
    process.exitCode = 1;
  });
  server.closeAllConnections();
  await new Promise(resolve => server.close(resolve));
}
