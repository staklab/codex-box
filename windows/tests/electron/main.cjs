const { app, BrowserWindow, protocol } = require('electron');
const path = require('node:path');
protocol.registerSchemesAsPrivileged([{scheme:'app',privileges:{standard:true,secure:true,supportFetchAPI:true}}]);
app.whenReady().then(async () => {
  protocol.handle('app', request => new Response(request.url.includes('avatar') ? '<title>Codex Avatar</title>辅助窗口' : `<!doctype html><html class="electron-dark"><head><meta charset="utf-8"><title>Codex 换肤回归</title><style>
  :root {--radius-2xl:24px} body{margin:0;background:#181818;color:white;font:18px sans-serif} :is(.electron-light,[data-theme="light"]) body{background:white;color:#18232b}
  main{height:100vh;display:flex;position:relative;background:#181818}:is(.electron-light,[data-theme="light"]) main{background:white}
  .app-shell-left-panel{position:relative;width:260px;background:rgba(50,50,50,.7)}.app-shell-left-panel::after{content:'';position:absolute;inset:0 -24px 0 auto;width:24px;background:inherit;pointer-events:none}
  [data-app-shell-page-surface="true"]{background:rgba(24,24,24,.8)}.sidebar-navigation{height:100%;background:rgba(24,24,24,.65)}[class~="electron:bg-surface"]{background:#181818}:is(.electron-light,[data-theme="light"]) .sidebar-navigation{background:rgba(255,255,255,.65)}:is(.electron-light,[data-theme="light"]) [class~="electron:bg-surface"]{background:white}
  #content{padding:40px;flex:1}button{margin:30px;padding:16px}.card{margin:30px;background:#282828;padding:24px}:is(.electron-light,[data-theme="light"]) .card{background:#eee}
  </style></head><body><main class="bg-surface" data-app-shell-page-surface="true"><div class="app-shell-left-panel"><div class="sidebar-navigation"><button id="click">常规设置</button><p>主题与账号</p></div></div><main id="content" class="_MainContentSurface_fixture"><div class="text-size-chat">换肤后的正文应清晰可读。<br>测试消息：something went wrong</div><div data-app-shell-main-content-layout="full-bleed"><div id="settings" class="electron:bg-surface flex h-full min-h-0 flex-col"><div class="scrollbar-stable overflow-y-auto"><div class="card">设置内容</div></div></div></div></main></main><script>
  window.clicks=0;document.querySelector('#click').onclick=()=>window.clicks++;
  window.probes=0;new MutationObserver(()=>{window.probes++;if(window.probes>20)throw Error('颜色探针循环');let p=document.createElement('div');p.hidden=true;document.body.append(p);getComputedStyle(p).color;p.remove()}).observe(document.documentElement,{attributes:true,attributeFilter:['class','style','data-theme']});
  </script></body></html>`, {headers:{'Content-Type':'text/html;charset=utf-8'}}));
  const main = new BrowserWindow({width:1100,height:760,webPreferences:{preload:path.join(__dirname,'preload.cjs')}});
  await main.loadURL('app://-/index.html');
  const avatar = new BrowserWindow({show:false,webPreferences:{preload:path.join(__dirname,'preload.cjs')}});
  await avatar.loadURL('app://-/avatar-overlay');
  // 模拟官方 Windows 关闭窗口后仍驻留后台的行为。
  main.on('close',event=>{event.preventDefault();main.hide()});
});
app.on('window-all-closed',()=>app.quit());
