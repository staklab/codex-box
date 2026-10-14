// 26.1007.30912：code-review/assets/pull-requests.js 的 u0i / mQn / xgo，及 widget.Nc 的全局宿主。
module.exports = {
  host: `
    <main data-app-shell-main-surface="default">
      <div id="review-workspace-surface" data-mcp-extension-surface="true" class="flex h-full min-h-0 flex-col bg-surface text-default" style="background-color:white">
        <div data-mcp-app-portal-target="true"><div data-mcp-app-inline-surface="true"></div></div>
      </div>
      <div data-mcp-app-portal-target="true"><div id="review-inline-host" class="group/mcp-app"><webview id="review-inline-webview" title="代码审查" style="background-color:white"></webview></div></div>
    </main>
    <div data-embedded-frame-host-root="true" class="pointer-events-none fixed inset-0 overflow-visible">
      <div id="review-workspace-host" class="group/mcp-app pointer-events-auto relative flex h-full min-h-0 min-w-0 w-full flex-col overflow-hidden" style="background-color:white">
        <webview id="review-workspace-webview" title="Code Review" class="h-full min-h-0 min-w-0 w-full overflow-hidden" style="background-color:white"></webview>
      </div>
      <div id="ordinary-embedded-host" class="group/mcp-app" style="background-color:white"><webview id="ordinary-embedded-webview" title="Website Preview" style="background-color:white"></webview></div>
    </div>`,
  document: `
    <div id="root">
      <div id="pr-page" class="relative flex h-screen min-h-0 min-w-0 overflow-hidden bg-surface">
        <div class="relative isolate flex max-h-full min-h-0 w-full flex-1">
          <div class="_MainContentClip_19cvy_2">
            <main id="pr-main" class="_MainContentSurface_19cvy_2" data-app-shell-main-surface="default">
              <div class="_WorkspaceContent_19cvy_2"><div class="h-full select-none"><h2>Select a pull request</h2><p>Choose one from the sidebar to review its changes</p></div></div>
              <section id="pr-detail" class="h-full min-h-0 min-w-0 bg-surface">
                <div id="pr-code-preview" class="bg-surface">代码预览</div>
                <div id="pr-addition" style="background:rgb(220,252,231)">新增行</div>
                <div id="pr-deletion" style="background:rgb(254,226,226)">删除行</div>
              </section>
            </main>
          </div>
        </div>
      </div>
    </div>`,
};
