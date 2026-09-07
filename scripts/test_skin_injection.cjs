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
async function verify(mode) {
  const dom = new JSDOM(`<html class="electron-${mode}"><body><button>继续</button></body></html>`, { runScripts: 'outside-only' });
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
  observer.observe(w.document.documentElement, { attributes: true, attributeFilter: ['class', 'style'] });
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
  assert(w.document.documentElement.classList.contains(`electron-${mode}`));
  w.eval(remover);
  w.eval(remover);
  assert.equal(w.document.getElementById('codexbar-skin'), null);
  observer.disconnect();
  dom.window.close();
  console.log(`${mode}：颜色探针 ${callbacks} 次，重复换肤、点击、恢复通过`);
}
(async () => { await verify('light'); await verify('dark'); })().catch(error => { console.error(error); process.exitCode = 1; });
