import { build } from 'esbuild';
import { mkdir, writeFile, copyFile, readFile } from 'node:fs/promises';
import { resolve } from 'node:path';

const out = resolve('../Sources/KnowLake/Resources/Reader');
await mkdir(out, { recursive: true });
await build({
  entryPoints: ['src/reader.ts'], outfile: `${out}/reader.js`, bundle: true,
  minify: true, target: 'safari16', format: 'iife', legalComments: 'eof',
  loader: { '.css': 'text' },
});
await copyFile('src/reader.css', `${out}/reader.css`);
await copyFile('src/index.html', `${out}/index.html`);
const names = ['marked', 'dompurify'];
const licenses = [];
for (const name of names) {
  const pkg = JSON.parse(await readFile(`node_modules/${name}/package.json`, 'utf8'));
  let license = '';
  for (const file of ['LICENSE', 'LICENSE.md', 'LICENSE.txt']) {
    try { license = await readFile(`node_modules/${name}/${file}`, 'utf8'); break; }
    catch { /* package license filename differs */ }
  }
  licenses.push(`${name} ${pkg.version}\n${license || `License: ${pkg.license}`}\n`);
}
await writeFile(`${out}/LICENSES.txt`, licenses.join('\n---\n\n').trimEnd() + '\n');
console.log(`Reader built: ${out}`);
