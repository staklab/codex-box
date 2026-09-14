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
const css = source.slice(source.indexOf('private func buildCSS')).split('rules.append("""')[1].split('""")')[0]
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
(async () => { for (const attribute of ['class', 'data-theme']) { verifySurfaces(attribute); await verify('light', attribute); await verify('dark', attribute); } })().catch(error => { console.error(error); process.exitCode = 1; });
