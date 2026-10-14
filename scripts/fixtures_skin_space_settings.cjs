// 26.1007.30912 的站点/空间浏览页与设置分组结构。
// 来源：appgen-page、SearchableHeader、SettingsPageLayout、SettingsGroup。
module.exports = `
<main data-app-shell-main-surface="default">
  <div data-app-shell-main-content-layout="full-bleed">
    <div id="sites-page" class="flex h-full min-h-0 flex-col bg-surface">
      <div class="contents">
        <div id="space-scroll" data-app-shell-inline-page-header="true" class="relative h-full min-h-0 flex-1 overflow-x-hidden overflow-y-auto">
          <div class="flex min-h-full w-full flex-col">
            <div id="space-header" class="_shell_bomwa_2 border-transparent" data-sticky="true" data-scroll-collapse="true" data-expand-search="true">
              <div class="_content_bomwa_2 mx-auto w-full px-12">
                <div class="_headerRow_bomwa_2"><h1>站点</h1><input id="site-search" placeholder="搜索站点"><button id="create-site">创建网站</button></div>
              </div>
            </div>
            <div id="space-toolbar" class="sticky z-30 bg-surface top-0 after:bg-linear-to-b after:from-surface after:to-transparent"><button id="space-tab" style="background:rgba(128,128,128,0.2)">全部</button></div>
            <div id="sites-content" class="mx-auto flex min-h-0 w-full flex-1 flex-col bg-surface pb-panel max-w-[1440px] px-12">
              <div id="sites-tabpanel" role="tabpanel" tabindex="0" class="mx-auto flex min-h-full w-full flex-1 flex-col bg-surface">
                <div id="empty-state"><h2>暂无站点</h2><p>创建网站和应用</p><button>创建新站点</button></div>
                <article id="site-card" class="group/site-card rounded-2xl border border-subtle bg-surface-card"><div id="site-thumbnail" class="flex aspect-8/5 items-center justify-center overflow-hidden bg-surface">网站预览</div></article>
              </div>
            </div>
          </div>
        </div>
      </div>
    </div>
    <div id="settings-page" class="flex h-full min-h-0 flex-col electron:overflow-hidden electron:bg-surface">
      <div id="settings-scroll" class="flex-1 scrollbar-stable overflow-y-auto">
        <div id="settings-density" class="group/settings mx-auto flex w-full flex-col max-w-3xl" data-density="default">
          <h1>数据管理</h1>
          <section class="flex flex-col"><div class="flex flex-col gap-1.5">
            <div id="settings-group" class="flex flex-col rounded-2xl overflow-hidden border border-default" style="background-color:var(--color-background-panel, var(--color-background-primary-soft-alpha))">
              <div class="settings-row"><span>工作模式网络访问</span><button id="settings-toggle" role="switch" aria-checked="true" style="background:rgb(50,128,255)">开启</button></div>
              <div class="settings-row"><span>导出数据</span><button id="export-data" style="background:rgba(128,128,128,0.1)">导出</button></div>
            </div>
          </div></section>
          <section class="flex flex-col"><div id="settings-secondary" class="flex flex-col rounded-2xl overflow-hidden bg-surface-secondary/92">账号设置</div></section>
          <section class="flex flex-col"><div id="settings-form" class="flex flex-col rounded-2xl overflow-hidden border border-subtle bg-surface dark:bg-surface-secondary/92"><input id="settings-input" placeholder="名称"></div></section>
          <section class="flex flex-col"><div id="settings-muted" class="flex flex-col rounded-2xl overflow-hidden bg-(--color-background-primary-soft-alpha)/50 dark:bg-primary-soft-alpha">辅助设置</div></section>
          <div id="settings-preview" class="bg-surface">内容预览</div>
        </div>
      </div>
    </div>
    <div id="ordinary-inline-group" class="flex flex-col rounded-2xl" style="background-color:var(--color-background-panel, var(--color-background-primary-soft-alpha))">普通卡片</div>
    <div id="ordinary-shell" class="_shell_other_2" data-sticky="true">其他模块</div>
  </div>
</main>
<div id="space-menu" role="menu" class="bg-surface">菜单</div>
<div id="space-dialog" role="dialog" class="bg-surface">确认窗口</div>`;
