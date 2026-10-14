// 设置与代码审查使用独立的 MCP 文档，并可能移到全局嵌入宿主。
// 仅同步页面背景样式，保留控件、代码预览与 diff 配色。
(() => {
  window.__codexboxSkinSettings?.restore();
  const reviewTitle = ':is([title="Code Review" i], [title="代码审查"])';
  const selector = [
    '[data-density][class~="group/settings"] [data-mcp-app-portal-target] [class~="group/mcp-app"] > webview',
    `:is([data-embedded-frame-host-root], [data-mcp-app-portal-target]) [class~="group/mcp-app"] > webview${reviewTitle}`,
  ].join(', ');
  const views = new Map();
  let active = true;

  const remove = async (view, key) => {
    if (key == null) return;
    try { await view.removeInsertedCSS(key); } catch {}
  };
  const backgroundCSS = view => {
    const root = document.documentElement;
    const dark = root.getAttribute('data-theme') === 'dark' ||
      (!root.hasAttribute('data-theme') && root.classList.contains('electron-dark'));
    const glass = getComputedStyle(root).getPropertyValue('--codexbox-skin-glass').trim() ||
      (dark ? 'rgba(18, 20, 20, 0.18)' : 'rgba(248, 250, 249, 0.14)');
    const review = view.matches(reviewTitle);
    const common = `:root {
      --color-background-primary: ${glass} !important;
      --color-background-panel: ${glass} !important;
      ${review ? '' : `--color-surface: ${glass} !important;`}
    }
    html, body, body > :is(#root, #app, main) {
      background: transparent !important;
    }`;
    if (!review) return common;
    // pull-requests.js 的 u0i 外层、主区及 xgo 详情层各自使用 surface。
    // 清理这些页面层，保留代码卡片、弹层及 diff 行自己的背景。
    return `${common}
      #root .relative.flex.h-screen.min-h-0.min-w-0.overflow-hidden.bg-surface:has([data-app-shell-main-surface]),
      [data-app-shell-main-surface],
      [data-app-shell-main-surface] [class*="_WorkspaceContent_"]::before,
      [data-app-shell-main-surface] section.h-full.min-h-0.min-w-0.bg-surface,
      [data-app-shell-main-titlebar],
      [data-app-shell-page-surface] {
        background: transparent !important;
      }`;
  };
  const apply = (view, state, force = false) => {
    const css = backgroundCSS(view);
    if (!force && state.css === css) return;
    state.css = css;
    const revision = ++state.revision;
    state.pending = state.pending.then(async () => {
      if (!active || views.get(view) !== state || state.revision !== revision) return;
      const key = await view.insertCSS(css);
      if (!active || views.get(view) !== state || state.revision !== revision || !view.matches(selector)) {
        await remove(view, key);
        return;
      }
      const previous = state.key;
      state.key = key;
      await remove(view, previous);
    }).catch(() => {
      // 未就绪的 webview 等待 dom-ready；不启动轮询或修改应用外观标记。
      if (state.revision === revision) state.css = null;
    });
  };
  const detach = (view, state) => {
    views.delete(view);
    state.revision++;
    view.removeEventListener('dom-ready', state.ready);
    const key = state.key;
    state.key = null;
    return Promise.all([state.pending, remove(view, key)]);
  };
  const scan = () => {
    if (!active) return;
    for (const [view, state] of views) {
      if (!view.isConnected || !view.matches(selector)) void detach(view, state);
    }
    for (const view of document.querySelectorAll(selector)) {
      if (typeof view.insertCSS !== 'function' || typeof view.removeInsertedCSS !== 'function') continue;
      let state = views.get(view);
      if (!state) {
        state = {key: null, css: null, revision: 0, pending: Promise.resolve(), ready: null};
        state.ready = () => apply(view, state, true);
        views.set(view, state);
        view.addEventListener('dom-ready', state.ready);
      }
      apply(view, state);
    }
  };
  const appearance = new MutationObserver(scan);
  appearance.observe(document.documentElement, {attributes: true, attributeFilter: ['class', 'data-theme']});
  const content = new MutationObserver(records => {
    if (records.some(record => record.type === 'attributes' || [...record.addedNodes, ...record.removedNodes].some(node =>
      node.nodeType === 1 && (node.matches('webview') || node.querySelector('webview'))))) scan();
  });
  content.observe(document.documentElement, {childList: true, subtree: true, attributes: true, attributeFilter: ['title']});
  window.__codexboxSkinSettings = {
    restore() {
      active = false;
      appearance.disconnect();
      content.disconnect();
      return Promise.all([...views].map(([view, state]) => detach(view, state)));
    },
  };
  scan();
})();
