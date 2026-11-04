'use strict';
// Workspace workflows, deliberately separate from the presentation-only layer.
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
    const n = node('button', cls, label); n.type = 'button';
    n.onclick = () => Promise.resolve().then(action).catch(e => toast(e.message));
    return n;
  };
  const key = row => row.host + '|' + row.id;
  let selecting = false;
  const selected = new Set();
  const baseNew = get('new-chat').onclick;

  function dialog(title, hint = '') {
    const d = node('dialog', 'picker workspace-dialog');
    const heading = node('h2', '', title); heading.id = 'workspace-heading-' + uuid();
    d.setAttribute('aria-labelledby', heading.id);
    const head = node('div', 'picker-head');
    const close = button('×', () => d.close(), 'icon-button');
    close.setAttribute('aria-label', words('关闭', 'Close'));
    head.append(heading, close); d.append(head);
    if (hint) d.append(node('p', 'muted workspace-hint', hint));
    const error = node('p', 'error'); error.setAttribute('role', 'alert');
    d.append(error); document.body.append(d);
    d.addEventListener('close', () => d.remove(), {once: true});
    let busy = false;
    d.addEventListener('cancel', event => { if (busy) event.preventDefault(); });
    async function run(action) {
      if (busy) return;
      busy = true; error.textContent = '';
      const controls = [...d.querySelectorAll('button,input,select')];
      const disabled = controls.map(n => n.disabled); controls.forEach(n => n.disabled = true);
      try { await action(); }
      catch (e) { error.textContent = e.message; }
      finally { busy = false; controls.forEach((n, i) => n.disabled = disabled[i]); }
    }
    return {d, run, show: () => d.showModal(), add: n => error.before(n)};
  }

  function confirm(title, hint, label, action) {
    const ui = dialog(title, hint);
    ui.add(button(label, () => ui.run(async () => { await action(); ui.d.close(); }), 'primary workspace-confirm'));
    ui.show();
  }

  function field(ui, title, value, id) {
    const label = node('label', 'workspace-field', title);
    const input = node('input'); input.value = value || ''; input.id = id; input.required = true;
    label.append(input); ui.add(label); return input;
  }

  async function copy(text) {
    if (navigator.clipboard?.writeText) { await navigator.clipboard.writeText(text); toast(words('已复制', 'Copied')); }
    else { const ui = dialog(words('长按复制', 'Select to copy')); field(ui, '', text, 'workspace-copy'); ui.show(); }
  }

  function browse(onSelect, initial = '') {
    const ui = dialog(words('选择 Mac 文件夹', 'Choose a Mac folder'), words('列出的是 Mac 上的目录，不是手机文件。', 'These folders are on your Mac, not your phone.'));
    const path = field(ui, words('目录路径', 'Directory path'), initial, 'workspace-directory-path');
    const search = field(ui, words('筛选子目录', 'Filter folders'), '', 'workspace-directory-search'); search.required = false;
    const list = node('div', 'workspace-directories');
    let offset = 0, current = initial, parent = null;
    const up = button(words('上一级', 'Parent folder'), () => ui.run(() => read(parent || current)));
    const more = button(words('更多文件夹', 'More folders'), () => ui.run(() => read(current, true)));
    async function read(target, append = false) {
      if (!append) offset = 0;
      const result = await api('/api/workspace/directories?' + new URLSearchParams({path: target || '', offset, q: search.value}));
      current = result.path; parent = result.parent; path.value = current; up.disabled = !parent;
      if (!append) list.replaceChildren();
      for (const row of result.directories) list.append(button('▱  ' + row.name + '  ›', () => ui.run(() => read(row.path))));
      if (!result.directories.length && !append) list.append(node('p', 'muted', words('没有匹配的子目录', 'No matching subfolders')));
      offset += result.directories.length; more.hidden = !result.hasMore;
    }
    ui.add(button(words('前往 / 筛选', 'Go / Filter'), () => ui.run(() => read(path.value))));
    ui.add(up); ui.add(list); ui.add(more);
    ui.add(button(words('使用此文件夹', 'Use this folder'), () => { onSelect(current); ui.d.close(); }, 'primary'));
    ui.show(); ui.run(() => read(initial));
  }

  function projectForm(project = null, startChat = false) {
    const editing = !!project?.registered;
    const ui = dialog(editing ? words('修改项目显示名称', 'Rename project in codex-link') : words('新建项目', 'New project'),
      words('项目登记保存在 codex-link；不会改写 Codex 桌面项目配置，也不会删除文件。', 'Registrations are saved in codex-link. Desktop project settings and files are not removed.'));
    ui.d.id = 'workspace-project-dialog';
    const title = field(ui, words('项目名称', 'Project name'), project?.name, 'workspace-project-name'); title.maxLength = 120;
    const path = field(ui, words('Mac 目录', 'Mac directory'), project?.cwd, 'workspace-project-path'); path.readOnly = editing;
    path.placeholder = '/Users/you/Projects/my-project';
    const createLabel = node('label', 'workspace-check');
    const create = node('input'); create.type = 'checkbox'; create.id = 'workspace-create-directory';
    createLabel.append(create, node('span', '', words('目录不存在时创建新文件夹（父目录必须存在）', 'Create a new folder if absent (parent must exist)')));
    if (!editing) {
      ui.add(button(words('浏览 Mac 文件夹…', 'Browse Mac folders…'), () => browse(value => { path.value = value; if (!title.value) title.value = value.split('/').pop(); }, path.value)));
      ui.add(createLabel);
    }
    let attempt = null;
    ui.add(button(words('保存项目', 'Save project'), () => ui.run(async () => {
      if (!title.reportValidity() || !path.reportValidity()) return;
      const content = JSON.stringify([title.value.trim(), path.value.trim(), create.checked]);
      if (!attempt || attempt.content !== content) attempt = {id: uuid(), content};
      const body = editing ? {action: 'update', key: project.key, changes: {name: title.value}} :
        {action: 'create', id: attempt.id, name: title.value, cwd: path.value, createDirectory: create.checked};
      const result = await api('/api/workspace/projects', body);
      ui.d.close(); await window.LinkReading.selectProject(result.project.key);
      if (startChat) await newChat(result.project);
    }), 'primary workspace-project-save'));
    ui.show();
  }

  async function newChat(project = window.LinkReading.selectedProject()) {
    if (project?.hidden) throw Error(words('请先恢复此项目，再新建对话。', 'Restore this project before creating a conversation.'));
    if (project && !project.registered) { projectForm(project, true); return; }
    await baseNew();
    if (project && newChatProjects.some(p => p.key === project.key)) {
      get('new-chat-project').value = project.key; get('new-chat-project').onchange();
    }
    if (!newChatProjects.length) get('new-chat-error').textContent = words('还没有项目，请先在这里新建项目。', 'No projects yet. Add a project here first.');
  }
  get('new-chat').onclick = () => newChat().catch(e => toast(e.message));
  const createFromChat = button(words('＋ 新建项目', '+ New project'), () => { get('new-chat-dialog').close(); projectForm(null, true); });
  createFromChat.id = 'workspace-project-from-chat'; get('new-chat-path').after(createFromChat);

  function projectMenu(project) {
    const ui = dialog(project.name, project.cwd); ui.d.classList.add('workspace-menu');
    const action = (label, run) => ui.add(button(label, () => { ui.d.close(); return run(); }));
    action(words('新建对话', 'New conversation'), () => newChat(project));
    if (project.registered && project.host === 'local' && window.LinkSettings) action(words('Codex 项目配置（只读）', 'Codex project settings (read-only)'), () => window.LinkSettings.open(project.key));
    if (project.registered) {
      action(words('修改显示名称', 'Rename in codex-link'), () => projectForm(project));
      if (project.host === 'local') action(words('查看 AGENTS.md（只读）', 'View AGENTS.md (read-only)'), async () => {
        const viewer = dialog('AGENTS.md', project.cwd); viewer.show();
        await viewer.run(async () => { const r = await api('/api/workspace/agents?project=' + encodeURIComponent(project.key)); viewer.add(node('pre', 'workspace-file', r.text)); });
      });
      action(project.hidden ? words('恢复项目', 'Restore project') : words('隐藏项目', 'Hide project'), () => confirm(
        project.hidden ? words('恢复项目？', 'Restore project?') : words('隐藏项目？', 'Hide project?'),
        words('仅更改 codex-link 项目列表；不会删除目录、对话或桌面配置。可从“已隐藏”中恢复。', 'Only changes the project list. No directories, conversations or Desktop settings are deleted. Restore from Hidden.'),
        words('确认', 'Confirm'), async () => { await api('/api/workspace/projects', {action: 'update', key: project.key, changes: {hidden: !project.hidden}}); await window.LinkReading.selectProject(null); }));
    } else action(words('添加为项目', 'Register as a project'), () => projectForm(project));
    action(words('复制目录路径', 'Copy directory path'), () => copy(project.cwd));
    ui.show();
  }

  async function preferences(rows, changes) {
    await api('/api/workspace/preferences', {sessions: rows.map(r => ({id: r.id, host: r.host})), changes});
    await loadList(true);
  }

  function archiveRows(rows, archived) {
    confirm(archived ? words('归档对话？', 'Archive conversations?') : words('取消归档？', 'Unarchive conversations?'),
      words(`将修改 Mac 上 ${rows.length} 条桌面会话的归档状态。请先确认任务已结束；不会自动停止任务。`, `Changes ${rows.length} Desktop conversations on the Mac. Finish active tasks first; tasks are not stopped automatically.`),
      words('确认操作', 'Confirm'), async () => {
        let done = 0;
        try {
          for (const row of rows) {
            await api('/api/workspace/archive', {id: row.id, host: row.host, archived, confirmed: true}); done++;
          }
        } catch (error) { throw Error(words(`已确认 ${done}/${rows.length} 条。其余操作未确认，请刷新检查：`, `${done}/${rows.length} confirmed. Check the list before retrying: `) + error.message); }
        finally { await loadList(true); }
      });
  }

  function rename(row) {
    const ui = dialog(words('修改对话名称', 'Rename conversation'), words('修改 Mac 上的桌面会话标题。', 'Changes the Desktop conversation title on the Mac.'));
    const title = field(ui, words('名称', 'Name'), row.title, 'workspace-thread-name'); title.maxLength = 120;
    ui.add(button(words('保存', 'Save'), () => ui.run(async () => {
      if (!title.reportValidity()) return;
      await api('/api/sessions/' + row.id + '/rename?host=' + encodeURIComponent(row.host), {title: title.value});
      ui.d.close(); await loadList(true);
      if (currentId === row.id && currentHost === row.host) { get('chat-title').textContent = title.value; if (state) state.title = title.value; }
    }), 'primary')); ui.show();
  }

  function threadMenu(row) {
    row = {...row, readOnly: row.readOnly || window.LinkReading.readOnlyView(row.id, row.host)};
    const ui = dialog(row.title, row.cwd); ui.d.classList.add('workspace-menu');
    const action = (label, run) => ui.add(button(label, () => { ui.d.close(); return run(); }));
    action(words('打开对话', 'Open conversation'), () => openChat(row.id, row.host));
    if (row.host === 'local' && row.historyReadable !== false) action(words('只读查看日志', 'Read log without activation'), () => openChat(row.id, row.host, {history: true}));
    action(row.pinned ? words('取消置顶', 'Unpin') : words('置顶对话', 'Pin conversation'), () => preferences([row], {pinned: !row.pinned}));
    if (!row.readOnly) action(words('修改对话名称', 'Rename conversation'), () => rename(row));
    if (!row.readOnly && row.host === 'local') action(row.archived ? words('取消归档', 'Unarchive') : words('归档对话', 'Archive conversation'), () => archiveRows([row], !row.archived));
    else ui.add(node('p', 'muted', words('此历史不支持桌面修改；可置顶或隐藏，不改变原始日志。', 'This history cannot be modified through Desktop. Pin or hide without changing logs.')));
    action(row.hidden ? words('恢复到列表', 'Restore to list') : words('从列表隐藏', 'Hide from list'), () => confirm(
      words('整理会话列表', 'Organize conversations'), words('只修改 codex-link 列表，不删除原始对话。可从“已隐藏”中恢复。', 'Only changes the codex-link list. Original conversations are not deleted. Restore from Hidden.'),
      words('确认', 'Confirm'), () => preferences([row], {hidden: !row.hidden})));
    action(words('复制会话 ID', 'Copy conversation ID'), () => copy(row.id));
    ui.show();
  }

  const addProject = button('', () => projectForm()); addProject.id = 'workspace-new-project'; get('refresh').before(addProject);
  const toolbar = node('div', 'workspace-toolbar');
  const sort = node('select'); sort.id = 'workspace-sort';
  sort.append(new Option('', 'updated'), new Option('', 'title'));
  const visibility = node('select'); visibility.id = 'workspace-visibility'; visibility.append(new Option('', 'visible'), new Option('', 'hidden'));
  for (const input of [sort, visibility]) input.onchange = () => loadList(true).catch(e => toast(e.message));
  const select = button('', () => { selecting = !selecting; selected.clear(); options.open = false; renderList(); }); select.id = 'workspace-select';
  toolbar.append(sort, visibility, select); document.querySelector('.history-filters').after(toolbar);
  const context = node('div', 'workspace-context'); toolbar.after(context);
  const options = node('details', 'workspace-options'); options.id = 'workspace-options';
  const optionsTitle = node('summary'); options.append(optionsTitle);
  const optionsBody = node('div', 'workspace-options-body');
  optionsBody.append(get('archived').closest('label'), document.querySelector('.history-filters'), toolbar);
  options.append(optionsBody); document.querySelector('.list-filters').append(options);
  for (const input of [sort, visibility, get('history-scope'), get('history-internal'), get('archived')]) {
    input.addEventListener('change', () => { options.open = false; relabel(); });
  }
  document.addEventListener('pointerdown', event => { if (!options.contains(event.target)) options.open = false; });
  const batch = node('div', 'workspace-batch'); batch.hidden = true; get('sessions').after(batch);
  const chatMenu = button('···', async () => {
    if (!currentId) return;
    const row = await api('/api/session-meta/' + currentId + '?host=' + encodeURIComponent(currentHost));
    threadMenu(row);
  }, 'icon-button'); chatMenu.id = 'workspace-chat-menu'; document.querySelector('.chat-head').append(chatMenu);

  function batchBar() {
    const rows = listRows.filter(r => selected.has(key(r)));
    batch.hidden = !selecting; batch.replaceChildren();
    if (!selecting) return;
    batch.append(node('span', '', words(`已选 ${rows.length}`, `${rows.length} selected`)));
    batch.append(button(words('完成', 'Done'), () => { selecting = false; selected.clear(); renderList(); }));
    batch.append(button(words('选本页', 'Select loaded'), () => { listRows.slice(0, 100).forEach(r => selected.add(key(r))); renderList(); }));
    const commands = [
      [words('置顶', 'Pin'), () => preferences(rows, {pinned: true}), true],
      [visibility.value === 'hidden' ? words('恢复', 'Restore') : words('隐藏', 'Hide'), () => confirm(words('整理所选对话', 'Organize selected'), words('仅影响 codex-link 列表，不删除原始数据。', 'Only affects the list. No original data is deleted.'), words('确认', 'Confirm'), () => preferences(rows, {hidden: visibility.value !== 'hidden'})), true],
      [get('archived').checked ? words('取消归档', 'Unarchive') : words('归档', 'Archive'), () => archiveRows(rows, !get('archived').checked), rows.every(r => !r.readOnly && r.host === 'local')],
    ];
    for (const [label, action, allowed] of commands) {
      const b = button(label, action); b.disabled = !rows.length || !allowed;
      if (!allowed) b.title = words('所选包含只读或 SSH 会话，请使用隐藏', 'Selection contains read-only or SSH history. Use Hide instead.');
      batch.append(b);
    }
  }

  function decorateList() {
    const current = window.LinkReading.selectedProject();
    context.replaceChildren(); context.hidden = !window.LinkReading.projectKey();
    document.querySelector('aside').classList.toggle('workspace-project-open', !context.hidden);
    if (current) {
      context.append(node('strong', '', current.name), node('span', 'workspace-path', current.cwd));
      context.append(button(words('＋ 新建对话', '+ New conversation'), () => newChat(current)), button('···', () => projectMenu(current)));
    }
    for (const item of get('sessions').querySelectorAll('.history-project')) {
      if (item.parentElement.classList.contains('workspace-project-row')) continue;
      const project = window.LinkReading.projects().find(p => p.key === item.dataset.project);
      if (!project) continue;
      const row = node('div', 'workspace-project-row'); item.before(row); row.append(item);
      const menu = button('···', () => projectMenu(project), 'workspace-row-menu'); menu.setAttribute('aria-label', words('项目操作：', 'Project actions: ') + project.name);
      row.append(menu); item.oncontextmenu = event => { event.preventDefault(); projectMenu(project); };
    }
    for (const item of get('sessions').querySelectorAll('.session')) {
      if (item.parentElement.classList.contains('workspace-session-row')) continue;
      const value = listRows.find(r => r.id === item.dataset.id && r.host === item.dataset.host); if (!value) continue;
      const row = node('div', 'workspace-session-row'); item.before(row); row.append(item);
      if (value.pinned) item.querySelector('strong').prepend(node('span', 'workspace-pin', words('置顶 · ', 'Pinned · ')));
      if (selecting) {
        const check = node('input'); check.type = 'checkbox'; check.checked = selected.has(key(value));
        check.setAttribute('aria-label', words('选择：', 'Select: ') + value.title);
        const toggle = () => { if (selected.has(key(value))) selected.delete(key(value)); else if (selected.size < 100) selected.add(key(value)); else toast(words('一次最多选择 100 条', 'Select up to 100 conversations')); renderList(); };
        check.onchange = toggle; row.prepend(check); item.onclick = toggle;
      }
      const menu = button('···', () => threadMenu(value), 'workspace-row-menu'); menu.setAttribute('aria-label', words('会话操作：', 'Conversation actions: ') + value.title);
      row.append(menu); item.oncontextmenu = event => { event.preventDefault(); threadMenu(value); };
    }
    select.textContent = selecting ? words('完成', 'Done') : words('多选', 'Select'); batchBar();
  }
  function relabel() {
    optionsTitle.textContent = get('archived').checked ? words('已归档 ▾', 'Archived ▾') : visibility.value === 'hidden' ? words('已隐藏 ▾', 'Hidden ▾') : words('筛选与排序', 'Filter & sort');
    addProject.textContent = words('＋ 项目', '+ Project'); addProject.setAttribute('aria-label', words('新建项目', 'New project'));
    sort.options[0].textContent = words('最近更新', 'Updated'); sort.options[1].textContent = words('标题排序', 'Title');
    sort.setAttribute('aria-label', words('会话排序', 'Conversation order'));
    visibility.options[0].textContent = words('正常列表', 'Visible'); visibility.options[1].textContent = words('已隐藏', 'Hidden');
    visibility.setAttribute('aria-label', words('列表可见性', 'List visibility'));
    chatMenu.setAttribute('aria-label', words('会话操作', 'Conversation actions'));
    createFromChat.textContent = words('＋ 新建项目', '+ New project'); decorateList();
  }
  window.LinkWorkspace = {
    filters: () => ({sort: sort.value, hidden: visibility.value === 'hidden'}),
    resetSelection: () => { selected.clear(); }, decorateList,
  };
  new MutationObserver(relabel).observe(document.documentElement, {attributes: true, attributeFilter: ['lang']});
  relabel();
  // Repair an initial page rendered before this deferred asset arrived.
  if (!get('app').hidden) renderList();
})();
