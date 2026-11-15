const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const docs = path.resolve(__dirname, '..');

test('published pages keep local links, assets and anchors valid', () => {
  for (const name of ['index.html', 'develop.html', '404.html']) {
    const html = fs.readFileSync(path.join(docs, name), 'utf8');
    for (const [, raw] of html.matchAll(/(?:href|src)="([^"]+)"/g)) {
      if (/^https?:/.test(raw)) continue;
      const [file, anchor] = raw.replace(/^\/OpenNotes\//, '').split('#');
      const target = path.join(docs, file === './' ? 'index.html' : file || name);
      assert.ok(fs.existsSync(target), `${name}: missing ${raw}`);
      if (anchor) assert.ok(fs.readFileSync(target, 'utf8').includes(`id="${anchor}"`), `${name}: missing anchor ${raw}`);
    }
    for (const [image] of html.matchAll(/<img\b[^>]*>/g)) assert.match(image, /\balt="[^"]*"/, `${name}: image needs alt text`);
  }
});

test('download links and README describe the packaged version', () => {
  const manifest = JSON.parse(fs.readFileSync(path.join(docs, 'release-build36.json'), 'utf8'));
  assert.equal(manifest.build, '36');
  assert.match(manifest.sha256, /^[a-f0-9]{64}$/);
  for (const name of ['index.html', 'develop.html']) {
    const html = fs.readFileSync(path.join(docs, name), 'utf8');
    assert.ok(html.includes(`${manifest.tag}/${manifest.artifact}`), `${name}: stale download`);
    assert.ok(!html.includes('Powered by PencilKit') && !/\.catnote\b/.test(html), `${name}: stale product copy`);
  }
  const readme = fs.readFileSync(path.join(docs, '../README.md'), 'utf8');
  assert.ok(readme.includes(manifest.tag));
  for (const [, file] of readme.matchAll(/!?\[[^\]]*\]\(([^)]+)\)/g)) {
    if (!/^https?:/.test(file)) assert.ok(fs.existsSync(path.resolve(docs, '..', file.split('#')[0])), `README: missing ${file}`);
  }
});
