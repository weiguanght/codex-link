'use strict';
// Real settings facade. Never resume a thread or send a turn from this channel.
(() => {
  const get = id => document.getElementById(id);
  const words = (zh, en) => document.documentElement.lang.startsWith('en') ? en : zh;
  const node = (tag, cls, text) => {
    const n = document.createElement(tag);
    if (cls) n.className = cls;
    if (text !== undefined) n.textContent = text;
    return n;
  };
  const button = (label, action, cls = 'plain') => {
    const b = node('button', cls, label); b.type = 'button'; b.onclick = action; return b;
  };
  const endpoint = '/api/codex-settings';
  let active = null;
  const labels = {
    model: ['默认模型', 'Default model'], model_reasoning_effort: ['推理强度', 'Reasoning effort'],
    model_reasoning_summary: ['推理摘要', 'Reasoning summary'], model_verbosity: ['回答详略', 'Response verbosity'],
    web_search: ['联网搜索', 'Web search'], approval_policy: ['审批策略', 'Approval policy'],
    sandbox_mode: ['执行沙盒', 'Execution sandbox'], developer_instructions: ['开发者指令', 'Developer instructions'],
  };
  const optionLabels = {
    disabled: ['关闭', 'Off'], cached: ['缓存搜索', 'Cached search'], live: ['实时搜索', 'Live search'],
    'read-only': ['只读', 'Read only'], 'workspace-write': ['允许写工作区', 'Workspace write'],
    'danger-full-access': ['完全访问（高风险）', 'Full access (high risk)'],
    untrusted: ['不受信任时审批', 'Untrusted'], 'on-request': ['按需审批', 'On request'], never: ['从不审批（高风险）', 'Never (high risk)'],
  };
  function confirm(title, hint, label) {
    return new Promise(resolve => {
      const d = node('dialog', 'picker settings-confirm');
      d.setAttribute('aria-label', title);
      d.append(node('h2', '', title), node('p', 'settings-note', hint));
      let accepted = false;
      d.append(button(words('取消', 'Cancel'), () => d.close()), button(label, () => { accepted = true; d.close(); }, 'primary'));
      d.addEventListener('close', () => { d.remove(); resolve(accepted); }, {once: true});
      document.body.append(d); d.showModal();
    });
  }
  function source(value) {
    if (!value?.type) return words('运行时默认', 'Runtime default');
    return [value.type, value.profile, value.file || value.dotCodexFolder].filter(Boolean).join(' · ');
  }
  function open(initialScope = '') {
    if (active) { active.focus(); return; }
    const d = node('dialog', 'picker settings-dialog'); d.id = 'codex-settings-dialog'; active = d;
    d.setAttribute('aria-labelledby', 'codex-settings-heading');
    let data = null, busy = false, stale = false, tab = 'config', skillData = null;
    const controls = new Map();
    const head = node('div', 'picker-head');
    const title = node('h2', '', words('Codex 设置', 'Codex settings')); title.id = 'codex-settings-heading';
    const close = button('×', () => dismiss(), 'icon-button'); close.setAttribute('aria-label', words('关闭设置', 'Close settings'));
    head.append(title, close); d.append(head);
    d.append(node('p', 'settings-note', words('管理 Mac 上 Codex 的默认行为，不中断正在执行的任务。', 'Manage Codex defaults on your Mac without interrupting running tasks.')));
    const scopeLabel = node('label', 'settings-scope', words('配置范围', 'Configuration scope'));
    const scope = node('select'); scope.id = 'codex-settings-scope';
    scope.append(new Option(words('全局默认设置', 'Global defaults'), ''));
    for (const p of window.LinkReading?.projects() || []) if (p.host === 'local' && p.registered) scope.append(new Option(p.name, p.key));
    scope.value = initialScope; if (scope.selectedIndex < 0) scope.value = '';
    scopeLabel.append(scope); d.append(scopeLabel);
    const tabs = node('nav', 'settings-tabs'); tabs.setAttribute('aria-label', words('设置分类', 'Settings sections'));
    const panels = {};
    for (const [key, label] of [['config', words('默认行为', 'Defaults')], ['skills', 'Skills'], ['mcp', 'MCP'], ['connections', words('账号与会话', 'Accounts & chat')]]) {
      tabs.append(button(label, () => showTab(key)));
      panels[key] = node('section', 'settings-panel'); panels[key].dataset.panel = key; panels[key].hidden = key !== tab;
    }
    d.append(tabs);
    const status = node('p', 'settings-status'); status.id = 'codex-settings-status'; status.setAttribute('role', 'status');
    const error = node('p', 'error'); error.id = 'codex-settings-error'; error.setAttribute('role', 'alert');
    d.append(status, error, ...Object.values(panels));
    const footer = node('div', 'settings-footer');
    const refresh = button(words('重新读取', 'Reload'), () => reload()); refresh.id = 'codex-settings-reload';
    const save = button(words('保存更改', 'Save changes'), () => run(submit), 'primary'); save.id = 'codex-settings-save'; save.disabled = true;
    footer.append(refresh, save); d.append(footer); document.body.append(d);
    function changes() {
      const result = {};
      if (!data || data.scope.key) return result;
      for (const [key, control] of controls) {
        const value = control.value === '' ? null : control.value;
        if (data.fields[key].editable && value !== data.fields[key].value) result[key] = value;
      }
      return result;
    }
    function sync() { save.disabled = busy || stale || !data?.writable || !Object.keys(changes()).length; }
    async function discard() {
      return !Object.keys(changes()).length || await confirm(words('放弃未保存的更改？', 'Discard unsaved changes?'),
        words('当前草稿尚未写入 Mac。', 'This draft has not been saved to your Mac.'), words('放弃更改', 'Discard'));
    }
    async function dismiss() { if (!busy && await discard()) d.close(); }
    d.addEventListener('cancel', e => { e.preventDefault(); dismiss(); });
    d.addEventListener('close', () => { d.remove(); active = null; }, {once: true});
    async function run(action) {
      if (busy) return;
      busy = true; error.textContent = ''; d.setAttribute('aria-busy', 'true');
      const previous = [...d.querySelectorAll('button,input,select,textarea')].map(n => [n, n.disabled]);
      previous.forEach(([n]) => n.disabled = true);
      try { await action(); } catch (e) { error.textContent = e.message; }
      finally { busy = false; d.removeAttribute('aria-busy'); previous.forEach(([n, disabled]) => { if (n.isConnected) n.disabled = disabled; }); sync(); }
    }
    function render() {
      const panel = panels.config; panel.replaceChildren(); controls.clear();
      panel.append(node('p', 'settings-note', data.notice));
      if (data.reason) panel.append(node('p', 'settings-readonly', data.reason));
      const sections = [
        [words('模型与推理', 'Model & reasoning'), ['model', 'model_reasoning_effort', 'model_reasoning_summary', 'model_verbosity']],
        [words('搜索与执行权限', 'Search & execution permissions'), ['web_search', 'approval_policy', 'sandbox_mode']],
        [words('指令', 'Instructions'), ['developer_instructions']],
      ];
      for (const [heading, keys] of sections) {
        const group = node('fieldset', 'settings-group'); group.append(node('legend', '', heading));
        for (const key of keys) {
          const field = data.fields[key]; if (!field) continue;
          const row = node('div', 'settings-field');
          const label = node('label', '', words(...labels[key])); label.htmlFor = 'setting-' + key;
          let input;
          if (field.kind === 'choice') {
            input = node('select'); input.append(new Option(words('继承 / 运行时默认', 'Inherit / runtime default'), ''));
            for (const value of field.choices) input.append(new Option(optionLabels[value] ? words(...optionLabels[value]) : value, value));
            const value = data.scope.key ? field.effective : field.value;
            if (value && !field.choices.includes(value)) input.append(new Option(value, value));
          } else {
            input = node(field.kind === 'multiline' ? 'textarea' : 'input');
            input.placeholder = words('留空则继承默认值', 'Leave empty to inherit');
            if (key === 'model') { input.setAttribute('list', 'codex-settings-models'); input.autocapitalize = 'none'; input.spellcheck = false; input.maxLength = 200; }
            else if (key === 'model_reasoning_effort') { input.setAttribute('list', 'codex-settings-efforts'); input.maxLength = 80; }
            else { input.rows = 5; input.maxLength = 32768; }
          }
          input.id = 'setting-' + key; input.value = (data.scope.key ? field.effective : field.value) ?? '';
          input.disabled = !field.editable; input.addEventListener('input', sync); input.addEventListener('change', sync); controls.set(key, input);
          const reset = button(words('继承', 'Inherit'), () => { input.value = ''; sync(); }, 'plain settings-reset'); reset.disabled = !field.editable;
          const headingRow = node('div', 'settings-field-head'); headingRow.append(label, reset); row.append(headingRow, input);
          const details = node('details', 'settings-effective');
          details.append(node('summary', '', words('生效值与来源', 'Effective value & source')),
            node('pre', '', field.structured ? words('高级结构化设置（请在 Mac 管理）', 'Structured setting (manage on Mac)') : field.effective ?? words('运行时默认', 'Runtime default')),
            node('p', '', source(field.origin)));
          row.append(details);
          if (field.reason && field.reason !== data.reason) row.append(node('p', 'settings-note', field.reason));
          if (key === 'model_reasoning_effort' && field.kind === 'text') row.append(node('p', 'settings-note', words('由模型决定。可读取模型目录获取建议，或输入供应商支持的强度 ID。', 'Model-dependent. Load the catalog for suggestions, or enter a provider-supported effort ID.')));
          group.append(row);
        }
        panel.append(group);
        if (keys.includes('model')) {
          const list = node('datalist'); list.id = 'codex-settings-models'; panel.append(list);
          const efforts = node('datalist'); efforts.id = 'codex-settings-efforts'; panel.append(efforts);
          const models = button(words('读取可用模型', 'Load available models'), () => run(async () => {
            status.textContent = words('正在读取模型目录…', 'Loading model catalog…');
            const result = await api(endpoint + '/models'); list.replaceChildren();
            for (const row of result.models) list.append(new Option(row.name, row.id));
            function suggestEfforts() {
              const chosen = controls.get('model').value || data.fields.model.effective;
              efforts.replaceChildren(...(result.models.find(m => m.id === chosen)?.efforts || []).map(value => new Option(value, value)));
            }
            controls.get('model').addEventListener('input', suggestEfforts); suggestEfforts();
            status.textContent = result.notice + ' (' + result.models.length + (result.hasMore ? '+' : '') + ')';
          })); models.disabled = !data.capabilities.models; models.id = 'codex-settings-load-models'; panel.append(models);
        }
      }
      const layers = node('details', 'settings-effective'); layers.append(node('summary', '', words('配置层与运行时', 'Layers & runtime')));
      layers.append(node('p', '', data.runtimeVersion), node('p', '', 'Provider: ' + (data.provider || 'default')));
      for (const layer of data.layers) layers.append(node('p', '', source(layer) + (layer.disabled ? words('（已禁用）', ' (disabled)') : '')));
      panel.append(layers); sync();
    }
    async function read(key) {
      status.textContent = words('正在读取 Mac 配置…', 'Reading Mac configuration…');
      const result = await api(endpoint + '?' + new URLSearchParams({scope: key}));
      data = result; stale = false; scope.value = key; skillData = null;
      render(); showSkillIntro(); status.textContent = result.writable ? words('已读取；修改后点击保存。', 'Loaded. Save when ready.') : words('当前范围只读', 'This scope is read-only');
    }
    async function reload() {
      if (busy || (tab === 'config' && !await discard())) return;
      await run(() => tab === 'mcp' ? loadMcp() : tab === 'skills' ? loadSkills() : read(scope.value));
    }
    scope.onchange = async () => {
      const next = scope.value; scope.value = data?.scope.key ?? '';
      if (busy || !await discard()) return;
      await run(() => read(next)); showTab('config');
    };
    async function submit() {
      const dirty = changes(); if (!Object.keys(dirty).length || stale) return;
      const permission = ['approval_policy', 'sandbox_mode'].filter(key => key in dirty);
      if (permission.length && !await confirm(words('确认执行权限变更', 'Confirm permission changes'),
        permission.map(key => words(...labels[key]) + ': ' + (dirty[key] ?? words('继承', 'Inherit'))).join('\n') + '\n' +
        words('影响后续会话。完全访问或从不审批可能允许 Codex 无提示地修改文件、运行命令。', 'Affects future sessions. Full access or no approvals may allow file changes and commands without prompting.'), words('确认并保存', 'Confirm & save'))) return;
      status.textContent = words('正在保存并回读…', 'Saving and verifying…');
      try {
        const result = await api(endpoint, {scope: data.scope.key, revision: data.revision, changes: dirty, confirmPermissions: permission.length > 0});
        data = result.settings; render();
        status.textContent = result.status === 'saved_overridden' ? words('已保存，但有更高优先级配置覆盖；请检查生效值。', 'Saved, but higher-priority configuration overrides these values.') : words('已保存并回读确认；未热更新当前会话。', 'Saved and verified. The current conversation was not changed.');
      } catch (e) { stale = true; status.textContent = words('草稿已保留。请重新读取确认 Mac 上的实际值后再保存。', 'Draft retained. Reload to verify the Mac configuration before saving again.'); throw e; }
    }
    function showTab(key) {
      if (busy) return;
      tab = key; Object.entries(panels).forEach(([name, panel]) => panel.hidden = name !== key);
      [...tabs.children].forEach((b, i) => b.setAttribute('aria-pressed', String(Object.keys(panels)[i] === key)));
      save.hidden = key !== 'config'; refresh.hidden = key === 'connections';
    }
    function showSkillIntro() {
      panels.skills.replaceChildren(node('p', 'settings-note', words('列出所选目录可用的 Skills。开关写入全局用户配置，不是仅对这个项目生效。', 'List skills available in this directory. Toggles change user configuration, not only this project.')),
        button(words('读取技能', 'Load skills'), () => run(loadSkills)));
    }
    async function loadSkills() {
      skillData = await api(endpoint + '/skills?' + new URLSearchParams({scope: data?.scope.key ?? scope.value})); renderSkills();
    }
    function renderSkills() {
      const panel = panels.skills; panel.replaceChildren(node('p', 'settings-note', skillData.notice));
      if (!skillData.writable) panel.append(node('p', 'settings-readonly', skillData.reason || words('当前技能配置只读；操作未确认时请重新读取。', 'Skill configuration is read-only. Reload after an unconfirmed operation.')));
      if (!skillData.skills.length) panel.append(node('p', 'muted', words('此范围没有可用技能', 'No skills in this scope')));
      for (const skill of skillData.skills) {
        const row = node('article', 'settings-card'); row.append(node('strong', '', skill.name), node('p', '', skill.description), node('small', '', skill.scope + ' · ' + skill.path));
        const toggle = button(skill.enabled ? words('已启用 · 点击禁用', 'Enabled · Disable') : words('已禁用 · 点击启用', 'Disabled · Enable'), () => run(async () => {
          if (!await confirm(words('修改技能开关？', 'Change skill availability?'), skill.name + '\n' + skillData.notice, words('确认修改', 'Confirm'))) return;
          try {
            skillData = await api(endpoint + '/skills', {scope: data?.scope.key ?? scope.value, revision: skillData.revision, path: skill.path, enabled: !skill.enabled, confirmed: true}); renderSkills();
            status.textContent = words('技能开关已回读确认；默认行为页需重新读取。', 'Skill change verified. Reload the defaults page before editing.');
          } catch (e) {
            skillData.writable = false; renderSkills();
            status.textContent = words('操作未确认，请重新读取技能列表后检查。', 'Unconfirmed. Reload the skill list to check its actual state.');
            throw e;
          } finally { stale = true; }
        })); toggle.disabled = !skillData.writable; row.append(toggle); panel.append(row);
      }
    }
    panels.mcp.append(node('p', 'settings-note', words('按需启动设置查询进程并读取 MCP 状态，可能连接配置的 MCP 服务。不调用工具，也不代表桌面当前会话状态。', 'Explicitly query MCP status from a settings process; configured servers may be contacted. No tools are invoked. This is not the current desktop thread status.')),
      button(words('读取 MCP 状态', 'Load MCP status'), () => run(loadMcp)));
    async function loadMcp() {
      const result = await api(endpoint + '/mcp'); panels.mcp.replaceChildren(node('p', 'settings-note', result.notice));
      for (const server of result.servers) {
        const row = node('article', 'settings-card'); row.append(node('strong', '', server.name), node('p', '', server.authStatus + ' · ' + server.toolCount + ' tools' + (server.discoveryError ? words(' · 发现失败', ' · Discovery failed') : ''))); panels.mcp.append(row);
      }
      if (!result.servers.length) panels.mcp.append(node('p', 'muted', words('未配置 MCP 服务', 'No MCP servers configured')));
      if (result.hasMore) panels.mcp.append(node('p', 'muted', words('仅显示前 1000 项', 'Showing the first 1,000 entries')));
    }
    panels.connections.append(node('p', 'settings-note', words('账号沿用原有管理入口；当前会话的模型仍由桌面连接管理，不通过设置查询进程接管。', 'Use the existing account manager. Current-thread models are managed by the desktop connection, never by this settings process.')));
    panels.connections.append(button(words('账号与接入', 'Accounts and providers'), async () => { if (busy || !await discard()) return; d.close(); get('accounts-button').click(); }));
    const current = button(words('当前会话模型', 'Current conversation model'), async () => {
      if (busy || !await discard()) return;
      d.close(); get('model-button').click();
    });
    current.disabled = typeof state === 'undefined' || !state?.connected || state?.readOnly || get('model-button').disabled;
    panels.connections.append(current);
    showSkillIntro(); showTab('config'); d.showModal(); run(() => read(scope.value));
  }
  const entry = button(words('Codex 设置', 'Codex settings'), () => open(), 'plain settings-entry'); entry.id = 'codex-settings-open';
  document.querySelector('.sidebar-foot').prepend(entry);
  const appearance = button(words('Codex 默认行为、Skills 与 MCP →', 'Codex defaults, Skills & MCP →'), () => { get('appearance-dialog').close(); open(); }, 'plain settings-appearance-entry');
  get('appearance-dialog').querySelector('.picker-head').after(appearance);
  new MutationObserver(() => {
    entry.textContent = words('Codex 设置', 'Codex settings');
    appearance.textContent = words('Codex 默认行为、Skills 与 MCP →', 'Codex defaults, Skills & MCP →');
  }).observe(document.documentElement, {attributes: true, attributeFilter: ['lang']});
  window.LinkSettings = {open};
})();
