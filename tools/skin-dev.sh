#!/bin/bash
# codex-box 皮肤开发循环
#
# 解决的问题：调皮肤要看效果，看效果似乎要重启 Codex，
# 而重启会把正在干活的 Codex 会话打断。
#
# 关键认识：**重启只是为了拿到调试端口，不是为了应用样式。**
# 端口一旦开着，后续所有 CSS 迭代都能热注入，一次都不用再重启。
#
# 因此正确的工作方式是：
#   1. 开工前跑一次 `skin-dev.sh ensure`（这一次会重启 Codex）
#   2. 之后 inject / shot 反复迭代，Codex 全程不重启
#   3. 改完 Swift 代码再编译安装，最后验证一次完整流程
#
# 另外：**干活的 agent 请跑在 Codex CLI（终端）里，不要用桌面版。**
# CLI 与桌面版是两个进程，重启桌面版不会打断 CLI 会话。

set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN="$DIR/.bin"
APP="/Applications/ChatGPT.app"

mkdir -p "$BIN"

build_helpers() {
  for name in cdp-eval cdp-shot; do
    if [ ! -x "$BIN/$name" ] || [ "$DIR/$name.swift" -nt "$BIN/$name" ]; then
      swiftc -O "$DIR/$name.swift" -o "$BIN/$name"
    fi
  done
}

find_port() {
  lsof -nP -iTCP -sTCP:LISTEN 2>/dev/null \
    | grep -i "ChatGPT" | grep -oE ":[0-9]+ " | tr -d ': ' | head -1 || true
}

find_ws() {
  local port="$1"
  curl -s --noproxy '*' --max-time 5 "http://127.0.0.1:$port/json" \
    | python3 -c "
import sys, json
for t in json.load(sys.stdin):
    if t.get('type') == 'page' and t.get('url','').endswith('index.html'):
        print(t['webSocketDebuggerUrl']); break"
}

require_port() {
  local port
  port="$(find_port)"
  if [ -z "$port" ]; then
    echo "没有调试端口。先跑：$0 ensure" >&2
    exit 1
  fi
  echo "$port"
}

case "${1:-help}" in
  ensure)
    # 唯一需要重启 Codex 的一步，整轮开发只跑一次
    port="$(find_port)"
    if [ -n "$port" ]; then
      echo "调试端口已就绪：${port}（无需重启）"
      exit 0
    fi
    echo "正在以调试端口重启 Codex（此后不必再重启）…"
    osascript -e 'tell application id "com.openai.codex" to quit' >/dev/null 2>&1 || true
    for _ in $(seq 1 15); do
      pgrep -f "$APP/Contents/MacOS/ChatGPT" >/dev/null || break
      sleep 1
    done
    open -a "$APP" --args --remote-debugging-port=54321
    for _ in $(seq 1 30); do
      curl -s --noproxy '*' --max-time 2 "http://127.0.0.1:54321/json/version" >/dev/null 2>&1 && break
      sleep 1
    done
    echo "就绪：$(find_port)"
    ;;

  inject)
    # 用法：skin-dev.sh inject path/to/style.css
    build_helpers
    css_file="${2:?用法: $0 inject <css文件>}"
    port="$(require_port)"
    ws="$(find_ws "$port")"
    js="$(mktemp)"
    python3 - "$css_file" > "$js" <<'PY'
import base64, sys
css = open(sys.argv[1], 'rb').read()
enc = base64.b64encode(css).decode()
print(f"""(() => {{
  let e = document.getElementById('codexbox-dev');
  if (!e) {{ e = document.createElement('style'); e.id = 'codexbox-dev';
             document.documentElement.appendChild(e); }}
  e.textContent = atob('{enc}');
  return 'injected ' + e.textContent.length + ' bytes';
}})()""")
PY
    "$BIN/cdp-eval" "$ws" "$js"
    rm -f "$js"
    ;;

  shot)
    # 用法：skin-dev.sh shot out.png
    build_helpers
    out="${2:-/tmp/codexbox-shot.png}"
    port="$(require_port)"
    "$BIN/cdp-shot" "$(find_ws "$port")" "$out"
    echo "截图：$out"
    ;;

  vars)
    # 打印界面实际使用的主题变量，用于确认覆盖是否生效
    build_helpers
    port="$(require_port)"
    js="$(mktemp)"
    cat > "$js" <<'EOF'
(() => {
  const cs = getComputedStyle(document.documentElement);
  const names = ['--wb-surface-primary','--wb-surface-secondary','--color-background-surface',
                 '--wb-text-primary','--wb-text-tertiary','--wb-border','--wb-focus','--cb-scrim'];
  const out = {};
  for (const n of names) out[n] = cs.getPropertyValue(n).trim() || '(未设置)';
  out['htmlClass'] = document.documentElement.className;
  return JSON.stringify(out, null, 2);
})()
EOF
    "$BIN/cdp-eval" "$(find_ws "$port")" "$js"
    rm -f "$js"
    ;;

  reset)
    # 清掉开发期注入，回到 codex-box 正式注入的状态
    build_helpers
    port="$(require_port)"
    js="$(mktemp)"
    echo "(() => { const e = document.getElementById('codexbox-dev'); if (e) e.remove(); return 'cleared'; })()" > "$js"
    "$BIN/cdp-eval" "$(find_ws "$port")" "$js"
    rm -f "$js"
    ;;

  *)
    cat <<'USAGE'
codex-box 皮肤开发循环

  skin-dev.sh ensure            准备调试端口（整轮开发只需跑一次，会重启 Codex）
  skin-dev.sh inject <css文件>   热注入 CSS，不重启
  skin-dev.sh shot [out.png]     截图当前界面
  skin-dev.sh vars               打印界面实际生效的主题变量
  skin-dev.sh reset              清除开发期注入

典型循环（Codex 全程不重启）：
  ./tools/skin-dev.sh ensure
  vim /tmp/try.css
  ./tools/skin-dev.sh inject /tmp/try.css && ./tools/skin-dev.sh shot /tmp/a.png
  # 看图 → 改 CSS → 再来一轮
  # 满意后把 CSS 写进 CodexSkinInjectionService.buildCSS，编译验证

注意：干活的 agent 请跑在 Codex CLI（终端）里，不要用桌面版——
CLI 与桌面版是两个进程，重启桌面版不会打断 CLI 会话。
USAGE
    ;;
esac
