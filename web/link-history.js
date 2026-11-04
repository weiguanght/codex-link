'use strict';
// First-party reading integration. The original controller handles desktop chats;
// read-only history uses bounded HTTP pages and never activates a Codex owner.
(() => {
  const get = id => document.getElementById(id);
  const baseApi = api, baseOpen = openChat, baseRender = renderState, baseList = renderList;
  const access = new Map();
  let projects = [], total = 0, project = null, selectedProject = null, opening = 0, force = false, loading = false;
  const key = (id, host = 'local') => host + '|' + id;
  const english = () => document.documentElement.lang.startsWith('en');
  const words = (zh, en) => english() ? en : zh;
  const node = (tag, cls, text) => {
    const element = document.createElement(tag);
    if (cls) element.className = cls;
    if (text) element.textContent = text;
    return element;
  };

  const controls = node('div', 'history-filters');
  const scope = node('select');
  scope.id = 'history-scope';
  scope.append(new Option('全部来源', 'all'), new Option('仅桌面会话', 'desktop'));
  const internalLabel = node('label');
  const internal = node('input'); internal.type = 'checkbox'; internal.id = 'history-internal';
  const internalText = node('span');
  internalLabel.append(internal, internalText);
  controls.append(scope, internalLabel);
  document.querySelector('.list-filters').after(controls);
  const projectBack = node('button', 'plain history-project-back');
  projectBack.type = 'button'; projectBack.hidden = true;
  controls.after(projectBack);
  projectBack.onclick = () => { project = null; loadList(true).catch(error => toast(error.message)); };
  for (const input of [scope, internal]) input.onchange = () => { project = null; loadList(true).catch(error => toast(error.message)); };

  const readBar = node('div', 'history-read-bar'); readBar.hidden = true;
  const readLabel = node('span');
  const reload = node('button', 'plain'); reload.type = 'button';
  reload.id = 'history-refresh';
  reload.onclick = () => chatTimeline?.start();
  readBar.append(readLabel, reload);
  get('composer').after(readBar);
  const inspect = node('button', 'plain'); inspect.type = 'button';
  inspect.id = 'history-inspect';
  get('chat-details-dialog').append(inspect);
  inspect.onclick = () => {
    get('chat-details-dialog').close();
    openChat(currentId, currentHost, {history: true}).catch(error => toast(error.message));
  };

  function presentation(readOnly) {
    get('chat').classList.toggle('history-readonly', readOnly);
    get('composer').hidden = readOnly;
    readBar.hidden = !readOnly;
    get('reconnect').hidden = readOnly;
    get('rename-chat').disabled = readOnly;
    inspect.hidden = readOnly || currentHost !== 'local';
    inspect.disabled = !access.get(key(currentId, currentHost))?.historyReadable;
    if (readOnly) {
      get('history').hidden = true;
      get('stop').hidden = true;
      get('send').disabled = true;
      get('status').textContent = words('只读历史', 'Read-only');
    }
  }

  // Defense in depth for the automatic reconnect in upstream openChat(). The
  // server independently rejects ALL writes to non-desktop historical sessions.
  api = async (path, body, signal) => {
    const url = new URL(path, location.origin);
    const match = url.pathname.match(/^\/api\/sessions\/([0-9a-f-]{36})\/(.+)$/);
    if (match && access.get(key(match[1], url.searchParams.get('host') || 'local'))?.readOnly) {
      if (body !== undefined) {
        if (match[2] === 'reconnect') return {ok: true, readOnly: true, connected: false};
        throw Error(words('只读历史不能执行此操作', 'This history is read-only'));
      }
      if (['timeline', 'changes', 'detail'].includes(match[2])) {
        url.pathname = '/api/history/' + match[1] + '/' + match[2];
        path = url.pathname + url.search;
      }
    }
    return baseApi(path, body, signal);
  };

  openChat = async (id, host = 'local', options = {}) => {
    const generation = ++opening;
    const info = await baseApi('/api/session-meta/' + encodeURIComponent(id) + '?host=' + encodeURIComponent(host));
    if (generation !== opening) return;
    if (options.history && host !== 'local') throw Error('SSH 日志视图尚未支持');
    access.set(key(id, host), {...info, readOnly: info.readOnly || !!options.history});
    presentation(info.readOnly || !!options.history);
    await baseOpen(id, host);
  };

  renderState = view => {
    const readOnly = !!view.readOnly || !!access.get(key(currentId, currentHost))?.readOnly;
    if (readOnly) view = {...view, readOnly: true, connected: false, requests: [], submissions: [], goalRuntimeAvailable: false};
    baseRender(view);
    presentation(readOnly);
    if (readOnly) {
      get('notice').hidden = false;
      get('notice-text').textContent = [words('仅阅读日志，不会恢复会话或执行任务。', 'Reading logs only. No session is resumed or task executed.'), ...(view.historyWarnings || [])].join(' ');
    }
  };

  loadList = async (reset = false) => {
    const generation = ++listGeneration;
    if (reset) {
      listOffset = 0; listRows = [];
      window.LinkWorkspace?.resetSelection();
      get('sessions').replaceChildren(node('p', 'muted', words('正在读取会话…', 'Reading conversations…')));
      get('more').hidden = true;
    }
    loading = true;
    get('refresh').disabled = true;
    listQuery = get('search').value;
    const params = new URLSearchParams({q: listQuery, offset: listOffset, archived: get('archived').checked,
      scope: scope.value, internal: internal.checked, refresh: force, ...window.LinkWorkspace?.filters()});
    force = false;
    if (project) params.set('project', project);
    let result;
    try {
      result = await api('/api/sessions?' + params);
    } catch (error) {
      if (generation === listGeneration) {
        get('host-errors').textContent = error.message;
        get('host-errors').hidden = false;
        if (reset) get('sessions').replaceChildren(node('p', 'muted', words('读取失败，请刷新重试。', 'Could not read conversations. Please refresh.')));
      }
      throw error;
    } finally {
      if (generation === listGeneration) { loading = false; get('refresh').disabled = false; }
    }
    if (generation !== listGeneration) return;
    const rows = new Map(listRows.map(row => [key(row.id, row.host), row]));
    for (const row of result.sessions) rows.set(key(row.id, row.host), row);
    listRows = [...rows.values()];
    listOffset += result.sessions.length;
    total = result.total ?? listOffset;
    projects = result.projects || [];
    selectedProject = result.selectedProject || projects.find(item => item.key === project) || null;
    get('more').hidden = result.hasMore === undefined ? result.sessions.length < 100 : !result.hasMore;
    get('host-errors').textContent = [...(result.warnings || []), ...(result.unavailableHosts || []).map(h => h.label + '：' + h.error)].join('\n');
    get('host-errors').hidden = !get('host-errors').textContent;
    renderList();
    refreshActivity();
  };

  renderList = () => {
    // Upstream activity/recency updates also invoke renderList. Keep the user's
    // chosen order and pinned rows instead of letting those updates undo it.
    if (window.LinkWorkspace?.filters().sort === 'title') {
      listRows.sort((a, b) => {
        const left = a.title.toLowerCase(), right = b.title.toLowerCase();
        return left < right ? -1 : left > right ? 1 : 0;
      });
    } else listRows.sort((a, b) => (b.recency || 0) - (a.recency || 0));
    listRows.sort((a, b) => Number(!!b.pinned) - Number(!!a.pinned));
    projectBack.hidden = !project;
    const indexView = get('list-mode').value === 'project' && !project;
    if (indexView && projects.length) {
      get('sessions').replaceChildren();
      for (const item of projects) {
        const button = node('button', 'history-project'); button.type = 'button';
        button.dataset.project = item.key;
        button.append(node('strong', '', item.name), node('span', 'workspace-path', item.cwd || ''), node('small', '', `${item.hostLabel} · ${item.count} ${words('条会话', 'conversations')}`));
        button.onclick = () => { project = item.key; loadList(true).catch(error => toast(error.message)); };
        get('sessions').append(button);
      }
      get('more').hidden = true; // Complete project index, independent of the page.
    } else {
      baseList();
      if (project) get('sessions').querySelectorAll('.project-group').forEach(group => { group.open = true; });
      for (const button of get('sessions').querySelectorAll('.session')) {
        const row = listRows.find(r => r.id === button.dataset.id && r.host === button.dataset.host);
        if (row?.readOnly) {
          const badge = node('span', 'history-badge', row.historyReadable === false ? words('日志缺失', 'Log missing') : words('只读', 'Read-only'));
          button.querySelector('strong').append(badge);
        }
      }
    }
    window.LinkWorkspace?.decorateList();
  };
  get('list-mode').onchange = () => {
    localStorage.setItem('list-mode', get('list-mode').value);
    project = null;
    loadList(true).catch(error => toast(error.message));
  };
  get('refresh').onclick = () => { force = true; loadList(true).catch(error => toast(error.message)); };

  function relabel() {
    scope.options[0].textContent = words('全部来源', 'All sources');
    scope.options[1].textContent = words('仅桌面会话', 'Desktop only');
    scope.setAttribute('aria-label', words('会话来源范围', 'Session source'));
    internalText.textContent = words('内部会话', 'Internal');
    projectBack.textContent = words('‹ 全部项目', '‹ All projects');
    readLabel.textContent = words('只读历史 · 不会执行任务', 'Read-only · No execution');
    reload.textContent = words('刷新历史', 'Refresh history');
    inspect.textContent = words('只读查看完整日志', 'Read the full log (read-only)');
    if (state) presentation(!!state.readOnly);
  }
  window.LinkReading = {
    projects: () => projects,
    selectedProject: () => selectedProject,
    projectKey: () => project,
    readOnlyView: (id, host) => !!access.get(key(id, host))?.readOnly,
    selectProject: key => { project = key; get('list-mode').value = 'project'; return loadList(true); },
    summary: () => loading ? words('正在读取…', 'Reading…') : get('list-mode').value === 'project' && !project && projects.length
      ? `${projects.length} ${words('个项目', 'projects')}`
      : words(`已加载 ${listRows.length} / ${total} 条`, `${listRows.length} / ${total} loaded`),
  };
  new MutationObserver(relabel).observe(document.documentElement, {attributes: true, attributeFilter: ['lang']});
  relabel();

  // On a slow connection the upstream authentication request can finish before
  // this deferred asset arrives. Replace that initial list (generation guarded)
  // so a saved project view still gets the complete index. Never reopen an
  // already running desktop chat just to install the reading layer.
  if (!get('app').hidden) {
    loadList(true).catch(error => toast(error.message));
    const id = currentId, host = currentHost, generation = opening;
    if (id) baseApi('/api/session-meta/' + encodeURIComponent(id) + '?host=' + encodeURIComponent(host))
      .then(info => {
        if (info.readOnly && generation === opening && currentId === id && currentHost === host) return openChat(id, host);
      }).catch(error => toast(error.message));
  }
})();
