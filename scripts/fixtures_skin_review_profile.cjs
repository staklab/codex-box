// 26.1007.30912：ProfilePage / ProfileSettings / CodeReviewPluginSettings 与 MCP 宿主。
module.exports = `
<main data-app-shell-main-surface="default">
  <div data-app-shell-main-content-layout="full-bleed">
    <div id="review-page" class="flex h-full min-h-0 flex-col electron:overflow-hidden electron:bg-surface select-none">
      <div id="review-scroll" class="flex-1 scrollbar-stable overflow-y-auto">
        <div class="group/settings mx-auto flex w-full flex-col max-w-3xl px-panel pb-panel" data-density="default">
          <h1>代码审查</h1>
          <section aria-label="应用偏好设置">
            <div data-mcp-app-portal-target="true" class="relative h-full min-h-0">
              <div id="review-host" class="group/mcp-app pointer-events-auto relative flex h-full min-h-0 min-w-0 w-full flex-col overflow-hidden">
                <webview id="review-webview" class="h-full min-h-0 min-w-0 w-full overflow-hidden rounded-lg" style="background-color:rgb(255,255,255)" title="代码审查设置"></webview>
              </div>
            </div>
          </section>
          <div id="settings-other-webview"><webview id="settings-preview-webview" style="background-color:rgb(255,255,255)"></webview></div>
        </div>
      </div>
    </div>
    <div id="profile-page" class="relative flex h-full min-h-0 min-w-0 flex-1 flex-col bg-surface">
      <header id="profile-header" class="relative z-30 shrink-0 border-b border-subtle bg-surface/80 backdrop-blur-xl dark:border-default" data-app-shell-header="true"><button id="profile-edit">编辑个人资料</button></header>
      <div id="profile-page-scroll" data-profile-scroll="true" class="@container -mt-[var(--height-toolbar)] min-h-0 flex-1 scrollbar-stable overflow-y-auto">
        <div class="mx-auto flex w-full max-w-[732px] flex-col gap-10 px-panel pt-12">
          <div class="relative isolate flex flex-col items-center"><div id="profile-avatar" style="background:rgb(205,243,255)">头像</div><h1>个人资料</h1></div>
          <section class="@container flex flex-col items-center justify-center overflow-hidden rounded-2xl border border-token-border-default bg-transparent"><div>使用统计</div></section>
          <section class="group/profile-section flex flex-col gap-4">
            <h2>精选作品</h2>
            <div class="grid grid-cols-1 gap-4">
              <div id="profile-showcase-empty" class="_showcaseEmptyState_1eppv_28 col-span-full flex min-h-64 w-full flex-col items-center justify-center gap-4 rounded-2xl px-6 py-10 text-center select-none">
                <div id="profile-showcase-artwork" style="background:rgb(255,255,255)">WWW</div><p role="status">在你的个人资料中展示网站</p><button id="profile-create-site">创建网站</button>
              </div>
              <div id="profile-showcase-site" class="_card_1pl6u_1 _site_1pl6u_19 bg-surface">网站预览</div>
            </div>
          </section>
          <section class="group/profile-section flex flex-col gap-4">
            <h2>Token 活动</h2>
            <div id="profile-activity-chart" class="flex flex-col gap-2" role="img" aria-label="Codex token activity" style="--profile-usage-level-0:var(--color-chart-empty);--profile-usage-level-1:var(--color-chart-sequential-1);--profile-usage-level-4:var(--color-chart-sequential-4)">
              <div id="profile-empty-cell" class="pointer-events-none size-full rounded-[4px] _cell_1ac5p_12 bg-[var(--profile-usage-level-0)]"></div>
              <div id="profile-activity-cell" class="pointer-events-none size-full rounded-[4px] _cell_1ac5p_12 bg-[var(--profile-usage-level-1)]" style="background:rgb(50,128,255)"></div>
            </div>
          </section>
          <div id="profile-content-preview" class="bg-surface">内容预览</div>
        </div>
      </div>
    </div>
  </div>
  <div id="profile-settings" class="relative flex h-full min-h-0 min-w-0 flex-1 flex-col electron:overflow-hidden electron:bg-surface">
    <div id="profile-settings-scroll" data-profile-scroll="true" class="@container flex-1 scrollbar-stable overflow-y-auto pb-panel">
      <div id="profile-settings-header" class="_shell_bomwa_2 border-transparent"><h1>个人资料</h1></div>
      <div class="flex min-h-0 flex-col pt-panel"><div class="group/settings mx-auto flex w-full flex-col max-w-3xl px-panel pt-panel" data-density="default"><p>个人介绍</p></div></div>
    </div>
  </div>
  <div id="profile-lookalike" class="flex h-full min-h-0 flex-col bg-surface"><div class="scrollbar-stable overflow-y-auto">其他页面</div></div>
  <div id="ordinary-showcase-empty" class="_showcaseEmptyState_1eppv_28">其他空状态</div>
  <div id="ordinary-activity-chart" role="img" style="--profile-usage-level-0:white">其他图表</div>
  <div class="group/mcp-app"><webview id="ordinary-webview" style="background-color:rgb(255,255,255)"></webview></div>
</main>`;
