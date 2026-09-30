// Codex 26.928.20755：取自 thread-scroll-layout、native-room 和完成文件卡片。
module.exports = `
<div data-app-shell-tab-controller="main" data-tab-id="chat">
  <div id="active-tab" class="pointer-events-none absolute inset-0 z-0 rounded-md border-hairline border-default bg-surface-elevated-secondary shadow-sm _SelectedSurface_p64dj_1"></div>
  <button id="chat-tab" aria-selected="true">审查采序接管状态</button>
</div>
<div id="inactive-tab" class="bg-surface">其他标签</div>
<div class="relative flex shrink-0 items-center overflow-hidden">
  <div data-tab-id="dot" class="group/tab relative flex h-8 shrink-0 items-center rounded-lg select-none">
    <div id="dot-active-tab" class="pointer-events-none absolute inset-0 z-0 rounded-md border-hairline border-default bg-surface-elevated-secondary shadow-sm _SelectedSurface_p64dj_1"></div>
    <button id="dot-tab" role="tab" aria-selected="true">tibo</button>
    <button id="dot-tab-menu">更多</button>
  </div>
</div>
<main data-app-shell-main-surface="default" class="_MainContentSurface_bo1ta_2">
  <div id="footer" data-thread-scroll-footer="true" class="pointer-events-none absolute inset-x-0 z-20 has-[[data-thread-focus-mode]]:bg-surface bottom-0 pb-4">
    <div id="footer-surface" aria-hidden="true" class="pointer-events-none absolute inset-x-0 -top-8 z-0 bottom-0 mt-8 bg-surface"></div>
    <div id="composer" class="_ComposerLayoutRoot_newhash_2"><input id="composer-input"><button>发送</button></div>
  </div>
  <div id="spacer" aria-hidden="true" class="pointer-events-none sticky bottom-0 z-10 mt-auto w-full shrink-0" style="height:120px">
    <div id="footer-fade" aria-hidden="true" class="pointer-events-none absolute inset-x-0 -top-8 z-0 h-8 bg-gradient-to-t from-surface"></div>
  </div>
  <div id="other-gradient" aria-hidden="true" class="pointer-events-none absolute inset-x-0 bg-gradient-to-t from-surface">预览装饰</div>
  <div id="dot" class="messaging-root messaging-embedded">
    <div class="workspace"><section id="dot-pane" class="thread-pane">
      <div id="dot-scroll" class="messages-scroll" style="height:120px;overflow-y:auto">
        <div class="message-list" style="height:240px"><div id="bubble" class="message-bubble">你好</div></div>
      </div>
      <div class="conversation-footer">
        <div id="dot-composer-wrap" class="composer-wrap"><div class="_ComposerLayoutRoot_newhash_2"><input id="dot-input"></div></div>
        <div id="reply-composer" class="reply-chain-composer"><div id="reply-composer-wrap" class="composer-wrap"><input id="reply-input"></div></div>
      </div>
      <p id="disclaimer" class="composer-disclaimer">提示</p>
    </section></div>
  </div>
  <div id="sources" data-summary-panel-variant="summary" class="group/summary-panel rounded-2xl bg-surface-elevated-secondary electron:elevation-prominent">
    <header id="sources-title" class="sticky top-2 z-10 flex h-7 w-full bg-surface-elevated-secondary before:bg-surface-elevated-secondary before:pointer-events-none before:absolute before:inset-x-0 before:-top-2 before:h-2 before:content-['']">采序</header>
    <header id="sources-header" class="sticky top-2 z-10 flex h-7 w-full bg-surface-elevated-secondary before:bg-surface-elevated-secondary before:pointer-events-none before:absolute before:inset-x-0 before:-top-2 before:h-2 before:content-['']">来源</header>
    <button id="source-link" data-slot="thread-summary-panel-item">来源</button>
  </div>
  <div id="files" class="flex flex-col overflow-hidden electron:elevation-stroke bg-surface-elevated-secondary/50 rounded-lg mb-2 text-base [--turn-diff-row-padding-y:0.25rem]">
    <div class="group/turn-diff-header"><button>查看变更</button></div>
    <div class="flex flex-col border-t border-default">
      <div class="group/turn-diff-file-row"><button id="file-row" class="flex h-9 w-full bg-surface/70 hover:bg-background-primary-ghost-hover/60">agent/result_projection.py</button></div>
      <div class="diff-addition" style="background:rgba(0,180,0,0.2)">新增</div>
      <div class="diff-deletion" style="background:rgba(180,0,0,0.2)">删除</div>
      <button id="expand-files" aria-expanded="false">再显示 5 个文件</button>
    </div>
  </div>
  <div id="other-card" class="bg-surface-elevated-secondary/50 rounded-lg">附件预览</div>
</main>
<div id="dot-dialog" role="dialog" class="relative flex max-h-full min-h-0 flex-col">
  <div id="dot-profile" data-summary-panel-variant="dynamic-isle" class="group/summary-panel rounded-2xl bg-surface-elevated-secondary electron:elevation-prominent">
    <div id="profile-scroll" class="flex h-fit max-h-full min-h-0 min-w-0 flex-col overflow-x-hidden overflow-y-auto" style="height:120px">
      <section role="presentation"><div>tibo</div><button id="call-dot">拨打电话</button></section>
      <section role="presentation">
        <header id="computers-header" class="sticky top-2 z-10 flex h-7 w-full bg-surface-elevated-secondary before:bg-surface-elevated-secondary before:pointer-events-none before:absolute before:inset-x-0 before:-top-2 before:h-2 before:content-['']">Computers</header>
        <div data-slot="thread-summary-panel-item"><span>MacBook-Pro.local</span><button id="allow-computer" disabled style="background:rgba(128,128,128,0.4)">允许</button></div>
      </section>
      <section role="presentation">
        <header id="activity-header" class="sticky top-2 z-10 flex h-7 w-full bg-surface-elevated-secondary before:bg-surface-elevated-secondary before:pointer-events-none before:absolute before:inset-x-0 before:-top-2 before:h-2 before:content-['']">活动</header>
        <button>已创建任务</button>
      </section>
    </div>
  </div>
</div>
<div id="ordinary-dialog" role="dialog" class="bg-surface"><header id="ordinary-header" class="sticky top-2 bg-surface-elevated-secondary">确认操作</header><button>确认</button></div>
<div id="attachment-root" class="messaging-root messaging-attachments">附件</div>
<div class="messaging-root"><div id="standalone-composer-wrap" class="composer-wrap">独立消息输入区</div></div>
<div id="menu" role="menu" class="bg-surface">菜单</div>`;
