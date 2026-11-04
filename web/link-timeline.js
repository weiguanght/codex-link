'use strict';
// Timeline projection adapted from codex-mobile-bridge 1.3.2 (try2love, MIT).
// Keep its cursors and polling; group tool records without changing execution.
(() => {
  const BaseTimeline = ChatTimeline;
  const words = (zh, en) => document.documentElement.lang.startsWith('en') ? en : zh;
  function arrange(parent, children) {
    let position = parent.firstElementChild;
    for (const child of children) {
      if (child === position) position = position.nextElementSibling;
      else parent.insertBefore(child, position);
    }
    while (position) {
      const next = position.nextElementSibling;
      position.remove();
      position = next;
    }
  }

  ChatTimeline = class extends BaseTimeline {
    constructor(options) {
      super(options);
      this.showReasoning = false;
      this.processGroups = [];
      this.processByRow = new Map();
    }

    setVisibility({showProcess}) {
      if (this.showProcess === showProcess) return;
      this.showProcess = showProcess;
      const anchor = this.capture(node => this.rowVisible(this.rows.get(node.dataset.key).row)), bottom = this.following;
      for (const [key, {node}] of this.nodes) node.hidden = !this.rowVisible(this.rows.get(key).row);
      this.groupProcess();
      this.restore(anchor, bottom);
      this.fillRecent();
    }

    apply(page, reset = false, history = false) {
      const anchor = this.capture(), bottom = this.following;
      if (reset) {
        this.generation++;
        this.rows.clear(); this.nodes.clear(); this.details.clear(); this.files.clear();
        this.processGroups = []; this.processByRow.clear();
        this.container.replaceChildren(); this.epoch = page.epoch; this.retryCount = 0;
      }
      for (const file of page.files || []) this.files.set(file.id, file);
      if ((!history && page.sequence >= this.sequence) || reset) {
        this.sequence = page.sequence; this.meta = page.meta;
        this.renderMeta({...page.meta, files: [...this.files.values()]});
      }
      if (!history) this.pendingRequests = !!page.meta.requests?.length;
      let changed = false;
      for (const row of page.rows) {
        if (row.kind === 'reasoning' || row.family === 'reasoning') continue;
        const previous = this.rows.get(row.key);
        if (previous && previous.sequence > page.sequence) continue;
        this.rows.set(row.key, {row, sequence: page.sequence});
        const stamp = JSON.stringify(row), old = this.nodes.get(row.key);
        if (old?.stamp === stamp) continue;
        const node = this.renderRow(row, old?.node.tagName === 'DETAILS' && old.node.open);
        node.dataset.key = row.key; node.hidden = !this.rowVisible(row);
        changed = changed || !node.hidden;
        if (old) old.node.replaceWith(node);
        this.nodes.set(row.key, {node, stamp});
      }
      this.groupProcess();
      if (reset || history) { this.before = page.before; this.hasMore = page.hasMore; this.windowRevision++; }
      this.refreshActions(); this.historyStatus(); this.restore(anchor, bottom);
      if (!history && !bottom && (changed || page.meta.requests?.length)) {
        this.newer.textContent = timelineText(page.meta.requests?.length ? '有待确认请求 ↓' : '有新内容 ↓');
        this.newer.hidden = false;
      }
      if (reset) requestAnimationFrame(() => this.fillRecent());
    }

    createProcessGroup() {
      const node = document.createElement('details'); node.className = 'link-process-group';
      const summary = document.createElement('summary');
      const label = document.createElement('span'); label.className = 'link-process-label';
      const count = document.createElement('span'); count.className = 'link-process-count';
      const status = document.createElement('span'); status.className = 'link-process-status';
      const body = document.createElement('div'); body.className = 'link-process-items';
      summary.append(label, count, status); node.append(summary, body);
      const group = {node, summary, label, count, status, body, rows: []};
      summary.addEventListener('click', () => {
        // Opening a disclosure is an explicit reading action, even at the end.
        const anchor = {key: group.rows[0].key, group: true,
          offset: node.getBoundingClientRect().top - this.viewport.getBoundingClientRect().top};
        this.following = false; this.anchor = anchor;
        requestAnimationFrame(() => this.restore(anchor));
      });
      return group;
    }

    labelProcessGroup(group) {
      group.label.textContent = words('执行过程', 'Tool activity');
      group.count.textContent = words(`${group.rows.length} 项`, `${group.rows.length} ${group.rows.length === 1 ? 'item' : 'items'}`);
      const running = group.rows.some(row => row.status === 'inProgress');
      group.status.hidden = !running;
      group.status.textContent = words('进行中', 'Running');
    }

    groupProcess() {
      const ordered = [...this.rows.values()].map(entry => entry.row).sort((a, b) => a.order - b.order);
      const previous = this.processByRow, groups = [], byRow = new Map(), children = [];
      let run = [];
      const flush = () => {
        if (!run.length) return;
        // A history page can prepend to an existing group; keep the user's
        // open/closed choice by matching any of its stable member keys.
        const group = run.map(row => previous.get(row.key)).find(group => group && !groups.includes(group)) || this.createProcessGroup();
        group.rows = run; group.node.dataset.key = run[0].key;
        group.node.hidden = !run.some(row => this.rowVisible(row));
        this.labelProcessGroup(group);
        arrange(group.body, run.map(row => this.nodes.get(row.key).node));
        for (const row of run) byRow.set(row.key, group);
        groups.push(group); children.push(group.node); run = [];
      };
      for (const row of ordered) {
        if (row.role === 'activity') {
          if (run.length && run[0].turnId !== row.turnId) flush();
          run.push(row);
        } else {
          flush(); children.push(this.nodes.get(row.key).node);
        }
      }
      flush(); arrange(this.container, children);
      this.processGroups = groups; this.processByRow = byRow;
    }

    renderRow(row, open) {
      if (row.role !== 'activity') return super.renderRow(row, open);
      const node = document.createElement('section'); node.className = 'activity timeline-row link-process-item';
      const heading = document.createElement('span'); heading.className = 'link-process-title';
      heading.textContent = (row.title || row.kind) + (row.status === 'inProgress' ? timelineText(' · 进行中') : '');
      const body = document.createElement('pre'); body.className = 'activity-body';
      const more = document.createElement('button'); more.type = 'button'; more.className = 'plain detail-more';
      if (this.details.get(row.key)?.version !== row.version) this.details.delete(row.key);
      const paint = () => {
        const detail = this.details.get(row.key);
        body.textContent = detail?.text ?? row.text;
        more.hidden = detail ? detail.next === null : !row.truncated;
        more.textContent = timelineText(detail ? '继续加载正文' : '展开完整内容');
      };
      more.onclick = async () => {
        if (more.disabled || this.abort.signal.aborted) return;
        const prior = this.details.get(row.key);
        if (prior?.next === null) return;
        const offset = prior?.next || 0;
        more.disabled = true; more.textContent = timelineText('正在读取…');
        try {
          const detail = await this.read('detail', {key: this.epoch + '.' + row.key, offset, version: row.version});
          if (this.abort.signal.aborted || !node.isConnected || this.rows.get(row.key)?.row.version !== row.version) return;
          if (detail.version !== row.version || detail.key !== row.key || detail.offset !== offset) throw Error('stale detail');
          for (const file of detail.files || []) this.files.set(file.id, file);
          this.details.set(row.key, {version: detail.version, text: (offset ? prior?.text || '' : '') + detail.text, next: detail.next});
          paint();
        } catch {
          if (!this.abort.signal.aborted) { more.hidden = false; more.textContent = timelineText('读取失败，点击重试'); }
        } finally { more.disabled = false; }
      };
      node.append(heading, body, more); paint();
      return node;
    }

    capture(accept = () => true) {
      const top = this.viewport.getBoundingClientRect().top, candidates = [];
      for (const node of this.container.children) {
        if (node.hidden || !accept(node)) continue;
        const group = this.processByRow?.get(node.dataset.key);
        if (group?.node === node) {
          candidates.push({node: group.summary, key: node.dataset.key, group: true});
          if (node.open) for (const child of group.body.children) {
            if (!child.hidden && accept(child)) candidates.push({node: child, key: child.dataset.key});
          }
        } else candidates.push({node, key: node.dataset.key});
      }
      const item = candidates.find(item => item.node.getBoundingClientRect().bottom > top) || candidates.at(-1);
      return item ? {key: item.key, group: !!item.group, offset: item.node.getBoundingClientRect().top - top} : null;
    }

    restore(anchor, bottom = false) {
      if (this.abort.signal.aborted) return;
      this.suppress = true;
      const group = anchor && this.processByRow?.get(anchor.key);
      const node = group && (anchor.group || !group.node.open) ? group.node : anchor && this.nodes.get(anchor.key)?.node;
      if (bottom) this.jumpBottom();
      else if (node && !node.hidden) this.viewport.scrollTop += node.getBoundingClientRect().top - this.viewport.getBoundingClientRect().top - anchor.offset;
      this.lastTop = this.viewport.scrollTop; this.anchor = this.capture();
      requestAnimationFrame(() => this.suppress = false);
    }

    relabel() {
      super.relabel();
      for (const group of this.processGroups) this.labelProcessGroup(group);
    }

    fillRecent() {
      const count = [...this.container.children].filter(node => !node.hidden).length;
      // A page may contain only omitted summaries. Still follow its cursor to
      // reach visible messages, including after a reset or a live update.
      if (!this.abort.signal.aborted && count < 20 && !this.retryCount) this.loadOlder(100);
    }
  };
})();
