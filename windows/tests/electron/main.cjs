const { app, BrowserWindow, protocol } = require('electron');
const path = require('node:path');
protocol.registerSchemesAsPrivileged([{scheme:'app',privileges:{standard:true,secure:true,supportFetchAPI:true}}]);
app.whenReady().then(async () => {
  protocol.handle('app', request => new Response(request.url.includes('avatar') ? '<title>Codex Avatar</title>辅助窗口' : `<!doctype html><html class="electron-dark"><head><meta charset="utf-8"><title>Codex 换肤回归</title><style>
  :root {--radius-2xl:24px} body{margin:0;background:#181818;color:white;font:18px sans-serif} .electron-light body{background:white;color:#18232b}
  main{height:100vh;display:flex;position:relative;background:#181818}.electron-light main{background:white}
  .app-shell-left-panel{position:relative;width:260px;background:rgba(50,50,50,.7)}.app-shell-left-panel::after{content:'';position:absolute;inset:0 -24px 0 auto;width:24px;background:inherit;pointer-events:none}
  #content{padding:40px;flex:1}button{margin:30px;padding:16px}.card{margin:30px;background:#282828;padding:24px}.electron-light .card{background:#eee}
  </style></head><body><main class="bg-surface"><div class="app-shell-left-panel"><button id="click">常规设置</button><p>主题与账号</p></div><main id="content" class="_MainContentSurface_fixture"><div class="text-size-chat">换肤后的正文应清晰可读。<br>测试消息：something went wrong</div><div class="card">设置内容</div></main></main><script>
  window.clicks=0;document.querySelector('#click').onclick=()=>window.clicks++;
  window.probes=0;new MutationObserver(()=>{window.probes++;if(window.probes>20)throw Error('颜色探针循环');let p=document.createElement('div');p.hidden=true;document.body.append(p);getComputedStyle(p).color;p.remove()}).observe(document.documentElement,{attributes:true,attributeFilter:['class','style']});
  </script></body></html>`, {headers:{'Content-Type':'text/html;charset=utf-8'}}));
  const main = new BrowserWindow({width:1100,height:760,webPreferences:{preload:path.join(__dirname,'preload.cjs')}});
  await main.loadURL('app://-/index.html');
  const avatar = new BrowserWindow({show:false,webPreferences:{preload:path.join(__dirname,'preload.cjs')}});
  await avatar.loadURL('app://-/avatar-overlay');
  main.on('closed',()=>app.quit());
});
app.on('window-all-closed',()=>app.quit());
