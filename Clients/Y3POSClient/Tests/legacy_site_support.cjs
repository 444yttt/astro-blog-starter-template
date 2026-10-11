// Sanitized, routed fixtures only. No requests reach the real site.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { chromium } = require(process.env.PLAYWRIGHT_MODULE || 'playwright');

const source = fs.readFileSync(path.join(__dirname, '../Y3Client/LegacySiteSupport.swift'), 'utf8');
const scripts = Object.fromEntries(['viewportAndTouch', 'discoverFrames', 'frameFocus', 'siteHome'].map(name => {
  const match = source.match(new RegExp(`static let ${name} = #"""([\\s\\S]*?)"""#`));
  assert(match, `Missing ${name}`);
  return [name, match[1]];
}));
const primary = 'https://adidas-y3.poscmcloud.jp:15505';
const secondary = 'https://adidas-y3.poscmcloud.jp:7705';
const report = '<html><head><title>Fixture</title></head><body><table width="900">' +
  Array.from({ length: 6 }, (_, i) => `<tr><td>Row ${i}</td><td>Test</td><td>Only</td><td>Mock</td></tr>`).join('') + '</table></body></html>';
const fixtures = new Map([
  [primary + '/fixture/daily', '<html><head></head><frameset rows="115,*"><frame name="prtz030_1_1" src="/fixture/condition"><frame name="prtz030_2" src="/fixture/results"></frameset></html>'],
  [primary + '/fixture/condition', '<html><head></head><body><a href="/scripts/verona/menu/metz010_1.asp" target="_top" onclick="top.fixtureHomeClicks=(top.fixtureHomeClicks||0)+1;return false">Menu</a><table><form method="post" action="/fixture/submit" target="prtz030_2"><tbody><tr><td nowrap width="1%">Date</td><td nowrap><input type="text" name="ft_YYYYMMDD_F" value="20261011">〜<input type="text" name="ft_YYYYMMDD_T" value="20261011"></td><td nowrap><input type="submit" value="Search condition"><input type="reset" value="Clear condition"></td></tr></tbody></form></table></body></html>'],
  [primary + '/fixture/results', '<html><head></head><frameset rows="60%,*"><frame name="prtz030_2_2" src="/fixture/a"><frameset cols="*,40%"><frame name="prtz030_2_3" src="/fixture/b"><frame name="prtz030_2_4" src="/fixture/c"></frameset></frameset></html>'],
  [primary + '/fixture/a', report], [primary + '/fixture/b', report], [primary + '/fixture/c', report],
  [primary + '/fixture/submit', report],
  [primary + '/scripts/verona/dwh/prtz011_1.asp', '<html><head></head><body><form><input name="query" type="text"></form><span id="layer0" style="display:none;position:absolute;left:91px;top:91px;width:400px;height:200px"><iframe name="fraHinbanSearch" src="/fixture/helper" width="400" height="200"></iframe></span></body></html>'],
  [primary + '/fixture/helper', '<html><head></head><body>Helper only</body></html>'],
  [primary + '/scripts/verona/dwh/dstz210_2.asp', `<html><head></head><frameset rows="90,*"><frame name="dstz210_2_1" src="/fixture/header"><frame name="dstz210_2_2" src="${secondary}/dataspider/trigger/hanbai.asp"></frameset></html>`],
  [primary + '/fixture/header', '<html><head></head><body><a href="/scripts/verona/menu/metz010_1.asp" target="_top">Menu</a></body></html>'],
  [secondary + '/dataspider/trigger/hanbai.asp', `<html><head></head><body><a target="_blank" href="${primary}/scripts/verona/download/fixture.csv">右クリックで保存</a><a target="_blank" href="${primary}/scripts/verona/download/fixture.xls">右クリックで保存</a><a href="https://example.invalid/unrelated.csv">Untouched</a></body></html>`],
  [primary + '/fixture/unknown-external', '<html><head></head><frameset rows="*,*"><frame name="local" src="/fixture/a"><frame name="unknown" src="https://example.invalid/frame"></frameset></html>'],
  ['https://example.invalid/frame', '<html><head></head><body>Untrusted fixture</body></html>'],
]);

(async () => {
  const browser = await chromium.launch({ headless: true, executablePath: process.env.CHROMIUM_EXECUTABLE, args: ['--no-sandbox'] });
  const context = await browser.newContext({ viewport: { width: 390, height: 844 }, isMobile: true, hasTouch: true });
  let submitted;
  const unexpected = [];
  await context.route('**/*', async route => {
    const request = route.request();
    const url = request.url();
    if (url === primary + '/fixture/submit') submitted = { method: request.method(), body: request.postData() };
    if (!fixtures.has(url)) { unexpected.push(url); await route.abort(); return; }
    await route.fulfill({ contentType: 'text/html; charset=utf-8', body: fixtures.get(url) });
  });
  const page = await context.newPage();
  const adapt = async () => {
    for (const frame of page.frames()) await frame.evaluate(scripts.viewportAndTouch);
  };
  const focus = value => page.evaluate(`(${scripts.frameFocus})(${JSON.stringify(value)})`);
  try {
    await page.goto(primary + '/fixture/daily');
    assert(await page.evaluate(() => innerWidth) > 390, 'Legacy viewport should initially be wider than the phone');
    await adapt();
    await page.waitForFunction(() => innerWidth === 390);
    await page.evaluate(() => {
      window.fixtureRootFrames = Array.from(document.querySelectorAll('frame'));
      window.fixtureForm = frames[0].document.forms[0];
      window.fixtureResultDocument = frames[1].frames[1].document;
      document.cookie = 'synthetic=one;path=/';
    });
    const panes = await page.evaluate(scripts.discoverFrames);
    assert.deepEqual(panes.map(item => item.path), [[0], [1, 0], [1, 1], [1, 2]]);
    assert.deepEqual(panes.map(item => item.kind), ['condition', 'result', 'result', 'result']);
    assert.equal(await page.locator('frameset').first().getAttribute('rows'), '180,*');
    assert.equal(await focus([1, 1]), true);
    assert.deepEqual(await page.evaluate(() => [document.querySelector('frameset').rows, frames[1].document.querySelector('frameset').rows, frames[1].document.querySelector('frameset[cols]').cols]), ['0,*', '0,*', '*,0']);
    assert.equal(await page.evaluate(() => fixtureRootFrames.every((node, i) => node === document.querySelectorAll('frame')[i]) && fixtureForm === frames[0].document.forms[0] && fixtureResultDocument === frames[1].frames[1].document), true);
    assert.match(await page.evaluate(() => document.cookie), /synthetic=one/);
    assert.equal(await focus(null), true);
    assert.deepEqual(await page.evaluate(() => [document.querySelector('frameset').rows, frames[1].document.querySelector('frameset').rows, frames[1].document.querySelector('frameset[cols]').cols]), ['180,*', '60%,*', '*,40%']);
    const condition = page.frames().find(frame => frame.name() === 'prtz030_1_1');
    assert.equal(await condition.evaluate(() => document.documentElement.scrollWidth <= 390), true);
    const result = page.frames().find(frame => frame.name() === 'prtz030_2_2');
    assert.equal(await result.locator('table').evaluate(table => table.getBoundingClientRect().width >= 900 && !table.hasAttribute('data-y3client-search-table')), true);
    assert.deepEqual(await condition.evaluate(() => {
      const field = document.querySelector('input[type=text]');
      const style = getComputedStyle(field);
      return { font: style.fontSize, minHeight: style.minHeight, viewport: !!document.querySelector('meta[name=viewport]') };
    }), { font: '16px', minHeight: '44px', viewport: true });
    assert.equal(await page.evaluate(scripts.siteHome), true);
    assert.equal(await page.evaluate(() => fixtureHomeClicks), 1);
    await condition.evaluate(() => document.forms[0].submit());
    await page.waitForFunction(() => frames[1].location.pathname === '/fixture/submit');
    assert.deepEqual(submitted, { method: 'POST', body: 'ft_YYYYMMDD_F=20261011&ft_YYYYMMDD_T=20261011' });

    await page.goto(primary + '/scripts/verona/dwh/prtz011_1.asp');
    await adapt();
    assert.deepEqual(await page.evaluate(scripts.discoverFrames), []);
    assert.equal(await page.locator('#layer0').evaluate(element => getComputedStyle(element).display), 'none');
    await page.locator('#layer0').evaluate(element => { element.style.display = 'block'; });
    assert.equal(await page.locator('#layer0').evaluate(element => element.getBoundingClientRect().right <= innerWidth), true);

    await page.goto(primary + '/scripts/verona/dwh/dstz210_2.asp');
    await adapt();
    assert.deepEqual(await page.evaluate(scripts.discoverFrames), [{ path: [0], kind: 'navigation' }, { path: [1], kind: 'export' }]);
    assert.equal(await focus([1]), true);
    assert.equal(await page.locator('frameset').getAttribute('rows'), '0,*');
    assert.equal(await focus(null), true);
    assert.equal(await page.locator('frameset').getAttribute('rows'), '90,*');
    const exporter = page.frames().find(frame => frame.name() === 'dstz210_2_2');
    assert.deepEqual(await exporter.locator('a').allTextContents(), ['CSVを保存', 'Excelを保存', 'Untouched']);
    assert.equal(await exporter.locator('a[download]').count(), 2);
    assert.equal(await exporter.locator('a').first().getAttribute('href'), primary + '/scripts/verona/download/fixture.csv');

    await page.goto(primary + '/fixture/unknown-external');
    assert.deepEqual(await page.evaluate(scripts.discoverFrames), [{ path: [0], kind: 'result' }]);
    assert.equal(await focus([1]), false);
    const untrusted = page.frames().find(frame => frame.url().startsWith('https://example.invalid/'));
    await untrusted.evaluate(scripts.viewportAndTouch);
    assert.equal(await untrusted.locator('[data-y3client-phone]').count(), 0);
    assert.deepEqual(unexpected, []);
    console.log(JSON.stringify({ status: 'passed', checks: ['mobile viewport narrows to phone width', 'frame paths/roles', 'fixed condition height', 'nested focus/restore preserves nodes', 'form POST and session unchanged', 'touch controls', 'search form wraps within phone width while data table remains wide', 'site-owned home handler', 'hidden helper stays separate', 'opaque export focus', 'narrow download link adaptation', 'untrusted frames excluded'], scope: 'Synthetic mobile Chromium DOM checks; no real site or iPhone execution.' }, null, 2));
  } finally { await browser.close(); }
})().catch(error => { console.error(error.message); process.exitCode = 1; });
