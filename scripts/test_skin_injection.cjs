// 使用隔离 DOM 检查颜色探针、换肤与恢复之间的事件循环。
// 运行：node scripts/test_skin_injection.cjs（先安装 windows 开发依赖）
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { JSDOM } = require('../windows/node_modules/jsdom');
const source = fs.readFileSync(path.join(__dirname, '../codexBar/Services/CodexSkinInjectionService.swift'), 'utf8');
const settingsScript = fs.readFileSync(path.join(__dirname, '../codexBar/Resources/skin-settings-webviews.js'), 'utf8');
const installer = source.slice(source.indexOf('private static func installerJS')).split('return """')[1].split('"""')[0]
  .replace('\\(encoded)', Buffer.from('body { --test: 1; }').toString('base64'))
  .replace('\\(settingsScript)', settingsScript);
const remover = source.slice(source.indexOf('func removeSkin()')).split('let js = """')[1].split('"""')[0];
// 使用生产 CSS 验证主区透明规则，以及运行中切换外观后的匹配。
let css = source.slice(source.indexOf('private func buildCSS')).split('rules.append("""')[1].split('""")')[0]
  .replace(/\\\(Self\.(\w+)\)/g, (_, name) => source.match(new RegExp(`static let ${name} = ([0-9.]+)`))[1])
  .replace('\\(accents.joined(separator: "\\n"))', '');
function verifySurfaces(attribute) {
  const dom = new JSDOM(`<html><head><style>main { background: white; }</style><style>${css}</style></head><body><main class="bg-surface"><main class="_MainContentSurface_newhash_2"></main></main></body></html>`);
  const w = dom.window;
  for (const mode of ['light', 'dark', 'light']) {
    w.document.documentElement.setAttribute(attribute, attribute === 'class' ? `electron-${mode}` : mode);
    const [outer, inner] = w.document.querySelectorAll('main');
    assert.equal(w.getComputedStyle(outer).backgroundColor, 'rgba(0, 0, 0, 0)', `${attribute}/${mode} 外层主区应透明`);
    assert.equal(w.getComputedStyle(inner).backgroundColor, mode === 'light' ? 'rgba(248, 250, 249, 0.1)' : 'rgba(0, 0, 0, 0)', `${attribute}/${mode} 内层主区应使用原有透明度`);
  }
  dom.window.close();
  console.log(`${attribute}：主区背景与连续明暗切换通过`);
}
function verifyCurrentShell() {
  const fixture = require('./fixtures_skin_shell.cjs');
  const dom = new JSDOM(`<html><head><style>
    [data-app-shell-frame], [data-app-shell-main-surface], [data-app-shell-main-titlebar],
    [class~="electron:bg-surface"], .bg-surface-secondary { background: rgb(24, 24, 24); }
    ._PageSurfaceLayout_gs442_2 ._LeftPanel_gs442_2 .sidebar-navigation { background: rgba(24, 24, 24, 0.65); }
    [class~="bg-surface-secondary/40"] { background: rgba(240, 240, 240, 0.4); }
    .sticky.bg-surface { background: rgb(255,255,255); position: sticky; top: 0; }
    .bg-page-search { background: rgb(255,255,255); border: 1px solid gray; }
  </style><style>${css}</style></head><body>${fixture}</body></html>`);
  const w = dom.window;
  for (const mode of ['light', 'dark', 'light']) {
    w.document.documentElement.setAttribute('data-theme', mode);
    for (const id of ['frame', 'titlebar', 'settings', 'app-shell-sidebar', 'sidebar', 'usage-toolbar', 'shortcut-toolbar', 'search-field']) {
      assert.equal(w.getComputedStyle(w.document.getElementById(id)).backgroundColor,
        'rgba(0, 0, 0, 0)', `${mode}/${id} 新版页面背景应透明`);
    }
    for (const id of ['card', 'preview']) {
      assert.equal(w.getComputedStyle(w.document.getElementById(id)).backgroundColor,
        'rgb(24, 24, 24)', `${mode}/${id} 局部内容表面应保留`);
    }
    const scroll = w.document.querySelector('.scrollbar-stable');
    assert.equal(w.getComputedStyle(w.document.getElementById('selected')).backgroundColor,
      'rgba(128, 128, 128, 0.2)', '保留侧栏会话选中态');
    assert.equal(w.getComputedStyle(scroll).height, '120px');
    assert.equal(w.getComputedStyle(scroll).overflowY, 'auto');
    assert.equal(w.getComputedStyle(w.document.getElementById('usage-toolbar')).position, 'sticky');
    assert.equal(w.getComputedStyle(w.document.getElementById('usage-tab')).backgroundColor,
      'rgba(128, 128, 128, 0.2)', '保留概览标签选中态');
    assert.equal(w.getComputedStyle(w.document.getElementById('search-field')).borderTopWidth, '1px', '保留搜索控件边界');
  }
  let clicks = 0;
  w.document.getElementById('toggle').addEventListener('click', () => clicks++);
  w.document.getElementById('toggle').click();
  assert.equal(clicks, 1, '设置控件仍可交互');
  const search = w.document.getElementById('shortcut-search');
  let inputValue;
  search.addEventListener('input', () => { inputValue = search.value; });
  search.value = '复制'; search.dispatchEvent(new w.Event('input', { bubbles: true }));
  assert.equal(inputValue, '复制', '快捷键搜索输入仍正常');
  dom.window.close();
  console.log('新版外壳、设置主区、局部卡片与滚动交互通过');
}
function verifyComposerBackdrop() {
  const dom = new JSDOM(`<html><head><style>
    .from-surface { background: white; background-image: linear-gradient(to top, white, transparent); }
  </style><style>${css}</style></head><body>
    <main class="_MainContentSurface_newhash_2">
      <div aria-hidden="true" style="height: 120px">
        <div id="backdrop" aria-hidden="true" class="pointer-events-none absolute inset-x-0 bottom-0 z-0 h-full bg-gradient-to-t from-surface via-surface"></div>
      </div>
      <div id="composer" class="_ComposerLayoutRoot_newhash_2"><button>发送</button></div>
      <div id="content" class="bg-gradient-to-t from-surface via-surface">内容卡片</div>
    </main>
  </body></html>`);
  const w = dom.window;
  for (const attribute of ['class', 'data-theme']) {
    for (const mode of ['light', 'dark']) {
      const root = w.document.documentElement;
      root.removeAttribute('class'); root.removeAttribute('data-theme');
      root.setAttribute(attribute, attribute === 'class' ? `electron-${mode}` : mode);
      const backdrop = w.document.getElementById('backdrop');
      const style = w.getComputedStyle(backdrop);
      assert.equal(style.backgroundColor, 'rgba(0, 0, 0, 0)', `${attribute}/${mode} 输入框外围底色应透明`);
      assert.equal(style.backgroundImage || 'none', 'none', `${attribute}/${mode} 输入框外围应移除装饰渐变`);
      assert.equal(w.getComputedStyle(backdrop.parentElement).height, '120px', '保留滚动占位高度');
      assert.equal(w.getComputedStyle(w.document.getElementById('composer')).backgroundColor,
        mode === 'light' ? 'rgba(248, 250, 249, 0.76)' : 'rgba(18, 20, 20, 0.16)', '保留输入框玻璃底');
      assert.equal(w.getComputedStyle(w.document.getElementById('content')).backgroundColor, 'rgb(255, 255, 255)', '内容卡片不受装饰层规则影响');
    }
  }
  dom.window.close();
  console.log('输入框外围透明、滚动占位、玻璃底与内容卡片隔离通过');
}
function verifySpaceSettingsSurfaces() {
  const fixture = require('./fixtures_skin_space_settings.cjs');
  const dom = new JSDOM(`<html><head><style>
    .bg-surface, [class~="electron:bg-surface"], .bg-surface-card,
    [class~="bg-surface-secondary/92"], [class~="dark:bg-surface-secondary/92"],
    [class~="bg-(--color-background-primary-soft-alpha)/50"] { background: rgb(255,255,255); }
    .settings-row { border-bottom: 1px solid gray; }
    .sticky { position: sticky; }
    .overflow-y-auto { overflow-y: auto; }
  </style><style>${css}</style></head><body>${fixture}</body></html>`);
  const w = dom.window;
  for (const attribute of ['class', 'data-theme']) {
    for (const mode of ['light', 'dark', 'light']) {
      const root = w.document.documentElement;
      root.removeAttribute('class'); root.removeAttribute('data-theme');
      root.setAttribute(attribute, attribute === 'class' ? `electron-${mode}` : mode);
      const glass = w.getComputedStyle(root).getPropertyValue('--codexbox-skin-glass').trim();
      w.document.querySelector('head style:last-child').textContent = css.replaceAll('var(--codexbox-skin-glass)', glass);
      const normalizedGlass = w.document.createElement('div').style;
      normalizedGlass.backgroundColor = glass;
      for (const id of ['sites-page', 'sites-content', 'sites-tabpanel', 'space-toolbar', 'settings-page']) {
        assert.equal(w.getComputedStyle(w.document.getElementById(id)).backgroundColor,
          'rgba(0, 0, 0, 0)', `${attribute}/${mode}/${id} 空间页面层应透明`);
      }
      assert.equal(w.getComputedStyle(w.document.getElementById('settings-density')).getPropertyValue('--color-background-panel').trim(),
        glass, '设置布局的内联分组变量应使用模式玻璃底');
      for (const id of ['settings-secondary', 'settings-form', 'settings-muted']) {
        assert.equal(w.getComputedStyle(w.document.getElementById(id)).backgroundColor,
          normalizedGlass.backgroundColor, `${attribute}/${mode}/${id} 设置分组应使用模式玻璃底`);
      }
      // jsdom 不计算内联 var 的级联，默认分组的最终背景及标题伪元素另用浏览器验证。
      for (const id of ['site-card', 'site-thumbnail', 'settings-preview']) {
        assert.equal(w.getComputedStyle(w.document.getElementById(id)).backgroundColor,
          'rgb(255, 255, 255)', `${id} 内容预览应保持原有表面`);
      }
      assert.equal(w.getComputedStyle(w.document.getElementById('space-tab')).backgroundColor, 'rgba(128, 128, 128, 0.2)');
      assert.equal(w.getComputedStyle(w.document.getElementById('settings-toggle')).backgroundColor, 'rgb(50, 128, 255)');
      assert.equal(w.getComputedStyle(w.document.querySelector('.settings-row')).borderBottomWidth, '1px');
      assert.equal(w.getComputedStyle(w.document.getElementById('space-toolbar')).position, 'sticky');
      for (const id of ['space-scroll', 'settings-scroll']) assert.equal(w.getComputedStyle(w.document.getElementById(id)).overflowY, 'auto');
      assert.equal(w.getComputedStyle(w.document.getElementById('ordinary-inline-group')).getPropertyValue('--color-background-panel'), '', '普通分组不应套用设置变量');
    }
  }
  let clicks = 0;
  for (const id of ['create-site', 'settings-toggle', 'export-data']) {
    const button = w.document.getElementById(id);
    button.addEventListener('click', () => clicks++); button.click();
  }
  assert.equal(clicks, 3, '创建站点和设置控件仍可交互');
  dom.window.close();
  console.log('空间浏览页、站点页面层、设置分组、连续明暗切换与控件隔离通过');
}
function verifyReviewProfileSurfaces() {
  const fixture = require('./fixtures_skin_review_profile.cjs');
  const dom = new JSDOM(`<html><head><style>
    .bg-surface, [class~="electron:bg-surface"], [class~="bg-surface/80"],
    [class~="group/mcp-app"] { background: rgb(255,255,255); }
    [class*="_showcaseEmptyState_"] { background: rgb(247,247,247); }
    .border-b { border-bottom: 1px solid gray; }
    .overflow-y-auto { overflow-y: auto; }
  </style><style>${css}</style></head><body>${fixture}</body></html>`);
  const w = dom.window;
  for (const attribute of ['class', 'data-theme']) {
    for (const mode of ['light', 'dark', 'light']) {
      const root = w.document.documentElement;
      root.removeAttribute('class'); root.removeAttribute('data-theme');
      root.setAttribute(attribute, attribute === 'class' ? `electron-${mode}` : mode);
      const glass = w.getComputedStyle(root).getPropertyValue('--codexbox-skin-glass').trim();
      w.document.querySelector('head style:last-child').textContent = css.replaceAll('var(--codexbox-skin-glass)', glass);
      const color = w.document.createElement('div').style;
      color.backgroundColor = glass;
      for (const id of ['review-page', 'review-host', 'profile-page', 'profile-settings']) {
        assert.equal(w.getComputedStyle(w.document.getElementById(id)).backgroundColor, 'rgba(0, 0, 0, 0)', `${attribute}/${mode}/${id} 独立页面背景应透明`);
      }
      assert.equal(w.getComputedStyle(w.document.getElementById('profile-header')).backgroundColor, color.backgroundColor, '资料滚动后的标题背景应跟随模式');
      assert.equal(w.getComputedStyle(w.document.getElementById('profile-showcase-empty')).backgroundColor, color.backgroundColor, '精选作品空卡片应透出模式玻璃底');
      assert.equal(w.document.getElementById('profile-activity-chart').matches('[data-profile-scroll] [role="img"][style*="--profile-usage-level-0"]'), true);
      assert.equal(w.getComputedStyle(w.document.getElementById('profile-header')).borderBottomWidth, '1px');
      for (const id of ['profile-content-preview', 'profile-lookalike', 'profile-showcase-site', 'profile-showcase-artwork']) {
        assert.equal(w.getComputedStyle(w.document.getElementById(id)).backgroundColor, 'rgb(255, 255, 255)', `${id} 局部预览和其他页面应保留`);
      }
      for (const id of ['review-scroll', 'profile-page-scroll', 'profile-settings-scroll']) {
        assert.equal(w.getComputedStyle(w.document.getElementById(id)).overflowY, 'auto');
      }
      assert.equal(w.getComputedStyle(w.document.getElementById('profile-avatar')).backgroundColor, 'rgb(205, 243, 255)');
      assert.equal(w.getComputedStyle(w.document.getElementById('profile-activity-cell')).backgroundColor, 'rgb(50, 128, 255)');
      assert.equal(w.getComputedStyle(w.document.getElementById('ordinary-showcase-empty')).backgroundColor, 'rgb(247, 247, 247)');
      assert.equal(w.getComputedStyle(w.document.getElementById('ordinary-activity-chart')).getPropertyValue('--profile-usage-level-0'), 'white');
    }
  }
  // webview 的内联宿主底色由 Chromium 验证；jsdom 不实现跨文档样式或重要性级联。
  dom.window.close();
  console.log('代码审查宿主、个人资料页面与精选作品空卡片、预览隔离、连续明暗切换通过');
}

function verifyReviewWorkspaceSurfaces() {
  const {host} = require('./fixtures_skin_review_workspace.cjs');
  const dom = new JSDOM(`<html><head><style>.bg-surface, [class~="group/mcp-app"] {background:white}</style><style>${css}</style></head><body>${host}</body></html>`);
  const w = dom.window;
  // Chromium 验证内联底色的 !important 级联；jsdom 检查页面范围和选择器。
  for (const id of ['review-workspace-surface', 'review-workspace-host', 'review-inline-host']) w.document.getElementById(id).removeAttribute('style');
  for (const attribute of ['class', 'data-theme']) {
    for (const mode of ['light', 'dark', 'light']) {
      const root = w.document.documentElement;
      root.removeAttribute('class'); root.removeAttribute('data-theme');
      root.setAttribute(attribute, attribute === 'class' ? `electron-${mode}` : mode);
      for (const id of ['review-workspace-surface', 'review-workspace-host', 'review-inline-host']) {
        assert.equal(w.getComputedStyle(w.document.getElementById(id)).backgroundColor, 'rgba(0, 0, 0, 0)', `${attribute}/${mode}/${id} PR 页面及全局宿主应透明`);
      }
      assert.equal(w.getComputedStyle(w.document.getElementById('ordinary-embedded-host')).backgroundColor, 'rgb(255, 255, 255)', '其他嵌入预览宿主保留底色');
    }
  }
  dom.window.close();
  console.log('PR 浏览页、全局与页面内宿主、预览隔离通过');
}

async function verifySettingsWebviews(platform, install, removeSkin) {
  const dom = new JSDOM(`<html data-theme="light"><head></head><body>${require('./fixtures_skin_review_profile.cjs')}${require('./fixtures_skin_review_workspace.cjs').host}</body></html>`, {runScripts: 'outside-only'});
  const w = dom.window;
  w.TextDecoder = TextDecoder;
  const settle = () => new Promise(resolve => w.setTimeout(resolve, 0));
  const mock = view => {
    const styles = new Map();
    let calls = 0;
    view.insertCSS = async css => { const key = `style-${++calls}`; styles.set(key, css); return key; };
    view.removeInsertedCSS = async key => { styles.delete(key); };
    return {styles, calls: () => calls, view};
  };
  const review = mock(w.document.getElementById('review-webview'));
  const preview = mock(w.document.getElementById('settings-preview-webview'));
  const other = mock(w.document.getElementById('ordinary-webview'));
  const workspace = mock(w.document.getElementById('review-workspace-webview'));
  const inline = mock(w.document.getElementById('review-inline-webview'));
  const embeddedPreview = mock(w.document.getElementById('ordinary-embedded-webview'));
  w.eval(install);
  await settle();
  assert.equal(review.styles.size, 1, '设置的独立 webview 应有一份背景样式');
  assert.equal(preview.calls(), 0, '设置中的其他预览 webview 应保留');
  assert.equal(other.calls(), 0, '设置以外的 MCP webview 应保留');
  assert.equal(workspace.styles.size, 1, 'PR 全局宿主中的独立文档应有背景样式');
  assert.equal(inline.styles.size, 1, '页面内的 PR 文档应适配背景');
  assert.equal(embeddedPreview.calls(), 0, '全局宿主中的其他预览保持原样');
  assert.match([...workspace.styles.values()][0], /h-screen/);
  for (const attribute of ['class', 'data-theme']) {
    for (const mode of ['dark', 'light']) {
      const root = w.document.documentElement;
      root.removeAttribute('class'); root.removeAttribute('data-theme');
      root.setAttribute(attribute, attribute === 'class' ? `electron-${mode}` : mode);
      await settle();
      assert.equal(review.styles.size, 1, '切换明暗应替换旧样式');
      assert.match([...review.styles.values()][0], mode === 'dark' ? /rgba\(18, 20, 20, 0\.18\)/ : /rgba\(248, 250, 249, 0\.14\)/);
      assert.equal(workspace.styles.size, 1);
      assert.match([...workspace.styles.values()][0], mode === 'dark' ? /rgba\(18, 20, 20, 0\.18\)/ : /rgba\(248, 250, 249, 0\.14\)/);
    }
  }
  review.styles.clear(); // webview 导航清除了文档，dom-ready 应重新应用。
  review.view.dispatchEvent(new w.Event('dom-ready'));
  await settle();
  assert.equal(review.styles.size, 1, '独立文档重新就绪时应补回背景样式');
  w.eval(install);
  await settle();
  assert.equal(review.styles.size, 1, '重复应用主题不能积累 webview 样式');
  assert.equal(workspace.styles.size, 1);

  const guest = new JSDOM(`<html><head><style>.bg-surface, [data-app-shell-main-surface] {background:white}</style><style>${[...workspace.styles.values()][0]}</style></head><body>${require('./fixtures_skin_review_workspace.cjs').document}</body></html>`);
  for (const id of ['pr-page', 'pr-main', 'pr-detail']) assert.equal(guest.window.getComputedStyle(guest.window.document.getElementById(id)).backgroundColor, 'rgba(0, 0, 0, 0)', `${id} PR 文档页面层应透明`);
  for (const [id, color] of [['pr-code-preview', 'rgb(255, 255, 255)'], ['pr-addition', 'rgb(220, 252, 231)'], ['pr-deletion', 'rgb(254, 226, 226)']]) assert.equal(guest.window.getComputedStyle(guest.window.document.getElementById(id)).backgroundColor, color, '代码内容与 diff 色保留');
  guest.window.close();

  workspace.view.setAttribute('title', 'Website Preview');
  await settle();
  assert.equal(workspace.styles.size, 0, 'PR webview 改为其他预览时恢复样式');
  workspace.view.setAttribute('title', 'Code Review');
  await settle();
  assert.equal(workspace.styles.size, 1, 'PR 标题稍后就绪时重新适配');

  const parent = review.view.parentElement;
  w.document.body.append(review.view);
  await settle();
  assert.equal(review.styles.size, 0, '离开设置宿主后应恢复独立文档');
  parent.append(review.view);
  await settle();
  assert.equal(review.styles.size, 1, '返回设置宿主后应重新适配');

  const lateView = w.document.createElement('webview');
  const late = mock(lateView);
  const insert = lateView.insertCSS;
  let ready = false;
  lateView.insertCSS = css => ready ? insert(css) : Promise.reject(new Error('not ready'));
  parent.append(lateView);
  await settle();
  assert.equal(late.styles.size, 0);
  ready = true;
  lateView.dispatchEvent(new w.Event('dom-ready'));
  await settle();
  assert.equal(late.styles.size, 1, '稍后加载的设置文档应在就绪时适配');

  let resolveInsert;
  const pendingInsert = new Promise(resolve => { resolveInsert = resolve; });
  lateView.insertCSS = async css => { await pendingInsert; return insert(css); };
  lateView.dispatchEvent(new w.Event('dom-ready'));
  await settle();
  const cleanup = w.eval(removeSkin);
  resolveInsert();
  await cleanup;
  assert.equal(review.styles.size, 0);
  assert.equal(workspace.styles.size, 0);
  assert.equal(inline.styles.size, 0);
  assert.equal(late.styles.size, 0, '恢复时尚未完成的注入也应被清理');
  const previousCalls = review.calls();
  review.view.dispatchEvent(new w.Event('dom-ready'));
  w.document.documentElement.setAttribute('data-theme', 'dark');
  await settle();
  assert.equal(review.calls(), previousCalls, '恢复后不应残留外观观察器或就绪监听');
  assert.equal(w.__codexboxSkinSettings, undefined);
  dom.window.close();
  console.log(`${platform}：设置 webview 明暗切换、延迟加载、导航、重应用与异步恢复通过`);
}

function verify26928Surfaces() {
  const fixture = require('./fixtures_skin_26928.cjs');
  const dom = new JSDOM(`<html><head><style>
    .bg-surface, .bg-surface-elevated-secondary, [class~="bg-surface-elevated-secondary/50"],
    [class~="bg-surface/70"], .messaging-root, .thread-pane, .reply-chain-composer, .composer-disclaimer,
    [data-thread-scroll-footer] { background: rgb(255,255,255); }
    .from-surface { background: white; background-image: linear-gradient(to top, white, transparent); }
    .message-bubble { background: rgb(240,240,240); }
    .border-default { border: 1px solid gray; }
    :where(.messaging-root) .composer-wrap { border-bottom: 12px solid rgb(255, 255, 255); }
    ._background_18gud_1 { height: 40px; background: linear-gradient(to bottom, white, transparent); }
    ._floatingHeader_1u6c1_2 { position: absolute; pointer-events: none; height: 96px; background: linear-gradient(to bottom, white, transparent); }
    :is(.electron-dark, [data-theme="dark"]) ._floatingHeader_1u6c1_2 { background: linear-gradient(to bottom, black, transparent); }
    .scale-y-150 { transform: scaleY(1.5); }
    .sticky { position: sticky; }
    .overflow-y-auto { overflow-y: auto; }
  </style><style>${css}</style></head><body>${fixture}</body></html>`);
  const w = dom.window;
  for (const attribute of ['class', 'data-theme']) {
    for (const mode of ['light', 'dark', 'light']) {
      const root = w.document.documentElement;
      root.removeAttribute('class'); root.removeAttribute('data-theme');
      root.setAttribute(attribute, attribute === 'class' ? `electron-${mode}` : mode);
      // jsdom 不计算自定义属性；只替换已由生产规则选出的变量值，浏览器另验真实级联。
      const glass = w.getComputedStyle(root).getPropertyValue('--codexbox-skin-glass').trim();
      w.document.querySelector('head style:last-child').textContent = css.replaceAll('var(--codexbox-skin-glass)', glass);
      const normalizedGlass = w.document.createElement('div').style;
      normalizedGlass.backgroundColor = glass;
      for (const id of ['dot-top-fade', 'dot-floating-header', 'footer', 'footer-surface', 'footer-fade', 'dot', 'dot-pane', 'reply-composer', 'disclaimer', 'file-row', 'sources-title', 'sources-header', 'dot-dialog', 'computers-header', 'activity-header']) {
        const style = w.getComputedStyle(w.document.getElementById(id));
        assert.equal(style.backgroundColor, 'rgba(0, 0, 0, 0)', `${attribute}/${mode}/${id} 新表面应透明`);
        assert.equal(style.backgroundImage || 'none', 'none', `${id} 应移除背景渐变`);
      }
      assert.match(w.getComputedStyle(root).getPropertyValue('--codexbox-skin-glass'),
        mode === 'light' ? /248.*250.*249.*(?:0?\.14)/ : /18.*20.*20.*(?:0?\.18)/, '玻璃底色应跟随模式');
      for (const id of ['active-tab', 'dot-active-tab', 'sources', 'files', 'dot-profile']) {
        const style = w.getComputedStyle(w.document.getElementById(id));
        assert.equal(style.backgroundColor, normalizedGlass.backgroundColor, `${id} 使用模式玻璃底`);
      }
      for (const id of ['inactive-tab', 'other-gradient', 'other-card', 'attachment-root', 'ordinary-header']) {
        assert.equal(w.getComputedStyle(w.document.getElementById(id)).backgroundColor, 'rgb(255, 255, 255)', `${id} 无关表面应保留`);
      }
      assert.equal(w.getComputedStyle(w.document.getElementById('bubble')).backgroundColor, 'rgb(240, 240, 240)', '保留 dot 消息气泡');
      assert.equal(w.getComputedStyle(w.document.querySelector('.diff-addition')).backgroundColor, 'rgba(0, 180, 0, 0.2)');
      assert.equal(w.getComputedStyle(w.document.querySelector('.diff-deletion')).backgroundColor, 'rgba(180, 0, 0, 0.2)');
      assert.equal(w.getComputedStyle(w.document.getElementById('spacer')).height, '120px', '保留输入框滚动占位');
      assert.equal(w.getComputedStyle(w.document.getElementById('dot-scroll')).overflowY, 'auto', '保留 dot 滚动');
      assert.equal(w.getComputedStyle(w.document.getElementById('profile-scroll')).overflowY, 'auto', '保留 dot 资料窗口滚动');
      assert.equal(w.getComputedStyle(w.document.getElementById('sources-header')).position, 'sticky', '保留摘要标题吸顶');
      assert.equal(w.getComputedStyle(w.document.getElementById('ordinary-dialog')).backgroundColor,
        mode === 'light' && css.includes('0.96') ? 'rgba(248, 250, 249, 0.96)' : 'rgb(255, 255, 255)', '保留普通弹窗底色');
      assert.equal(w.getComputedStyle(w.document.getElementById('allow-computer')).backgroundColor, 'rgba(128, 128, 128, 0.4)', '保留机器权限控件状态');
      assert.equal(w.getComputedStyle(w.document.getElementById('active-tab')).borderTopWidth, '1px', '保留选中标签边界');
      const topFade = w.getComputedStyle(w.document.getElementById('dot-top-fade'));
      assert.equal(topFade.height, '40px', '保留 dot 顶部装饰层尺寸');
      assert.equal(topFade.transform, 'scaleY(1.5)', '保留 dot 顶部布局变换');
      const floatingHeader = w.getComputedStyle(w.document.getElementById('dot-floating-header'));
      assert.equal(floatingHeader.height, '96px', '保留新版 dot 顶部装饰层尺寸');
      assert.equal(floatingHeader.position, 'absolute', '保留新版 dot 顶部定位');
      assert.equal(floatingHeader.pointerEvents, 'none', '新版 dot 装饰层不拦截点击');
      assert.match(w.getComputedStyle(w.document.getElementById('viewer-top-fade')).backgroundImage,
        /linear-gradient/, '保留其他预览工具栏的渐变');
      assert.match(w.getComputedStyle(w.document.getElementById('viewer-floating-header')).backgroundImage,
        /linear-gradient/, '保留使用相同浮动类名的其他预览工具栏');
      for (const id of ['dot-composer-wrap', 'reply-composer-wrap']) {
        const style = w.getComputedStyle(w.document.getElementById(id));
        assert.equal(style.borderBottomColor, 'rgba(0, 0, 0, 0)', `${id} 底部装饰边应透明`);
        assert.equal(style.borderBottomWidth, '12px', `${id} 保留输入区底部间距`);
        assert.equal(style.borderBottomStyle, 'solid');
      }
      assert.equal(w.getComputedStyle(w.document.getElementById('standalone-composer-wrap')).borderBottomColor,
        'rgb(255, 255, 255)', '保留独立消息输入区的底边');
    }
  }
  let clicks = 0;
  for (const id of ['dot-header-profile', 'dot-header-call', 'chat-tab', 'dot-tab', 'dot-tab-menu', 'source-link', 'file-row', 'expand-files', 'call-dot']) {
    const button = w.document.getElementById(id);
    button.addEventListener('click', () => clicks++); button.click();
  }
  assert.equal(clicks, 9, 'dot 顶部按钮、标签、菜单、来源、文件和展开仍能交互');
  dom.window.close();
  console.log('26.928 / 26.1007 输入框装饰、dot 顶部、会话标签、来源与文件卡片通过');
}
async function verify(mode, attribute = 'class') {
  const dom = new JSDOM(`<html ${attribute}="${attribute === 'class' ? `electron-${mode}` : mode}"><body><button>继续</button></body></html>`, { runScripts: 'outside-only' });
  const w = dom.window;
  let callbacks = 0;
  let clicks = 0;
  // 桌面颜色检测：根节点样式变化时，临时插入元素读取计算色。
  const observer = new w.MutationObserver(() => {
    if (++callbacks > 30) {
      observer.disconnect();
      return;
    }
    const probe = w.document.createElement('div');
    probe.style.display = 'none';
    w.document.body.append(probe);
    w.getComputedStyle(probe).backgroundColor;
    probe.remove();
  });
  observer.observe(w.document.documentElement, { attributes: true, attributeFilter: ['class', 'style', 'data-theme'] });
  w.document.querySelector('button').addEventListener('click', () => clicks++);
  let restored = false;
  w.__codexbarSkinAppearance = { restore() { restored = true; } };
  w.eval(installer);
  assert(restored, '重应用时清理已有外观观察器');
  assert.equal(w.__codexbarSkinAppearance, undefined);
  w.eval(installer);
  assert.equal(w.document.querySelectorAll('#codexbar-skin').length, 1);
  w.document.documentElement.classList.add('theme-change');
  await new Promise(resolve => w.setTimeout(() => { w.document.querySelector('button').click(); resolve(); }, 0));
  assert(callbacks <= 2, `颜色探针发生循环：${callbacks}`);
  assert.equal(clicks, 1);
  assert(attribute === 'class' ? w.document.documentElement.classList.contains(`electron-${mode}`) : w.document.documentElement.getAttribute(attribute) === mode);
  await w.eval(remover);
  await w.eval(remover);
  assert.equal(w.document.getElementById('codexbar-skin'), null);
  observer.disconnect();
  dom.window.close();
  console.log(`${attribute}/${mode}：颜色探针 ${callbacks} 次，重复换肤、点击、恢复通过`);
}
(async () => {
  const windowsSource = fs.readFileSync(path.join(__dirname, '../windows/src-tauri/src/desktop.rs'), 'utf8');
  const windowsCSS = windowsSource.slice(windowsSource.indexOf('fn build_css('))
    .split('let mut css = format!(')[1].split('r#"')[1].split('"#,')[0]
    .replace('{}', '').replace(/\{\{/g, '{').replace(/\}\}/g, '}');
  for (const [platform, productionCSS] of [['macOS', css], ['Windows', windowsCSS]]) {
    console.log(`${platform} 生产样式回归`);
    css = productionCSS;
    verifyCurrentShell();
    verifyComposerBackdrop();
    verifySpaceSettingsSurfaces();
    verifyReviewProfileSurfaces();
    verifyReviewWorkspaceSurfaces();
    verify26928Surfaces();
    for (const attribute of ['class', 'data-theme']) verifySurfaces(attribute);
  }
  const windowsInstaller = JSON.parse(`"${windowsSource.slice(windowsSource.indexOf('pub async fn inject_theme')).match(/"(\(\(\) => .*?)",\n\s*encoded/)[1]}"`)
    .replace(/\{\{/g, '{').replace(/\}\}/g, '}')
    .replace('{}', Buffer.from('body { --test: 1; }').toString('base64')).replace('{}', settingsScript);
  const windowsRemover = JSON.parse(`"${windowsSource.slice(windowsSource.indexOf('pub async fn remove_skin')).match(/let script = "([^"]+)"/)[1]}"`);
  for (const [platform, install, remove] of [['macOS', installer, remover], ['Windows', windowsInstaller, windowsRemover]]) {
    await verifySettingsWebviews(platform, install, remove);
  }
  for (const attribute of ['class', 'data-theme']) {
    await verify('light', attribute);
    await verify('dark', attribute);
  }
})().catch(error => { console.error(error); process.exitCode = 1; });
