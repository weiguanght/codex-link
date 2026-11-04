'use strict';
// Presentation only. Reuse existing nodes/listeners, never issue Codex requests.
(() => {
  const get = id => document.getElementById(id);
  const root = document.documentElement;
  const make = (tag, className, text) => {
    const node = document.createElement(tag);
    if (className) node.className = className;
    if (text !== undefined) node.textContent = text;
    return node;
  };
  const paths = {
    terminal: 'm5 7 5 5-5 5m8 0h6',
    plus: 'M12 5v14M5 12h14',
    edit: 'm14 5 5 5M4 20l4-1L20 7a2.8 2.8 0 0 0-4-4L4 15v5Z',
    back: 'm14 5-7 7 7 7',
    refresh: 'M20 7v5h-5M4 17v-5h5M6 7a7 7 0 0 1 12-1l2 6M4 12l2 6a7 7 0 0 0 12-1',
    settings: 'M5 7h14M5 17h14M9 4v6m6 4v6',
    account: 'M20 21a8 8 0 0 0-16 0M16 7a4 4 0 1 1-8 0 4 4 0 0 1 8 0Z',
    bell: 'M18 8a6 6 0 0 0-12 0c0 7-3 7-3 9h18c0-2-3-2-3-9M10 21h4',
  };
  function icon(name) {
    const svg = document.createElementNS('http://www.w3.org/2000/svg', 'svg');
    svg.setAttribute('viewBox', '0 0 24 24');
    svg.setAttribute('fill', 'none');
    svg.setAttribute('stroke', 'currentColor');
    svg.setAttribute('stroke-width', '1.7');
    svg.setAttribute('stroke-linecap', 'round');
    svg.setAttribute('stroke-linejoin', 'round');
    svg.setAttribute('aria-hidden', 'true');
    const path = document.createElementNS(svg.namespaceURI, 'path');
    path.setAttribute('d', paths[name]);
    svg.append(path);
    return svg;
  }
  const labels = [];
  function label(node, zh, en, attribute) {
    labels.push({node, zh, en, attribute});
    // Let this layer own its new copy, not the upstream translation pass.
    node.removeAttribute(attribute ? 'data-i18n-' + attribute : 'data-i18n');
    return node;
  }
  function iconButton(node, name, zh, en) {
    node.replaceChildren(icon(name));
    node.removeAttribute('data-i18n'); // Translation must not replace an icon with a long text label.
    label(node, zh, en, 'aria-label');
    label(node, zh, en, 'title');
    return node;
  }

  // One quiet identity row; language remains available in appearance settings.
  const brand = document.querySelector('.wordmark');
  const mark = make('span', 'link-mark');
  mark.append(icon('terminal'));
  brand.replaceChildren(mark, make('span', 'link-brand-name', 'Codex Link'));
  document.querySelectorAll('[data-open-appearance]').forEach(button =>
    iconButton(button, 'settings', '界面设置', 'Appearance'));
  iconButton(get('refresh'), 'refresh', '刷新会话列表', 'Refresh conversations');
  iconButton(get('new-chat'), 'edit', '新建会话', 'New conversation');
  iconButton(get('back'), 'back', '返回会话列表', 'Back to conversations');
  iconButton(get('attach-button'), 'plus', '添加文件或图片', 'Add files or images');
  label(document.querySelector('.list-heading h2'), '工作空间', 'Workspace');

  // These buttons operate the original list-mode select, preserving persistence.
  const tabs = make('nav', 'link-list-tabs');
  label(tabs, '会话显示方式', 'Conversation view', 'aria-label');
  const mode = get('list-mode');
  const tabButtons = ['recent', 'project'].map((value, i) => {
    const button = make('button', 'link-list-tab');
    button.type = 'button';
    button.dataset.mode = value;
    label(button, i ? '项目' : '最近', i ? 'Projects' : 'Recent');
    button.onclick = () => {
      mode.value = value;
      mode.dispatchEvent(new Event('change', {bubbles: true}));
    };
    tabs.append(button);
    return button;
  });
  const filters = document.querySelector('.list-filters');
  filters.prepend(tabs);
  const listCaption = make('div', 'link-list-caption');
  const listTitle = make('span');
  const loadedCount = make('span');
  listCaption.append(listTitle, loadedCount);
  get('sessions').before(listCaption);
  label(get('sessions'), '会话列表', 'Conversations', 'aria-label');

  // Keep opt-in home shortcuts, but use quiet, labelled icon controls.
  const footer = document.querySelector('.sidebar-foot');
  const extras = make('fieldset', 'appearance-section link-access-settings');
  extras.append(label(make('legend'), '网关与账号', 'Gateway & accounts'));
  const extraActions = make('div', 'link-access-actions');
  extraActions.append(get('logout'));
  extras.append(extraActions);
  document.querySelector('.appearance-actions').before(extras);
  const footerCopy = label(make('span'), '在 Mac 上执行', 'Runs on Mac');
  const accounts = iconButton(get('accounts-button'), 'account', '账号与接入', 'Accounts and providers');
  const notifications = iconButton(get('pushplus-settings'), 'bell', 'PushPlus 通知', 'PushPlus notifications');
  footer.replaceChildren(footerCopy, accounts, notifications);
  // AccountPanel rewrites this button's text after asynchronous refreshes.
  // Preserve its status as an accessible name while keeping the compact icon.
  new MutationObserver(() => {
    if (accounts.querySelector('svg')) return;
    const status = accounts.textContent.trim();
    if (status) {
      accounts.setAttribute('aria-label', status);
      accounts.title = status;
    }
    accounts.replaceChildren(icon('account'));
  }).observe(accounts, {childList: true, characterData: true, subtree: true});

  // Prioritize appearance rather than advanced notification configuration.
  const appearance = get('appearance-dialog');
  label(appearance.querySelector('.conversation-options .appearance-note'),
    '关闭执行过程可专注回复；错误和待确认请求仍会显示。',
    'Hide execution details to focus on replies; errors and pending requests remain visible.');
  appearance.querySelector('.picker-head').after(appearance.querySelector('.appearance-grid'), appearance.querySelector('.conversation-options'));
  const advanced = make('details', 'link-advanced-settings');
  advanced.append(label(make('summary'), '更多设置', 'More settings'));
  advanced.append(get('appearance-pushplus').closest('fieldset'), get('notification-requests').closest('fieldset'), get('appearance-activity').closest('fieldset'), extras);
  appearance.querySelector('.appearance-actions').before(advanced);

  const welcome = get('welcome');
  const welcomeIcon = make('div', 'link-welcome-icon');
  welcomeIcon.append(icon('terminal'));
  welcome.querySelector('img').replaceWith(welcomeIcon);
  label(welcome.querySelector('h1'), '把工作接着做下去', 'Pick up where you left off');
  label(welcome.querySelector('p'), '打开一条会话，继续 Mac 上的思路。', 'Open a conversation and continue on your Mac.');
  const welcomeNew = label(make('button', 'primary link-welcome-new'), '新建会话', 'New conversation');
  welcomeNew.type = 'button';
  welcomeNew.onclick = () => get('new-chat').click();
  welcome.append(welcomeNew);
  const subtitle = make('div', 'link-chat-subtitle');
  document.querySelector('.chat-info').append(subtitle);

  // A model/mode row + one capsule prompt. Retain the original form, all IDs,
  // draft handling, attachment input, goal/stop/send controls and event handlers.
  const tools = document.querySelector('.composer-tools');
  tools.insertBefore(get('work-mode'), get('composer-toggle'));
  const body = get('composer-body');
  const goalToggle = get('goal-toggle');
  for (const [id, choices] of Object.entries({
    'work-mode': {default: ['普通模式', 'Default'], plan: ['计划模式', 'Plan'], goal: ['目标模式', 'Goal']},
    'send-mode': {send: ['发送新消息', 'Send message'], queue: ['完成后发送', 'Queue message'], steer: ['补充当前任务', 'Steer task']},
  })) {
    for (const [value, names] of Object.entries(choices)) label(get(id).querySelector(`[value="${value}"]`), ...names);
  }
  const prompt = make('div', 'link-prompt');
  prompt.append(get('attach-button'), get('message'), document.querySelector('.compose-actions'));
  const options = make('div', 'link-composer-options');
  options.append(get('send-mode'), get('skills-button'), get('notify-button'), goalToggle);
  body.append(prompt, options);
  label(get('message'), '向 Codex 提问，或继续当前任务…', 'Ask Codex or continue your task…', 'placeholder');

  // The upstream changes send text while queueing/steering. Keep that changing
  // accessible name, even though the visual control is a round arrow button.
  function actionLabels() {
    for (const id of ['send', 'stop']) {
      const button = get(id);
      const name = button.textContent.trim();
      button.setAttribute('aria-label', name);
      button.title = name;
    }
  }
  for (const id of ['send', 'stop']) {
    new MutationObserver(actionLabels).observe(get(id), {childList: true, characterData: true, subtree: true});
  }

  // One action in the prompt: stop an active task, or send the current draft.
  // Attachments count as draft content, including while they are uploading.
  function composerAction() {
    const hasContent = !!get('message').value.trim() || attachments.rows.length > 0;
    const showStop = state?.status === 'active' && state.connected && !state.readOnly && !hasContent;
    const send = get('send'), stop = get('stop');
    const disabled = !hasContent || !currentId || !state || state.readOnly || state.loadingHistory || state.activating || sending || !attachments.ready();
    // Write only changes: upstream also updates these attributes during sends,
    // state refreshes and draft restoration, which this observer reconciles.
    if (send.hidden !== !!showStop) send.hidden = !!showStop;
    if (stop.hidden !== !showStop) stop.hidden = !showStop;
    if (send.disabled !== !!disabled) send.disabled = !!disabled;
  }
  get('message').addEventListener('input', composerAction);
  const composerObserver = new MutationObserver(composerAction);
  composerObserver.observe(get('send'), {attributes: true, attributeFilter: ['disabled', 'hidden']});
  composerObserver.observe(get('stop'), {attributes: true, attributeFilter: ['hidden']});
  composerObserver.observe(get('attachment-list'), {childList: true, subtree: true});
  composerObserver.observe(get('composer'), {attributes: true, attributeFilter: ['hidden']});
  composerAction();

  function listState() {
    const english = root.lang.startsWith('en');
    const rows = get('sessions').querySelectorAll('.session');
    for (const button of tabButtons) button.setAttribute('aria-pressed', String(button.dataset.mode === mode.value));
    listTitle.textContent = mode.value === 'project' ? (english ? 'BY PROJECT' : '按项目浏览') : (english ? 'CONVERSATIONS' : '会话记录');
    loadedCount.textContent = window.LinkReading?.summary() || (english ? `${rows.length} loaded` : `已加载 ${rows.length} 条`);
    for (const group of get('sessions').querySelectorAll('.project-group')) {
      group.querySelector('summary').dataset.count = String(group.querySelectorAll('.session').length);
    }
    const selected = get('sessions').querySelector('.session.selected small span');
    subtitle.textContent = selected?.textContent || (english ? 'Codex conversation' : 'Codex 会话');
  }
  function relabel() {
    const english = root.lang.startsWith('en');
    document.title = 'Codex Link';
    for (const {node, zh, en, attribute} of labels) {
      if (attribute) node.setAttribute(attribute, english ? en : zh);
      else node.textContent = english ? en : zh;
    }
    listState();
    actionLabels();
  }
  // Observe the rendered collection only, not conversations or message bodies.
  new MutationObserver(listState).observe(get('sessions'), {childList: true, subtree: true, attributes: true, attributeFilter: ['class']});
  new MutationObserver(listState).observe(get('chat-title'), {childList: true, characterData: true, subtree: true});
  new MutationObserver(relabel).observe(root, {attributes: true, attributeFilter: ['lang']});
  mode.addEventListener('change', listState);

  // Follow the visible keyboard viewport without changing pinch-zoom behavior.
  function viewport() {
    const view = window.visualViewport;
    if (view && Math.abs(view.scale - 1) < .01) root.style.setProperty('--link-viewport-height', `${view.height}px`);
  }
  window.visualViewport?.addEventListener('resize', viewport);
  window.addEventListener('resize', viewport);
  root.classList.add('link-ui');
  relabel();
  viewport();
  window.BridgePresentation?.resizeMessage();
})();
