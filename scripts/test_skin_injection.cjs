// 使用隔离 DOM 检查颜色探针、换肤与恢复之间的事件循环。
// 运行：node scripts/test_skin_injection.cjs（先安装 windows 开发依赖）
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { JSDOM } = require('../windows/node_modules/jsdom');
const source = fs.readFileSync(path.join(__dirname, '../codexBar/Services/CodexSkinInjectionService.swift'), 'utf8');
const installer = source.slice(source.indexOf('private static func installerJS')).split('return """')[1].split('"""')[0]
  .replace('\\(encoded)', Buffer.from('body { --test: 1; }').toString('base64'));
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
    .sticky.bg-surface { background: rgb(255,255,255); position: sticky; top: 0; }
    .bg-page-search { background: rgb(255,255,255); border: 1px solid gray; }
  </style><style>${css}</style></head><body>${fixture}</body></html>`);
  const w = dom.window;
  for (const mode of ['light', 'dark', 'light']) {
    w.document.documentElement.setAttribute('data-theme', mode);
    for (const id of ['frame', 'titlebar', 'settings', 'sidebar', 'usage-toolbar', 'shortcut-toolbar', 'search-field']) {
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
      for (const id of ['dot-top-fade', 'footer', 'footer-surface', 'footer-fade', 'dot', 'dot-pane', 'reply-composer', 'disclaimer', 'file-row', 'sources-title', 'sources-header', 'dot-dialog', 'computers-header', 'activity-header']) {
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
      assert.match(w.getComputedStyle(w.document.getElementById('viewer-top-fade')).backgroundImage,
        /linear-gradient/, '保留其他预览工具栏的渐变');
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
  console.log('26.928 输入框装饰、dot、会话标签、来源与文件卡片通过');
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
  w.eval(remover);
  w.eval(remover);
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
    verify26928Surfaces();
    for (const attribute of ['class', 'data-theme']) verifySurfaces(attribute);
  }
  for (const attribute of ['class', 'data-theme']) {
    await verify('light', attribute);
    await verify('dark', attribute);
  }
})().catch(error => { console.error(error); process.exitCode = 1; });
