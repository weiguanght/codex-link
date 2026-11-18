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
  const sections = [
    ['模型与推理', 'Models & reasoning', {
      model: ['默认模型', 'Default model'], review_model: ['代码审查模型', 'Review model'], service_tier: ['服务档位', 'Service tier'],
      model_reasoning_effort: ['推理强度', 'Reasoning effort'], plan_mode_reasoning_effort: ['计划模式推理强度', 'Plan mode reasoning effort'],
      model_reasoning_summary: ['推理摘要', 'Reasoning summary'], model_verbosity: ['回答详略', 'Response verbosity'],
      personality: ['交流风格', 'Personality'], model_context_window: ['上下文窗口（Token）', 'Context window (tokens)'],
      model_auto_compact_token_limit: ['自动压缩阈值（Token）', 'Auto-compaction limit (tokens)'],
      model_auto_compact_token_limit_scope: ['自动压缩范围', 'Auto-compaction scope'],
      model_post_turn_compact_threshold_percent: ['回合结束压缩阈值（%）', 'End-of-turn compaction threshold (%)'],
    }],
    ['权限与沙盒', 'Permissions & sandbox', {
      approval_policy: ['审批策略', 'Approval policy'], approvals_reviewer: ['由谁审核', 'Approvals reviewer'],
      sandbox_mode: ['执行沙盒', 'Execution sandbox'], allow_login_shell: ['允许使用登录 Shell', 'Allow login shell'],
    }],
    ['指令与记忆', 'Instructions & memory', {
      developer_instructions: ['开发者指令', 'Developer instructions'], instructions: ['系统指令', 'System instructions'], compact_prompt: ['上下文压缩指令', 'Compaction prompt'],
      project_doc_max_bytes: ['项目指令读取上限（字节）', 'Project instructions limit (bytes)'],
      project_doc_fallback_filenames: ['候补指令文件名', 'Fallback instruction filenames'],
      include_permissions_instructions: ['注入权限说明', 'Include permission instructions'],
      include_environment_context: ['注入工作环境', 'Include working environment'],
      include_environment_context_time: ['注入当前日期与时区', 'Include date and time zone'],
      include_apps_instructions: ['注入应用指令', 'Include app instructions'],
      include_collaboration_mode_instructions: ['注入协作模式指令', 'Include collaboration mode instructions'],
      'features.memories': ['启用记忆', 'Enable memory'], 'memories.generate_memories': ['生成记忆', 'Generate memories'],
      'memories.use_memories': ['使用记忆', 'Use memories'],
      'memories.disable_on_external_context': ['使用外部上下文时停用记忆', 'Disable memory with external context'],
      'memories.extract_model': ['提取模型', 'Extraction model'],
      'memories.consolidation_model': ['整理模型', 'Consolidation model'],
      'memories.max_raw_memories_for_consolidation': ['整理时读取的记忆上限', 'Max memories read per consolidation'],
      'memories.max_rollout_age_days': ['参与整理的会话时效（天）', 'Max age of sessions to consolidate (days)'],
      'memories.max_unused_days': ['未使用记忆保留时长（天）', 'Unused memory retention (days)'],
      'memories.max_rollouts_per_startup': ['每次启动处理的会话上限', 'Max sessions processed per startup'],
      'memories.min_rollout_idle_hours': ['会话整理前最短空闲时间（小时）', 'Min idle time before consolidation (hours)'],
      'memories.min_rate_limit_remaining_percent': ['整理所需最低剩余额度（%）', 'Min remaining quota for consolidation (%)'],
    }],
    ['代理与目标', 'Agents & goals', {
      'agents.enabled': ['启用子代理', 'Enable subagents'],
      'agents.default_subagent_model': ['子代理默认模型', 'Default subagent model'],
      'agents.default_subagent_reasoning_effort': ['子代理默认推理强度', 'Default subagent reasoning effort'],
      'agents.max_concurrent_threads_per_session': ['单会话并发上限', 'Subagent concurrency per session'],
      'agents.max_depth': ['最大嵌套层数（V1）', 'Max nesting depth (V1)'],
      'agents.interrupt_message': ['记录子代理回合中断提示', 'Record interruptions of subagent turns'],
      'goals.max_goal_token_budget': ['目标预算上限（Token）', 'Max goal budget (tokens)'],
    }],
    ['工具与终端', 'Tools & terminal', {
      web_search: ['联网搜索', 'Web search'], tool_output_token_limit: ['工具输出上限（Token）', 'Tool output limit (tokens)'],
      background_terminal_max_timeout: ['后台终端等待上限（毫秒）', 'Background terminal polling limit (ms)'],
    }],
    ['CLI 输入历史', 'CLI input history', {
      'history.persistence': ['保存方式', 'Persistence'], 'history.max_bytes': ['历史文件上限（字节）', 'Max history size (bytes)'],
    }],
    ['项目与运行时', 'Projects & runtime', {
      project_root_markers: ['项目根目录标记', 'Project root markers'],
      check_for_update_on_startup: ['启动时检查更新', 'Check for updates at startup'],
      thread_unload_delay_secs: ['空闲会话卸载延迟（秒）', 'Idle thread unload delay (seconds)'],
      'analytics.enabled': ['分析遥测', 'Analytics'], 'feedback.enabled': ['允许提交反馈', 'Allow feedback'],
    }],
    ['Codex CLI 界面', 'Codex CLI interface', {
      'tui.animations': ['动画', 'Animations'], 'tui.show_tooltips': ['显示操作提示', 'Show tooltips'],
      'tui.collapse_turn_details': ['折叠回合详情', 'Collapse turn details'],
      'tui.sidebar_width_percent': ['侧栏宽度（%）', 'Sidebar width (%)'],
      file_opener: ['文件链接打开方式', 'File link opener'], hide_agent_reasoning: ['隐藏推理摘要', 'Hide reasoning summaries'],
      show_raw_agent_reasoning: ['显示原始推理', 'Show raw reasoning'],
    }],
  ];
  const labels = Object.assign({}, ...sections.map(([, , fields]) => fields));
  const fieldValue = field => field.effective ?? field.value;
  const inputValue = field => {
    const value = fieldValue(field);
    return Array.isArray(value) ? JSON.stringify(value) : String(value ?? '');
  };
  function stringList(value) {
    try {
      const parsed = JSON.parse(value);
      if (Array.isArray(parsed) && parsed.every(item => typeof item === 'string')) return parsed;
    } catch {}
    return undefined;
  }
  const optionLabels = {
    true: ['开启', 'On'], false: ['关闭', 'Off'], none: ['无', 'None'], 'save-all': ['全部保存', 'Save all'],
    default: ['标准', 'Standard'], fast: ['快速', 'Fast'], priority: ['快速', 'Fast'], flex: ['灵活', 'Flex'],
    user: ['用户', 'User'], auto_review: ['自动审核', 'Auto review'], guardian_subagent: ['审核子代理', 'Review subagent'],
    total: ['完整上下文', 'Entire context'], body_after_prefix: ['仅计算前缀后的内容', 'Content after prefix'],
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
    for (const [key, label] of [['config', words('默认行为', 'Defaults')], ['skills', 'Skills'], ['mcp', 'MCP'], ['reference', words('全部配置项', 'Configuration index')], ['connections', words('账号与会话', 'Accounts & chat')]]) {
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
        const field = data.fields[key];
        if (!field.editable || control.value === inputValue(field)) continue;
        let value = control.value === '' ? null : control.value;
        if (value !== null && field.kind === 'boolean') value = value === 'true';
        if (value !== null && field.kind === 'integer') value = control.valueAsNumber;
        if (value !== null && field.kind === 'string-list') value = stringList(value) ?? value;
        result[key] = value;
      }
      return result;
    }
    function sync() {
      save.disabled = busy || stale || !data?.writable || !Object.keys(changes()).length
        || [...controls.values()].some(control => !control.validity.valid);
    }
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
      for (const [zh, en, fields] of sections) {
        const group = node('fieldset', 'settings-group'); group.append(node('legend', '', words(zh, en)));
        for (const [key, title] of Object.entries(fields)) {
          const field = data.fields[key];
          if (!field || field.supported === false) continue;
          const row = node('div', 'settings-field');
          const label = node('label', 'settings-field-head', words(...title)); label.htmlFor = 'setting-' + key;
          let input;
          if (field.kind === 'choice' || field.kind === 'boolean') {
            const choices = field.kind === 'boolean' ? ['true', 'false'] : field.choices;
            input = node('select'); input.append(new Option(words('默认', 'Default'), ''));
            for (const value of choices) input.append(new Option(optionLabels[value] ? words(...optionLabels[value]) : value, value));
            const value = fieldValue(field);
            if (value !== null && !choices.includes(String(value))) input.append(new Option(String(value), String(value)));
          } else {
            input = node(['multiline', 'string-list'].includes(field.kind) ? 'textarea' : 'input');
            input.placeholder = words('默认', 'Default');
            if (field.kind === 'integer') {
              input.type = 'number'; input.step = '1'; input.min = field.minimum; input.max = field.maximum;
            } else if (field.kind === 'string-list') {
              input.rows = 2;
              input.placeholder = '[".git", "Package.swift"]';
              input.addEventListener('input', () => input.setCustomValidity(
                !input.value || stringList(input.value) ? '' : words('请输入字符串数组', 'Enter an array of strings')
              ));
            } else if (field.kind === 'multiline') {
              input.rows = 4; input.maxLength = 32768;
            } else {
              input.autocapitalize = 'none'; input.spellcheck = false;
              input.maxLength = key.endsWith('_effort') ? 80 : 200;
              if (key === 'model' || key === 'review_model') input.setAttribute('list', 'codex-settings-models');
              if (key.endsWith('_effort')) input.setAttribute('list', 'codex-settings-efforts');
            }
          }
          input.id = 'setting-' + key; input.value = inputValue(field);
          input.disabled = !field.editable; input.addEventListener('input', sync); input.addEventListener('change', sync); controls.set(key, input);
          row.append(label, input);
          if (field.reason && field.reason !== data.reason) row.append(node('p', 'settings-note', field.reason));
          group.append(row);
        }
        if (group.children.length > 1) panel.append(group);
        if (controls.has('model') && Object.hasOwn(fields, 'model')) {
          const list = node('datalist'); list.id = 'codex-settings-models'; panel.append(list);
          const efforts = node('datalist'); efforts.id = 'codex-settings-efforts'; panel.append(efforts);
          const models = button(words('读取可用模型', 'Load available models'), () => run(async () => {
            status.textContent = words('正在读取模型目录…', 'Loading model catalog…');
            const result = await api(endpoint + '/models'); list.replaceChildren();
            for (const row of result.models) list.append(new Option(row.name, row.id));
            function suggestEfforts() {
              const chosen = controls.get('model').value;
              const model = result.models.find(m => chosen ? m.id === chosen : m.isDefault);
              efforts.replaceChildren(...(model?.efforts || []).map(value => new Option(value, value)));
            }
            controls.get('model').addEventListener('input', suggestEfforts); suggestEfforts();
            status.textContent = result.notice + ' (' + result.models.length + (result.hasMore ? '+' : '') + ')';
          })); models.disabled = !data.capabilities.models; models.id = 'codex-settings-load-models'; panel.append(models);
        }
      }
      sync();
    }
    async function read(key) {
      status.textContent = words('正在读取 Mac 配置…', 'Reading Mac configuration…');
      const result = await api(endpoint + '?' + new URLSearchParams({scope: key}));
      data = result; stale = false; scope.value = key; skillData = null;
      render(); showSkillIntro(); status.textContent = result.writable ? words('已读取；修改后点击保存。', 'Loaded. Save when ready.') : words('当前范围只读', 'This scope is read-only');
    }
    async function reload() {
      if (busy || (tab === 'config' && !await discard())) return;
      if (tab === 'reference') { await run(loadReference); return; }
      await run(() => tab === 'mcp' ? loadMcp() : tab === 'skills' ? loadSkills() : read(scope.value));
    }
    scope.onchange = async () => {
      const next = scope.value; scope.value = data?.scope.key ?? '';
      if (busy || !await discard()) return;
      await run(() => read(next)); showTab('config');
    };
    async function submit() {
      const dirty = changes(); if (!Object.keys(dirty).length || stale) return;
      const permission = Object.keys(dirty).filter(key => data.fields[key].confirm || ['approval_policy', 'sandbox_mode'].includes(key));
      if (permission.length && !await confirm(words('确认执行权限变更', 'Confirm permission changes'),
        permission.map(key => words(...labels[key]) + ': ' + (dirty[key] ?? words('默认', 'Default'))).join('\n') + '\n' +
        words('影响后续会话。完全访问或从不审批可能允许 Codex 无提示地修改文件、运行命令。', 'Affects future sessions. Full access or no approvals may allow file changes and commands without prompting.'), words('确认并保存', 'Confirm & save'))) return;
      status.textContent = words('正在保存并回读…', 'Saving and verifying…');
      try {
        const result = await api(endpoint, {scope: data.scope.key, revision: data.revision, changes: dirty, confirmPermissions: permission.length > 0});
        data = result.settings; render();
        status.textContent = result.status === 'saved_overridden' ? words('已保存。部分值受 Mac 配置或策略限制，页面显示当前生效值。', 'Saved. The page shows the values currently applied by your Mac configuration and policies.') : words('已保存并回读确认；未热更新当前会话。', 'Saved and verified. The current conversation was not changed.');
      } catch (e) { stale = true; status.textContent = words('草稿已保留。请重新读取确认 Mac 上的实际值后再保存。', 'Draft retained. Reload to verify the Mac configuration before saving again.'); throw e; }
    }
    function showTab(key) {
      if (busy) return;
      tab = key; Object.entries(panels).forEach(([name, panel]) => panel.hidden = name !== key);
      [...tabs.children].forEach((b, i) => b.setAttribute('aria-pressed', String(Object.keys(panels)[i] === key)));
      save.hidden = key !== 'config'; refresh.hidden = key === 'connections';
      if (key === 'reference' && !panels.reference.childElementCount) run(loadReference);
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
    async function loadReference() {
      const catalog = await api(endpoint + '/reference');
      const search = node('input', 'settings-reference-search');
      search.type = 'search'; search.placeholder = words('搜索 TOML 键或设置名称', 'Search by key or setting');
      search.setAttribute('aria-label', search.placeholder);
      const list = node('div', 'settings-reference-results');
      const version = node('p', 'settings-note', words(
        'Codex ' + catalog.version + ' · ' + catalog.topLevelCount + ' 个一级键',
        'Codex ' + catalog.version + ' · ' + catalog.topLevelCount + ' top-level keys'
      ));
      function renderIndex() {
        const query = search.value.trim().toLowerCase();
        const results = catalog.entries.filter(({key}) => query
          ? key.toLowerCase().includes(query) || (labels[key] || []).some(label => label.toLowerCase().includes(query))
          : !key.includes('.') && !key.includes('[')
        );
        list.replaceChildren();
        for (const result of results.slice(0, 150)) {
          const row = node('details', 'settings-card');
          row.append(node('summary', '', result.key), node('small', '', [...result.types, ...(result.choices || [])].join(' · ')));
          if (controls.has(result.key)) {
            row.append(button(words('定位到设置', 'Open setting'), () => {
              showTab('config'); controls.get(result.key)?.scrollIntoView({block: 'center'});
            }));
          }
          const childPrefix = [result.key + '.', result.key + '['].find(prefix =>
            catalog.entries.some(entry => entry.key.startsWith(prefix)));
          if (childPrefix) {
            row.append(button(words('查看子项', 'Show subkeys'), () => {
              search.value = childPrefix;
              renderIndex();
            }));
          }
          list.append(row);
        }
        if (!results.length) list.append(node('p', 'settings-note', words('没有匹配的配置项。', 'No matching settings.')));
        if (results.length > 150) list.append(node('p', 'settings-note', words('缩小搜索范围以显示其余结果。', 'Refine the search to display more results.')));
      }
      search.addEventListener('input', renderIndex);
      panels.reference.replaceChildren(version, search, list);
      renderIndex();
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
