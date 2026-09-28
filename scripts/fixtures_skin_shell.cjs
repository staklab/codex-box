// Codex 26.924 的外壳与设置详情结构；仅保留影响背景、滚动和交互的节点。
module.exports = `
<div id="frame" class="_PageSurfaceLayout_gs442_2" data-app-shell-frame="true" data-app-shell-page-surface="true" data-app-shell-workspace-tab-chrome="true">
  <aside class="app-shell-left-panel _LeftPanel_gs442_2" data-app-shell-left-panel-appearance="default">
    <div id="app-shell-sidebar"><div class="flex">
      <nav id="rail"><button>主页</button></nav>
      <div id="sidebar" class="relative flex min-h-0 min-w-0 flex-1 flex-col overflow-hidden sidebar-navigation">
        <nav><button id="project">项目</button><button id="selected" style="background:rgba(128,128,128,0.2)">当前会话</button></nav>
      </div>
    </div></div>
  </aside>
  <div data-app-shell-unified-tab-strip="true">
    <main id="main" data-app-shell-main-surface="default" class="_MainContentSurface_gs442_2">
      <div id="workspace" class="_WorkspaceContent_gs442_2">
        <header id="titlebar" data-app-shell-main-titlebar="true">常规</header>
        <div data-app-shell-main-content-layout="full-bleed">
          <div id="settings" class="flex h-full min-h-0 flex-col electron:overflow-hidden electron:bg-surface windows:rounded-tl-lg">
            <div class="flex-1 scrollbar-stable overflow-y-auto" style="height:120px; overflow-y:auto">
              <section id="card" class="bg-surface-secondary" style="height:240px"><button id="toggle">切换</button></section>
            </div>
          </div>
          <div id="preview" class="electron:bg-surface">内容预览</div>
        </div>
        <div id="composer" class="_ComposerLayoutRoot_newhash_2">输入框</div>
      </div>
    </main>
  </div>
</div>
<div id="menu" role="menu" class="bg-surface">菜单</div>`;
