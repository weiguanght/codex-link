#!/usr/bin/env node
// Fully synthetic, intercepted browser requests. Never connects to the gateway.
// npm install --prefix build/ui-testing --no-save --no-package-lock playwright@1.56.1
// node scripts/test-web-ui.cjs
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const {execFileSync} = require('node:child_process');
const root = path.resolve(__dirname, '..');
const {chromium, webkit} = require(path.join(root, 'build/ui-testing/node_modules/playwright'));
const output = path.join(root, 'build/ui-preview');
fs.mkdirSync(output, {recursive: true});
const html = execFileSync('python3', ['-c',
  "from mac.web_ui import page; import sys; sys.stdout.buffer.write(page('vendor/codex-mobile-bridge/web'))"], {cwd: root});
const original = fs.readFileSync(path.join(root, 'vendor/codex-mobile-bridge/web/index.html'), 'utf8');
const originalIds = [...original.matchAll(/\bid="([^"]+)"/g)].map(m => m[1]).filter(id => id !== 'appearance-reasoning');
const titles = ['优化 iPhone 的聊天体验', '梳理会话发现与项目索引', '完善 IPv6 自动连接', '设计极简的阅读页面', '整理 Markdown 渲染样式', '添加跨平台构建说明', '检查消息发送与审批流程'];
const projects = ['codex-link', 'codex-link', 'codex-link', 'notes-app', 'notes-app', 'workspace', 'workspace'];
const rows = titles.map((title, i) => ({
  id: `00000000-0000-0000-0000-${String(i + 1).padStart(12, '0')}`,
  title, cwd: '/sample/' + projects[i], projectName: projects[i], projectKey: 'local|' + projects[i],
  host: 'local', hostLabel: '此电脑', recency: 1800000000000 - i * 86400000,
  readOnly: i === 6, desktopEligible: i !== 6, historyReadable: true,
}));
const meta = {id: rows[0].id, title: titles[0], cwd: '/sample/codex-link', host: 'local',
  model: 'gpt-5.4', effort: 'high', provider: 'sample', connected: true, status: 'idle',
  requests: [], submissions: [], historyComplete: true, goalRuntimeAvailable: true};
const messages = [
  {role: 'user', text: '参考移动端的设计，把聊天页面做得更简洁一些。'},
  {role: 'assistant', text: '可以。保留熟悉的交互，把注意力留给内容。\n\n### 这次调整\n\n- **更清晰的列表**：最近会话与项目分组切换。\n- **更轻的输入区**：模型选项、附件和发送各就其位。\n- **更舒适的阅读**：柔和的灰色气泡，自适应深色模式。\n\n```css\n.composer {\n  border-radius: 28px;\n  background: var(--surface);\n}\n```\n\n连接方式和 Codex 执行逻辑保持不变。'},
].map((row, i) => ({...row, key: 'message-' + i, order: i ? 7 : 0, version: 1, kind: 'message', truncated: false}));
const timeline = {epoch: 'synthetic', sequence: 1, before: null, hasMore: false, rows: messages, meta};
const reasoning = {key: 'reasoning-1', order: 1, version: 1, role: 'activity', kind: 'reasoning', title: '思考摘要', text: 'SYNTHETIC_REASONING_MUST_NOT_RENDER', truncated: true};
const tool = {key: 'tool-1', order: 2, version: 1, role: 'activity', kind: 'commandExecution', title: '执行命令', text: 'SYNTHETIC_TOOL_REMAINS_VISIBLE', truncated: false};
const toolOutput = {...tool, key: 'tool-output', order: 3, kind: 'function_call_output', title: '工具输出', text: 'SYNTHETIC_OUTPUT_PREVIEW', truncated: true};
const fileRead = {...tool, key: 'file-read', order: 4, kind: 'function_call', title: '读取文件', text: 'Read sample.txt'};
const fileWrite = {...tool, key: 'file-write', order: 5, kind: 'fileChange', title: '文件变更', text: 'Write sample.txt'};
const executionError = {key: 'error-1', order: 8, version: 1, role: 'error', kind: 'error', text: 'SYNTHETIC_ERROR_REMAINS_VISIBLE', truncated: false};
const visiblePage = {...timeline, rows: [...messages, reasoning, tool, toolOutput, fileRead, fileWrite, executionError]};
const engine = process.env.UI_BROWSER === 'webkit' ? webkit : chromium;

(async () => {
  const browser = await engine.launch({headless: true});
  try {
    const context = await browser.newContext({viewport: {width: 390, height: 844}, deviceScaleFactor: 2, locale: 'zh-CN', colorScheme: 'light'});
    const errors = [], unexpected = [], writes = [], detailReads = [];
    let largeList = false, failSend = false, historyGate = null;
    const registeredProjects = [{key: 'local|codex-link', name: 'codex-link', cwd: '/sample/codex-link', host: 'local', hostLabel: '此电脑', registered: true}];
    let settingsVersion = 1, settingsConflict = false, skillEnabled = true, settingsReads = 0;
    const configValues = {model: 'gpt-5.4', model_reasoning_effort: 'high'};
    function settingsFixture(scope = '') {
      const choices = {model_reasoning_summary: ['auto', 'concise', 'none'], model_verbosity: ['low', 'medium', 'high'], web_search: ['disabled', 'cached', 'live'], approval_policy: ['untrusted', 'on-request', 'never'], sandbox_mode: ['read-only', 'workspace-write', 'danger-full-access']};
      const keys = ['model', 'model_reasoning_effort', ...Object.keys(choices), 'developer_instructions'];
      return {scope: {key: scope, name: scope ? 'codex-link' : 'Global defaults'}, revision: 'config-' + settingsVersion,
        fields: Object.fromEntries(keys.map(key => [key, {kind: choices[key] ? 'choice' : key === 'developer_instructions' ? 'multiline' : 'text', value: configValues[key] ?? null,
          effective: configValues[key] ?? null, choices: choices[key] || [], editable: !scope, reason: '', origin: {type: 'user', file: '/sample/.codex/config.toml'}}])),
        writable: !scope, reason: scope ? '项目有效配置只读：原生接口不允许写项目配置。' : '', runtimeVersion: 'synthetic runtime', provider: 'sample',
        layers: [{type: 'user', file: '/sample/.codex/config.toml'}], capabilities: {models: true, skills: true, skillWrite: true, mcp: true}, notice: '保存后续会话的默认行为，不接管当前任务。'};
    }
    function skillFixture() { return {skills: [{name: 'Synthetic skill', path: '/sample/skills/demo/SKILL.md', enabled: skillEnabled, description: 'Only a synthetic skill', scope: 'user'}], revision: 'skills-' + settingsVersion, writable: true, notice: '技能开关写入全局用户配置。'}; }
    const preferences = new Map(), archivedRows = new Set(), renamed = new Map(), createdRows = [];
    const page = await context.newPage();
    await page.addInitScript(() => {
      if (!localStorage.getItem('bridge-appearance')) localStorage.setItem('bridge-appearance', JSON.stringify({showReasoning: true}));
    });
    if (process.env.DEBUG_CSP) {
      await page.addInitScript(() => {
        document.addEventListener('securitypolicyviolation', event => console.log('CSP_DEBUG', JSON.stringify({
          directive: event.effectiveDirective, source: event.sourceFile, line: event.lineNumber,
          blocked: event.blockedURI, sample: event.sample,
        })));
      });
      page.on('console', message => { if (message.text().includes('CSP_DEBUG')) console.log(message.text()); });
    }
    page.on('pageerror', error => errors.push(error.message));
    page.on('console', message => { if (message.type() === 'error' && message.text().includes('Content Security Policy')) errors.push(message.text()); });
    await context.route('**/*', async route => {
      const request = route.request(), url = new URL(request.url());
      if (url.hostname !== 'codex-link.test') { unexpected.push(url.origin); return route.abort(); }
      const p = url.pathname;
      if (p === '/link-history.js' && historyGate) await historyGate;
      const json = data => route.fulfill({json: data});
      if (p.startsWith('/api/')) {
        if (request.method() !== 'GET') writes.push({path: p, body: request.postDataJSON()});
        if (p === '/api/codex-settings') {
          settingsReads++;
          if (request.method() === 'POST') {
            const body = request.postDataJSON();
            if (settingsConflict || body.revision !== 'config-' + settingsVersion) return route.fulfill({status: 409, json: {error: '配置已被其他设备修改，请重新读取。', code: 'conflict'}});
            Object.assign(configValues, body.changes); settingsVersion++;
            return json({status: 'saved', settings: settingsFixture(), liveApplied: false, overridden: []});
          }
          return json(settingsFixture(url.searchParams.get('scope') || ''));
        }
        if (p === '/api/codex-settings/models') return json({models: [{id: 'gpt-5.4', name: 'GPT-5.4', efforts: ['low', 'medium', 'high']}], notice: 'Synthetic catalog'});
        if (p === '/api/codex-settings/skills') {
          if (request.method() === 'POST') { skillEnabled = request.postDataJSON().enabled; settingsVersion++; }
          return json(skillFixture());
        }
        if (p === '/api/codex-settings/mcp') return json({servers: [{name: 'Synthetic MCP', authStatus: 'notLoggedIn', toolCount: 2}], readOnly: true, notice: '设置查询进程状态，不代表桌面会话。'});
        if (p === '/api/auth') return json({authenticated: true, csrf: 'synthetic-only', instanceId: 'test', transport: 'poll'});
        if (p === '/api/accounts') return json({accounts: [], canSwitch: false});
        if (p === '/api/activity') return json({sessions: []});
        if (p === '/api/notifications/defaults') return json({requests: false, completion: false});
        if (p === '/api/projects') return json({projects: registeredProjects.filter(p => !p.hidden)});
        if (p === '/api/workspace/directories') {
          const folder = url.searchParams.get('path') || '/sample';
          return json({path: folder, parent: folder === '/sample' ? '/' : '/sample', directories: folder === '/sample' ? [{name: 'new-project', path: '/sample/new-project'}] : [], hasMore: false});
        }
        if (p === '/api/workspace/agents') return json({text: '# Synthetic instructions', readOnly: true});
        if (p === '/api/workspace/projects') {
          const body = request.postDataJSON();
          if (body.action === 'create') {
            if (!body.cwd.startsWith('/sample/')) return route.fulfill({status: 400, json: {error: 'Synthetic directory missing'}});
            const project = {key: 'local|link-' + body.id, name: body.name, cwd: body.cwd, host: 'local', hostLabel: '此电脑', registered: true, managed: true};
            registeredProjects.push(project); return json({project});
          }
          const project = registeredProjects.find(p => p.key === body.key); Object.assign(project, body.changes); return json({project});
        }
        if (p === '/api/workspace/preferences') {
          const body = request.postDataJSON();
          for (const row of body.sessions) preferences.set(row.id, {...preferences.get(row.id), ...body.changes});
          return json({ok: true});
        }
        if (p === '/api/workspace/archive') {
          const body = request.postDataJSON(); if (body.archived) archivedRows.add(body.id); else archivedRows.delete(body.id);
          return json({ok: true});
        }
        if (p.startsWith('/api/session-meta/')) {
          const row = [...rows, ...createdRows].find(row => p.endsWith(row.id)) || {...rows[0], id: p.split('/').pop()};
          return json({...row, ...preferences.get(row.id), archived: archivedRows.has(row.id), title: renamed.get(row.id) || row.title});
        }
        if (p.endsWith('/detail')) {
          const key = url.searchParams.get('key').split('.').at(-1), offset = Number(url.searchParams.get('offset') || 0);
          detailReads.push({key, offset});
          return json({key, offset, version: 1, text: offset ? 'SYNTHETIC_OUTPUT_END' : 'SYNTHETIC_FULL_OUTPUT_PART_1', next: offset ? null : 28});
        }
        if (p === '/api/sessions') {
          if (request.method() === 'POST') {
            const body = request.postDataJSON(), project = registeredProjects.find(p => p.key === body.project);
            const row = {...rows[0], id: '00000000-0000-0000-0000-000000000701', title: body.title, cwd: project.cwd, projectKey: project.key, projectName: project.name};
            createdRows.push(row); return json({id: row.id, host: 'local', message: 'Synthetic conversation created'});
          }
          const data = [...(largeList ? Array.from({length: 105}, (_, i) => ({...rows[i % rows.length], id: `00000000-0000-0000-0000-${String(i + 1).padStart(12, '0')}`})) : rows), ...createdRows]
            .map(row => ({...row, ...preferences.get(row.id), archived: archivedRows.has(row.id), title: renamed.get(row.id) || row.title}));
          let filtered = data.filter(row => row.archived === (url.searchParams.get('archived') === 'true') && !!row.hidden === (url.searchParams.get('hidden') === 'true') && row.title.includes(url.searchParams.get('q') || '') && (url.searchParams.get('scope') !== 'desktop' || !row.readOnly));
          if (url.searchParams.get('sort') === 'title') filtered.sort((a, b) => a.title.localeCompare(b.title));
          filtered.sort((a, b) => Number(!!b.pinned) - Number(!!a.pinned));
          const index = new Map();
          for (const row of filtered) {
            if (!index.has(row.projectKey)) index.set(row.projectKey, {key: row.projectKey, name: row.projectName, cwd: row.cwd, host: row.host, hostLabel: row.hostLabel, count: 0});
            index.get(row.projectKey).count++;
          }
          for (const project of registeredProjects) index.set(project.key, {...index.get(project.key) || {count: 0}, ...project});
          const selectedProject = index.get(url.searchParams.get('project'));
          if (url.searchParams.get('project')) filtered = filtered.filter(row => row.projectKey === url.searchParams.get('project'));
          const offset = Number(url.searchParams.get('offset') || 0);
          return json({sessions: filtered.slice(offset, offset + 100), total: filtered.length, hasMore: offset + 100 < filtered.length, projects: [...index.values()].filter(p => !!p.hidden === (url.searchParams.get('hidden') === 'true')), selectedProject, unavailableHosts: []});
        }
        if (p.startsWith('/api/history/')) return json({...visiblePage, meta: {...meta, readOnly: true, connected: false}, rows: p.endsWith('/changes') ? [reasoning] : visiblePage.rows});
        if (p.endsWith('/timeline')) return json(url.searchParams.has('before') ? visiblePage : {...timeline, rows: [reasoning], before: 'synthetic.reasoning-1', hasMore: true});
        if (p.endsWith('/changes')) {
          await new Promise(resolve => setTimeout(resolve, 700));
          return json({...timeline, sequence: 2, rows: [{...reasoning, version: 2}]});
        }
        if (p.endsWith('/notifications')) return json({available: false, watching: false, requests: 'inherit', completion: 'inherit'});
        if (p.endsWith('/reconnect')) return json({ok: true});
        if (p.endsWith('/rename')) { const id = p.split('/')[3]; renamed.set(id, request.postDataJSON().title); return json({id, title: renamed.get(id)}); }
        if (p.endsWith('/send')) return failSend ? route.fulfill({status: 503, json: {error: '模拟发送失败，请保留草稿后重试'}}) : json({status: 'sent'});
        if (p.endsWith('/stop')) return json({ok: true});
        if (p.endsWith('/catalog')) return json({models: [{id: 'gpt-5.4', name: 'GPT-5.4', efforts: ['low', 'medium', 'high']}], skills: []});
        unexpected.push(p);
        return route.fulfill({status: 404, json: {error: 'Synthetic endpoint not implemented'}});
      }
      const headers = {'content-security-policy': "default-src 'self'; script-src 'self'; style-src 'self'; style-src-attr 'unsafe-inline'; img-src 'self' data:; connect-src 'self'; object-src 'none'"};
      if (p === '/') return route.fulfill({body: html, contentType: 'text/html', headers});
      const base = /^\/link-(ui|history|workspace|settings|timeline|presentation)\./.test(p) ? 'web' : 'vendor/codex-mobile-bridge/web';
      const file = path.resolve(root, base, '.' + p);
      if (!file.startsWith(path.join(root, base) + path.sep) || !fs.existsSync(file)) { unexpected.push(p); return route.abort(); }
      const types = {'.css': 'text/css', '.js': 'text/javascript', '.png': 'image/png', '.woff2': 'font/woff2', '.webmanifest': 'application/manifest+json'};
      return route.fulfill({body: fs.readFileSync(file), contentType: types[path.extname(file)] || 'application/octet-stream', headers});
    });
    async function screenshot(name) {
      // Playwright 1.56's WebKit screenshot preparation injects `body {}` to
      // synchronize animations, even with caret:initial. Our CSP rejects it.
      // Test WebKit interactions with the strict CSP intact; capture Chromium.
      if (process.env.UI_BROWSER === 'webkit') return;
      await page.screenshot({path: path.join(output, `${process.env.UI_BROWSER || 'chromium'}-${name}.png`), caret: 'initial'});
    }
    async function noOverflow() {
      assert(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth), 'page overflows horizontally');
    }
    async function showFilters() {
      if (!(await page.locator('#workspace-options').getAttribute('open') !== null)) await page.locator('#workspace-options > summary').click();
    }
    async function chooseFilter(id, value) { await showFilters(); await page.selectOption(id, value); }
    await page.goto('http://codex-link.test');
    await page.waitForSelector('.session');
    assert.equal(await page.locator('.session').count(), 7);
    assert.equal(await page.title(), 'Codex Link');
    await page.waitForSelector('#accounts-button svg', {state: 'attached'});
    const domIds = await page.locator('[id]').evaluateAll(nodes => nodes.map(n => n.id));
    for (const id of originalIds) assert.equal(domIds.filter(v => v === id).length, 1, `missing/duplicate #${id}`);
    assert.equal(await page.locator('#appearance-reasoning').count(), 0);
    await noOverflow();
    await screenshot('recent');
    await page.click('[data-mode=project]');
    await page.waitForSelector('.history-project');
    assert.equal(await page.locator('.history-project').count(), 3);
    await screenshot('projects');
    await page.locator('.history-project').first().click();
    await page.waitForSelector('.session');
    await page.locator('.session').first().click();
    await page.waitForSelector('.message.assistant');
    assert.equal(await page.locator('.message.assistant > .who').first().isVisible(), false);
    assert.equal(await page.locator('.message.assistant .message-copy').first().isVisible(), true);
    async function noReasoning() {
      assert.equal(await page.locator('#messages [data-key=reasoning-1]').count(), 0);
      assert(!(await page.locator('#messages').textContent()).includes(reasoning.text));
      assert.equal(await page.evaluate(() => chatTimeline.rows.has('reasoning-1')), false);
    }
    await noReasoning();
    const processGroup = page.locator('.link-process-group').first();
    assert.equal(await page.locator('.link-process-group').count(), 1);
    assert.equal(await processGroup.getAttribute('open'), null);
    const processSpacing = await processGroup.evaluate(node => ({
      before: node.getBoundingClientRect().top - node.previousElementSibling.getBoundingClientRect().bottom,
      after: node.nextElementSibling.getBoundingClientRect().top - node.getBoundingClientRect().bottom,
    }));
    assert(processSpacing.before >= 0 && processSpacing.before <= 8, 'compact gap before tool activity');
    assert(processSpacing.after >= 0 && processSpacing.after <= 8, 'compact gap after tool activity');
    assert((await processGroup.locator('summary').textContent()).includes('4 项'));
    for (const key of ['tool-1', 'tool-output', 'file-read', 'file-write']) assert.equal(await page.locator(`#messages .timeline-row[data-key=${key}]`).isVisible(), false);
    assert.equal(detailReads.length, 0, 'collapsed tool activity must not fetch full output');
    assert.equal(await page.locator('#messages [data-key=error-1]').isVisible(), true);
    await page.waitForFunction(() => chatTimeline.sequence === 2);
    await noReasoning();
    await processGroup.locator('summary').click();
    for (const key of ['tool-1', 'tool-output', 'file-read', 'file-write']) assert.equal(await page.locator(`#messages .timeline-row[data-key=${key}]`).isVisible(), true);
    assert.equal(detailReads.length, 0, 'opening the group must only reveal previews');
    const disclosureTop = await processGroup.locator('summary').evaluate(node => node.getBoundingClientRect().top);
    assert.equal(await page.evaluate(() => chatTimeline.following), false, 'manual expansion must hold the reading position');
    await page.locator('[data-key=tool-output] .detail-more').click();
    await page.waitForFunction(() => document.querySelector('[data-key=tool-output] pre').textContent === 'SYNTHETIC_FULL_OUTPUT_PART_1');
    await page.locator('[data-key=tool-output] .detail-more').click();
    await page.waitForFunction(() => document.querySelector('[data-key=tool-output] pre').textContent.endsWith('SYNTHETIC_OUTPUT_END'));
    assert.equal(await page.locator('[data-key=tool-output] .detail-more').isVisible(), false);
    assert.equal(detailReads.length, 2);
    for (const width of [320, 390, 768]) {
      await page.setViewportSize({width, height: 844}); await noOverflow();
    }
    await page.setViewportSize({width: 390, height: 844});
    await screenshot('tool-activity-expanded');
    // Changed records, appended calls and history prepends retain this choice.
    await page.evaluate(({tool, timeline}) => {
      chatTimeline.apply({...timeline, sequence: 3, rows: [{...tool, version: 2, status: 'inProgress', text: 'updated command'}, {...tool, key: 'new-tool', order: 6}]});
    }, {tool, timeline});
    assert(await processGroup.getAttribute('open') !== null);
    assert((await processGroup.locator('summary').textContent()).includes('5 项'));
    assert.equal(await processGroup.locator('.link-process-status').isVisible(), true);
    await page.evaluate(({tool, timeline}) => chatTimeline.apply({...timeline, sequence: 1, before: null, hasMore: false,
      rows: [{...tool, key: 'older-tool', order: 1.5}]}, false, true), {tool, timeline});
    assert(await processGroup.getAttribute('open') !== null);
    assert((await processGroup.locator('summary').textContent()).includes('6 项'));
    assert(Math.abs(await processGroup.locator('summary').evaluate(node => node.getBoundingClientRect().top) - disclosureTop) < 3, 'history prepend must preserve the expanded disclosure position');
    // Messages and errors delimit separate groups; new groups stay collapsed.
    await page.evaluate(({tool, timeline}) => chatTimeline.apply({...timeline, sequence: 4, rows: [
      {key: 'commentary', order: 5.5, version: 1, role: 'assistant', phase: 'commentary', text: 'Visible progress', truncated: false},
      {...tool, key: 'next-turn-tool', order: 9, turnId: 'next-turn'},
      {...tool, key: 'other-turn-tool', order: 10, turnId: 'other-turn'},
    ]}), {tool, timeline});
    assert.equal(await page.locator('.link-process-group').count(), 4);
    assert.equal(await page.locator('#messages > [data-key=commentary]').isVisible(), true);
    assert.equal(await page.locator('#messages > [data-key=error-1]').isVisible(), true);
    for (const group of await page.locator('.link-process-group').all()) {
      if (await group.getAttribute('open') !== null) await group.locator('summary').click();
    }
    await page.evaluate(({tool, timeline}) => chatTimeline.apply({...timeline, sequence: 5, rows: [{...tool, version: 3}]}), {tool, timeline});
    assert.equal(await processGroup.getAttribute('open'), null);
    // Refresh and reopening return all groups to their default collapsed state.
    await page.evaluate(visiblePage => chatTimeline.apply(visiblePage, true), visiblePage);
    assert.equal(await page.locator('.link-process-group[open]').count(), 0);
    assert.equal(await page.locator('#send').isVisible(), true);
    assert.equal(await page.locator('#send').isEnabled(), false);
    assert.equal(await page.locator('#stop').isVisible(), false);
    assert.equal(await page.locator('#send').evaluate(node => getComputedStyle(node).backgroundColor), 'rgb(235, 235, 235)', 'empty idle draft uses a gray send button');
    assert.equal(await page.locator('.link-composer-options').evaluate(n => [...n.childNodes].filter(c => c.nodeType === Node.TEXT_NODE).map(c => c.textContent).join('').trim()), '');
    await page.evaluate(() => { document.getElementById('timeline').scrollTop = 0; });
    await screenshot('chat');
    const chooserEvent = page.waitForEvent('filechooser');
    await page.click('#attach-button');
    assert.equal((await chooserEvent).isMultiple(), true);
    await page.click('#model-button');
    await page.waitForFunction(() => document.getElementById('model-select').value === 'gpt-5.4');
    assert.equal(await page.locator('#model-error').textContent(), '');
    await page.locator('#model-dialog [data-close=model-dialog]').click();
    await page.click('#skills-button');
    await page.waitForSelector('#skill-list .muted');
    await page.locator('#skills-dialog [data-close=skills-dialog]').first().click();
    await page.fill('#message', '这是一条保留的草稿');
    await page.click('#composer-toggle');
    assert.equal(await page.locator('#composer-body').isVisible(), false);
    await page.click('#composer-toggle');
    assert.equal(await page.inputValue('#message'), '这是一条保留的草稿');
    await page.click('#back');
    await page.click('[data-mode=recent]');
    await page.locator('.session').first().click();
    assert.equal(await page.inputValue('#message'), '这是一条保留的草稿');
    failSend = true;
    await page.click('#send');
    await page.waitForSelector('#send-error:not(:empty)');
    assert.equal(await page.inputValue('#message'), '这是一条保留的草稿');
    failSend = false;
    await page.click('#send');
    await page.waitForFunction(() => document.getElementById('message').value === '');
    assert.equal(await page.locator('#send').isEnabled(), false, 'successful send clears and disables the empty draft');
    assert(writes.some(w => w.path.endsWith('/send') && w.body.text === '这是一条保留的草稿'));
    const attempts = writes.filter(w => w.path.endsWith('/send'));
    assert.equal(attempts.length, 2);
    assert.equal(attempts[0].body.id, attempts[1].body.id, 'retry must reuse upstream idempotency key');

    // Rendering approval/working/offline states uses only the synthetic fixture.
    // Stop polling while exercising task transitions so idle fixture updates
    // cannot replace the explicit synthetic states below.
    await page.evaluate(() => chatTimeline.abort.abort());
    await page.evaluate(() => renderState({...state, status: 'active'}));
    assert.equal(await page.locator('#stop').isVisible(), true);
    assert.equal(await page.locator('#send').isVisible(), false);
    await page.fill('#message', '补充当前任务');
    assert.equal(await page.locator('#send').isVisible(), true);
    assert.equal(await page.locator('#send').isEnabled(), true);
    assert.equal(await page.locator('#stop').isVisible(), false);
    await page.selectOption('#send-mode', 'steer');
    assert((await page.locator('#send').getAttribute('aria-label')).length > 0);
    await page.evaluate(() => renderState({...state, status: 'active'}));
    assert.equal(await page.locator('#stop').isVisible(), false, 'state refresh preserves send-only for a nonempty draft');
    await page.fill('#message', '  \n ');
    assert.equal(await page.locator('#stop').isVisible(), true);
    assert.equal(await page.locator('#send').isVisible(), false);
    // An attachment-only draft can be sent; uploads keep send disabled and
    // removing the last attachment returns to stop for the active task.
    await page.evaluate(() => {
      attachments.rows.push({id: 'synthetic-attachment', name: 'sample.txt', size: 10, status: 'uploading'});
      attachments.render();
    });
    assert.equal(await page.locator('#stop').isVisible(), false);
    assert.equal(await page.locator('#send').isVisible(), true);
    assert.equal(await page.locator('#send').isEnabled(), false);
    await page.evaluate(() => { attachments.rows[0].status = 'ready'; attachments.render(); });
    assert.equal(await page.locator('#send').isEnabled(), true);
    await page.locator('.attachment-remove').click();
    assert.equal(await page.locator('#stop').isVisible(), true);
    assert.equal(await page.locator('#send').isVisible(), false);
    await page.fill('#message', '');
    await page.click('#stop');
    assert(writes.some(w => w.path.endsWith('/stop')));
    await page.evaluate(() => renderState({...state, status: 'idle'}));
    assert.equal(await page.locator('#stop').isVisible(), false);
    assert.equal(await page.locator('#send').isVisible(), true);
    assert.equal(await page.locator('#send').isEnabled(), false);
    await page.fill('#message', '下一条消息');
    assert.equal(await page.locator('#send').isEnabled(), true);
    assert.equal(await page.locator('#stop').isVisible(), false);
    await page.evaluate(() => renderState({...state, loadingHistory: true}));
    assert.equal(await page.locator('#send').isEnabled(), false, 'history loading still blocks sending');
    await page.evaluate(() => renderState({...state, loadingHistory: false}));
    assert.equal(await page.locator('#send').isEnabled(), true);
    await page.fill('#message', '');
    await page.evaluate(() => renderState({...state, connected: false, status: 'idle', connectionError: '模拟离线：Mac 暂时不可达'}));
    assert.equal(await page.locator('#notice').isVisible(), true);
    await screenshot('offline');
    await page.evaluate(() => renderState({...state, connected: true, connectionError: '', requests: [{id: 'test-approval', method: 'item/commandExecution/requestApproval', supported: true, params: {command: 'echo synthetic-test', reason: '仅用于验证审批卡片布局'}}]}));
    assert.equal(await page.locator('.approval').count(), 1);
    await noOverflow();
    await screenshot('approval');

    for (const width of [320, 375, 430, 768, 1280]) {
      await page.setViewportSize({width, height: 844});
      await noOverflow();
      const box = await page.locator('#composer').boundingBox();
      assert(box && box.y + box.height <= 845, 'composer below viewport');
      assert((await page.locator('#send').boundingBox()).width >= 44);
      if (width === 1280) await screenshot('desktop');
    }
    await page.setViewportSize({width: 390, height: 460});
    await noOverflow();
    assert((await page.locator('#composer').boundingBox()).y >= 0);
    await page.setViewportSize({width: 390, height: 844});
    await page.locator('.chat-head [data-open-appearance]').click();
    await page.click('#appearance-reset');
    assert.equal(await page.isChecked('#appearance-copy'), true);
    assert.equal(await page.locator('.message-copy').first().isVisible(), true);
    await page.uncheck('#appearance-copy');
    assert.equal(await page.locator('.message-copy:visible').count(), 0);
    assert.equal(await page.locator('.message-actions:visible').count(), 0, 'copy-only action rows leave no blank space');
    assert.equal(await page.locator('.code-copy').first().isVisible(), true);
    assert.equal(await page.evaluate(() => JSON.parse(localStorage.getItem('bridge-appearance')).showCopyButtons), false);
    // The option applies to new replies while preserving other message actions.
    await page.evaluate(({timeline, messages}) => chatTimeline.apply({...timeline, sequence: 3, rows: [
      {...messages[1], key: 'copy-setting-reply', order: 9, forkable: true, turnStatus: 'completed'},
    ]}), {timeline, messages});
    assert.equal(await page.locator('[data-key=copy-setting-reply] .message-copy').isVisible(), false);
    assert.equal(await page.locator('[data-key=copy-setting-reply] .message-fork').isVisible(), true);
    assert.equal(await page.locator('[data-key=copy-setting-reply] .who').isVisible(), false);
    await page.locator('#appearance-dialog [data-close=appearance-dialog]').first().click();
    await page.reload();
    await page.waitForSelector('.message.assistant');
    assert.equal(await page.isChecked('#appearance-copy'), false, 'copy preference survives page refresh');
    assert.equal(await page.locator('.message-copy:visible').count(), 0);
    await page.locator('.chat-head [data-open-appearance]').click();
    await page.check('#appearance-copy');
    assert.equal(await page.locator('.message-copy').first().isVisible(), true);
    await page.uncheck('#appearance-copy');
    await page.click('#appearance-reset');
    assert.equal(await page.isChecked('#appearance-copy'), true, 'reset restores copy buttons');
    await noReasoning();
    await page.uncheck('#appearance-process');
    assert.equal(await page.locator('#messages .timeline-row[data-key=tool-1]').isVisible(), false);
    assert.equal(await page.locator('#messages [data-key=error-1]').isVisible(), true);
    await page.check('#appearance-process');
    assert.equal(await page.locator('.link-process-group').first().isVisible(), true);
    assert.equal(await page.locator('#messages .timeline-row[data-key=tool-1]').isVisible(), false);
    await noReasoning();
    assert.equal(await page.evaluate(() => Object.hasOwn(JSON.parse(localStorage.getItem('bridge-appearance')), 'showReasoning')), false);
    await page.selectOption('#appearance-theme', 'dark');
    await page.selectOption('#appearance-language', 'en');
    await page.waitForFunction(() => document.documentElement.lang === 'en');
    assert.equal(await page.locator('label:has(#appearance-copy) strong').textContent(), 'Copy buttons');
    assert.equal(await page.locator('.message.assistant > .who').first().isVisible(), false);
    assert.equal(await page.locator('.link-process-label').first().textContent(), 'Tool activity');
    assert.equal(await page.locator('.link-process-count').first().textContent(), '4 items');
    assert((await page.locator('.conversation-options .appearance-note').textContent()).startsWith('Hide execution details'));
    assert.equal(await page.locator('[data-mode=project]').textContent(), 'Projects');
    await noOverflow();
    await screenshot('settings-dark');
    await page.locator('#appearance-dialog [data-close=appearance-dialog]').first().click();
    assert.equal(await page.locator('#work-mode option:checked').textContent(), 'Default');
    await page.waitForFunction(() => document.getElementById('toast').hidden);
    await screenshot('chat-dark');
    await page.click('#back');
    await page.fill('#search', 'no-such-synthetic-session');
    await page.waitForFunction(() => document.querySelectorAll('.session').length === 0);
    assert((await page.locator('.link-list-caption').textContent()).includes('0 loaded'));
    await page.fill('#search', '');
    await page.waitForSelector('.session');
    await showFilters();
    await showFilters(); await page.check('#archived');
    await page.waitForFunction(() => document.querySelectorAll('.session').length === 0);
    await showFilters(); await page.uncheck('#archived');
    largeList = true;
    await page.click('#refresh');
    await page.waitForFunction(() => document.querySelectorAll('.session').length === 100);
    await page.click('#more');
    await page.waitForFunction(() => document.querySelectorAll('.session').length === 105);
    assert.equal(await page.locator('#more').isVisible(), false);
    await page.click('#new-chat');
    await page.waitForSelector('#new-chat-project option', {state: 'attached'});
    assert.equal(await page.locator('#new-chat-dialog').isVisible(), true);
    await noOverflow();
    await page.locator('#new-chat-dialog [data-close=new-chat-dialog]').click();
    await chooseFilter('#history-scope', 'desktop');
    await page.waitForFunction(() => !document.querySelector('.history-badge'));
    await chooseFilter('#history-scope', 'all');
    await page.waitForSelector('.history-badge');
    const readOnlyId = rows[6].id;
    const beforeRead = writes.length;
    await page.evaluate(id => openChat(id, 'local'), readOnlyId);
    await page.waitForSelector('.history-read-bar:not([hidden])');
    assert.equal(await page.locator('#composer').isVisible(), false);
    assert.equal(await page.locator('#send').isEnabled(), false);
    await page.click('#history-refresh');
    await page.waitForSelector('.message.assistant');
    await noReasoning();
    assert.equal(await page.locator('.link-process-group[open]').count(), 0);
    await page.locator('.link-process-group > summary').first().focus();
    await page.keyboard.press('Enter');
    assert.equal(await page.locator('#messages [data-key=tool-output]').isVisible(), true);
    await page.keyboard.press('Enter');
    assert.equal(await page.locator('#messages [data-key=tool-output]').isVisible(), false);
    const prevented = await page.evaluate(async id => { try { await api('/api/sessions/' + id + '/send', {text: 'must not send'}); return false; } catch { return true; } }, readOnlyId);
    assert(prevented);
    assert(!writes.slice(beforeRead).some(w => w.path.includes(readOnlyId)), 'read-only open/reload must not activate or write');
    await screenshot('readonly-history');
    await page.evaluate(id => openChat(id, 'local'), rows[0].id);
    await page.waitForSelector('#composer:not([hidden])');
    await page.click('#chat-details-button');
    const reconnects = writes.filter(w => w.path.endsWith('/reconnect')).length;
    await page.click('#history-inspect');
    await page.waitForSelector('.history-read-bar:not([hidden])');
    assert.equal(writes.filter(w => w.path.endsWith('/reconnect')).length, reconnects, 'explicit desktop log view must not reactivate');
    // Authentication may finish before a deferred feature asset on slow Wi-Fi.
    // A saved project view must still acquire the complete server index.
    let releaseHistory;
    historyGate = new Promise(resolve => { releaseHistory = resolve; });
    const slowPage = await context.newPage();
    slowPage.on('pageerror', error => errors.push(error.message));
    await slowPage.addInitScript(() => localStorage.setItem('list-mode', 'project'));
    await slowPage.goto('http://codex-link.test/', {waitUntil: 'commit'});
    await slowPage.waitForSelector('.session');
    assert.equal(await slowPage.evaluate(() => !!window.LinkReading), false);
    releaseHistory(); historyGate = null;
    await slowPage.waitForSelector('.history-project');
    assert.equal(await slowPage.locator('.history-project').count(), 3);
    await slowPage.close();

    // Project creation is a real form workflow, not a decorative demo button.
    await page.click('#back'); largeList = false;
    await page.click('[data-mode=project]');
    await page.waitForSelector('.history-project');
    await page.click('#workspace-new-project');
    await page.fill('#workspace-project-name', 'Mobile project');
    await page.fill('#workspace-project-path', '/missing-path');
    await page.click('.workspace-project-save');
    await page.waitForSelector('#workspace-project-dialog .error:not(:empty)');
    assert.equal(await page.inputValue('#workspace-project-name'), 'Mobile project', 'failed create keeps fields');
    await page.getByRole('button', {name: 'Browse Mac folders…', exact: true}).click();
    await page.fill('#workspace-directory-path', '/sample');
    await page.getByRole('button', {name: 'Go / Filter', exact: true}).click();
    await page.locator('.workspace-directories button').filter({hasText: 'new-project'}).click();
    await page.getByRole('button', {name: 'Use this folder', exact: true}).click();
    assert.equal(await page.inputValue('#workspace-project-path'), '/sample/new-project');
    await page.check('#workspace-create-directory');
    await page.click('.workspace-project-save');
    await page.waitForSelector('.workspace-context strong');
    assert.equal(await page.locator('.workspace-context strong').textContent(), 'Mobile project');
    const createdProject = registeredProjects.find(p => p.name === 'Mobile project');
    assert(createdProject);
    assert(writes.some(w => w.path === '/api/workspace/projects' && w.body.createDirectory === true));
    await page.locator('.history-project-back').click();
    await page.waitForFunction(() => document.querySelectorAll('.history-project').length === 4);
    if (await page.locator('#workspace-options').getAttribute('open') !== null) await page.locator('#workspace-options > summary').click();
    await screenshot('workspace-projects');
    const projectCard = () => page.locator('.workspace-project-row').filter({hasText: 'Mobile project'});
    await projectCard().locator('.workspace-row-menu').click();
    await page.getByRole('button', {name: 'Rename in codex-link', exact: true}).click();
    await page.fill('#workspace-project-name', 'Renamed project');
    await page.click('.workspace-project-save');
    await page.waitForFunction(() => document.querySelector('.workspace-context strong')?.textContent === 'Renamed project');
    await page.locator('.workspace-context').getByRole('button', {name: '+ New conversation', exact: true}).click();
    await page.waitForSelector('#new-chat-project option', {state: 'attached'});
    assert.equal(await page.inputValue('#new-chat-project'), createdProject.key, 'new conversation uses the current project');
    await page.fill('#new-chat-title', 'Created from project');
    await page.click('#new-chat-submit');
    await page.waitForSelector('.message.assistant');
    assert(writes.some(w => w.path === '/api/sessions' && w.body.project === createdProject.key));
    await page.click('#back');
    await page.click('[data-mode=project]');
    await page.waitForSelector('.history-project');
    await page.locator('.workspace-project-row').filter({hasText: 'Renamed project'}).locator('.workspace-row-menu').click();
    await page.getByRole('button', {name: 'Hide project', exact: true}).click();
    await page.getByRole('button', {name: 'Confirm', exact: true}).click();
    await page.waitForFunction(() => ![...document.querySelectorAll('.history-project')].some(n => n.textContent.includes('Renamed project')));
    await showFilters();
    await chooseFilter('#workspace-visibility', 'hidden');
    await page.waitForSelector('.history-project');
    await page.locator('.workspace-project-row').filter({hasText: 'Renamed project'}).locator('.workspace-row-menu').click();
    await page.getByRole('button', {name: 'Restore project', exact: true}).click();
    await page.getByRole('button', {name: 'Confirm', exact: true}).click();
    await chooseFilter('#workspace-visibility', 'visible');
    await page.click('[data-mode=recent]');
    await page.waitForSelector('.session');
    const menuFor = id => page.locator('.workspace-session-row').filter({has: page.locator(`.session[data-id="${id}"]`)}).locator('.workspace-row-menu');
    const desktopId = rows[1].id;
    await menuFor(desktopId).click();
    await screenshot('workspace-conversation-menu');
    await page.getByRole('button', {name: 'Rename conversation', exact: true}).click();
    await page.fill('#workspace-thread-name', 'AAA renamed');
    await page.locator('.workspace-dialog').getByRole('button', {name: 'Save', exact: true}).click();
    await page.waitForFunction(() => [...document.querySelectorAll('.session strong')].some(n => n.textContent.includes('AAA renamed')));
    await menuFor(desktopId).click();
    await page.getByRole('button', {name: 'Pin conversation', exact: true}).click();
    await page.waitForSelector('.workspace-pin');
    assert.equal(await page.locator('.session').first().getAttribute('data-id'), desktopId);
    await chooseFilter('#workspace-sort', 'title');
    await page.waitForSelector('.workspace-pin');
    await menuFor(desktopId).click();
    await page.getByRole('button', {name: 'Archive conversation', exact: true}).click();
    await page.getByRole('button', {name: 'Confirm', exact: true}).click();
    await page.waitForFunction(id => !document.querySelector(`.session[data-id="${id}"]`), desktopId);
    await showFilters(); await page.check('#archived');
    await page.waitForSelector(`.session[data-id="${desktopId}"]`);
    await menuFor(desktopId).click();
    await page.getByRole('button', {name: 'Unarchive', exact: true}).click();
    await page.getByRole('button', {name: 'Confirm', exact: true}).click();
    await showFilters(); await page.uncheck('#archived');
    await page.waitForSelector('.history-badge');
    await menuFor(readOnlyId).click();
    assert.equal(await page.getByRole('button', {name: 'Archive conversation', exact: true}).count(), 0);
    await page.getByRole('button', {name: 'Hide from list', exact: true}).click();
    await page.getByRole('button', {name: 'Confirm', exact: true}).click();
    await page.waitForFunction(id => !document.querySelector(`.session[data-id="${id}"]`), readOnlyId);
    await chooseFilter('#workspace-visibility', 'hidden');
    await page.waitForSelector(`.session[data-id="${readOnlyId}"]`);
    await showFilters(); await page.click('#workspace-select');
    await page.locator('.workspace-batch').getByRole('button', {name: 'Select loaded', exact: true}).click();
    assert.equal(await page.locator('.workspace-batch').getByRole('button', {name: 'Archive', exact: true}).isEnabled(), false);
    await page.locator('.workspace-batch').getByRole('button', {name: 'Restore', exact: true}).click();
    await page.getByRole('button', {name: 'Confirm', exact: true}).click();
    await chooseFilter('#workspace-visibility', 'visible');
    await page.waitForSelector('.history-badge');
    await showFilters(); await page.click('#workspace-select');
    await noOverflow();
    // Keep a current, synthetic Chinese/light preview for the operation docs.
    await page.locator('.phone-header [data-open-appearance]').click();
    await page.selectOption('#appearance-theme', 'light');
    await page.selectOption('#appearance-language', 'zh');
    await page.locator('#appearance-dialog [data-close=appearance-dialog]').first().click();
    await page.click('[data-mode=project]');
    await page.waitForSelector('.history-project');
    await page.waitForFunction(() => document.getElementById('toast').hidden);
    await screenshot('workspace-projects-zh');
    await page.click('#workspace-new-project');
    await page.fill('#workspace-project-name', '我的新项目');
    await page.fill('#workspace-project-path', '/sample/my-project');
    await screenshot('workspace-create-zh');
    await page.locator('#workspace-project-dialog .picker-head button').click();
    // Settings are lazy, explicit, and never use thread/resume or turn/start.
    assert.equal(settingsReads, 0, 'settings must not load automatically');
    await page.locator('.phone-header [data-open-appearance]').click();
    await page.locator('.settings-appearance-entry').click();
    await page.waitForSelector('#setting-model');
    const settings = page.locator('#codex-settings-dialog');
    await screenshot('settings-defaults-zh');
    await page.fill('#setting-model_reasoning_effort', 'medium');
    await page.click('#codex-settings-save');
    await page.waitForFunction(() => document.getElementById('codex-settings-status').textContent.includes('回读确认'));
    assert.deepEqual(writes.filter(w => w.path === '/api/codex-settings').at(-1).body.changes, {model_reasoning_effort: 'medium'});
    await page.click('#codex-settings-load-models');
    await page.waitForSelector('#codex-settings-models option', {state: 'attached'});
    assert.equal(await page.locator('#codex-settings-efforts option').count(), 3);
    settingsConflict = true;
    await page.selectOption('#setting-web_search', 'live'); await page.click('#codex-settings-save');
    await page.waitForFunction(() => document.getElementById('codex-settings-error').textContent.includes('其他设备'));
    assert.equal(await page.inputValue('#setting-web_search'), 'live', 'conflict preserves draft');
    assert.equal(await page.isDisabled('#codex-settings-save'), true);
    settingsConflict = false;
    await page.click('#codex-settings-reload');
    await page.locator('.settings-confirm').getByRole('button', {name: '放弃更改', exact: true}).click();
    await page.waitForFunction(() => document.getElementById('setting-web_search').value === '');
    await page.selectOption('#setting-sandbox_mode', 'danger-full-access'); await page.click('#codex-settings-save');
    const countBeforeCancel = writes.length;
    await page.locator('.settings-confirm').getByRole('button', {name: '取消', exact: true}).click();
    assert.equal(writes.length, countBeforeCancel);
    await page.click('#codex-settings-save');
    await page.locator('.settings-confirm').getByRole('button', {name: '确认并保存', exact: true}).click();
    await page.waitForFunction(() => document.getElementById('codex-settings-status').textContent.includes('回读确认'));
    assert.equal(writes.filter(w => w.path === '/api/codex-settings').at(-1).body.confirmPermissions, true);
    await settings.getByRole('button', {name: 'Skills', exact: true}).click();
    await settings.getByRole('button', {name: '读取技能', exact: true}).click();
    await settings.getByRole('button', {name: '已启用 · 点击禁用', exact: true}).click();
    await page.locator('.settings-confirm').getByRole('button', {name: '确认修改', exact: true}).click();
    await settings.getByRole('button', {name: '已禁用 · 点击启用', exact: true}).waitFor();
    assert.equal(skillEnabled, false);
    await settings.getByRole('button', {name: 'MCP', exact: true}).click();
    await settings.getByRole('button', {name: '读取 MCP 状态', exact: true}).click();
    await settings.getByText('Synthetic MCP', {exact: true}).waitFor();
    await page.selectOption('#codex-settings-scope', 'local|codex-link');
    await settings.getByText('项目有效配置只读：原生接口不允许写项目配置。', {exact: true}).waitFor();
    assert.equal(await page.isDisabled('#setting-model'), true);
    assert.equal(await page.isDisabled('#codex-settings-save'), true);
    await screenshot('settings-project-zh');
    for (const width of [320, 375, 430, 768, 1280]) {
      await page.setViewportSize({width, height: 844}); await noOverflow();
      assert(await settings.evaluate(d => d.scrollWidth <= d.clientWidth + 1), 'settings overflow');
    }
    await settings.getByRole('button', {name: '关闭设置', exact: true}).click();
    for (const width of [320, 375, 430, 768, 1280]) { await page.setViewportSize({width, height: 844}); await noOverflow(); }
    assert.deepEqual(errors, [], 'browser errors');
    assert.deepEqual(unexpected, [], 'unexpected network requests');
    console.log('PASS: persistent copy-button setting, no reply brand labels, compact tool/reply spacing; exclusive stop/send actions, collapsed tool groups, manual/keyboard disclosure, paged full output, live updates/history prepends preserve expansion and reading position, reset, narrow layouts, reasoning omitted, views, drafts, send failure/retry, stop, approvals, offline, dark/English, read-only history, workspace operations and settings.');
    console.log(process.env.UI_BROWSER === 'webkit' ? 'WebKit: strict CSP preserved; screenshots skipped (Playwright inline-style injection).' : 'Synthetic screenshots: ' + output);
    await context.close();
  } finally { await browser.close(); }
})().catch(error => { console.error(error); process.exitCode = 1; });
