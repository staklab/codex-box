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
    for (const attribute of ['class', 'data-theme']) verifySurfaces(attribute);
  }
  for (const attribute of ['class', 'data-theme']) {
    await verify('light', attribute);
    await verify('dark', attribute);
  }
})().catch(error => { console.error(error); process.exitCode = 1; });
