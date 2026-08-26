import AppKit
import Foundation

/// 主题预览画廊：生成 HTML 并交给本地 HTTP 服务提供，再用默认浏览器打开。
///
/// 走本地 HTTP 而非 `file://`，是因为浏览器（尤其 Chrome）会拦截由 `file://`
/// 页面发起的自定义 scheme 跳转，表现就是"点了没反应"。同源之后按钮用
/// `fetch()` 调 `/apply`，还能把执行结果回显到页面。
@MainActor
enum CodexThemePreviewService {
    static func generateAndOpen(themeService: CodexThemeService) async throws {
        let url = try CodexPreviewServer.shared.serve(
            htmlProvider: { await self.renderPage(themeService: themeService) },
            themeService: themeService
        )
        NSWorkspace.shared.open(url)
    }

    /// 生成整页 HTML。每次浏览器请求 `/` 都会重新调用，
    /// 因此在页面里安装主题后刷新一下即可看到状态同步。
    static func renderPage(themeService: CodexThemeService) async -> String {
        let installedIDs = Set(themeService.state.installed.map(\.id))

        let installedCards = themeService.state.installed.compactMap { record -> String? in
            guard let definition = try? themeService.loadDefinition(id: record.id) else { return nil }
            return self.installedCard(
                record: record,
                definition: definition,
                imageURI: self.imageDataURI(directory: themeService.themeDirectory(id: record.id)),
                isApplied: themeService.state.appliedThemeID == record.id
            )
        }

        let pending = themeService.listings.filter { installedIDs.contains($0.id) == false }
        let previews = await self.fetchPreviews(for: pending)
        let grouped = Dictionary(grouping: pending) { $0.sourceName ?? "未知来源" }

        var marketGroups: [(name: String, cards: [String])] = []
        for name in grouped.keys.sorted() {
            let cards = (grouped[name] ?? []).map {
                self.marketCard(listing: $0, previewURI: previews[$0.id])
            }
            marketGroups.append((name, cards))
        }

        return self.page(installedCards: installedCards, marketGroups: marketGroups)
    }

    // MARK: - 预览图

    private static func fetchPreviews(for listings: [CodexThemeListing]) async -> [String: String] {
        await withTaskGroup(of: (String, String?).self) { group in
            for listing in listings {
                guard let path = listing.preview, path.isEmpty == false,
                      let base = listing.sourceBaseURL,
                      base != CodexThemeService.localSourceMarker,
                      let url = URL(string: path.hasPrefix("http") ? path : "\(base)/\(path)")
                else { continue }

                group.addTask {
                    var request = URLRequest(url: url)
                    request.timeoutInterval = 20
                    guard let (data, response) = try? await URLSession.shared.data(for: request),
                          let http = response as? HTTPURLResponse,
                          (200..<300).contains(http.statusCode),
                          data.isEmpty == false
                    else { return (listing.id, nil) }

                    let ext = url.pathExtension.lowercased()
                    let mime = ext == "png" ? "image/png"
                        : (ext == "webp" ? "image/webp" : "image/jpeg")
                    return (listing.id, "data:\(mime);base64,\(data.base64EncodedString())")
                }
            }
            var result: [String: String] = [:]
            for await (id, uri) in group {
                if let uri { result[id] = uri }
            }
            return result
        }
    }

    // MARK: - 工具

    private static func escape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    private static func actions(id: String, hasWallpaper: Bool) -> String {
        let js = id.replacingOccurrences(of: "'", with: "\\'")
        let wallpaper = hasWallpaper
            ? "<button class=\"btn primary\" onclick=\"apply('\(js)', 1)\">应用 + 壁纸</button>"
            : ""
        return """
        <div class="acts">
          <button class="btn" onclick="apply('\(js)', 0)">应用配色</button>
          \(wallpaper)
        </div>
        """
    }

    private static func imageDataURI(directory: URL) -> String? {
        for candidate in ["image.png", "image.jpg", "image.jpeg", "image.webp"] {
            let url = directory.appendingPathComponent(candidate)
            guard let data = try? Data(contentsOf: url) else { continue }
            let mime = candidate.hasSuffix("png") ? "image/png"
                : (candidate.hasSuffix("webp") ? "image/webp" : "image/jpeg")
            return "data:\(mime);base64,\(data.base64EncodedString())"
        }
        return nil
    }

    // MARK: - 卡片

    private static func installedCard(
        record: CodexInstalledTheme,
        definition: CodexThemeDefinition,
        imageURI: String?,
        isApplied: Bool
    ) -> String {
        let colors = definition.colors
        let background = CodexThemeService.normalizedHex(colors.background) ?? "#1a1a1a"
        let accent = CodexThemeService.normalizedHex(colors.accent) ?? "#69b99a"
        let text = CodexThemeService.normalizedHex(colors.text) ?? "#e8e8e8"
        let muted = CodexThemeService.normalizedHex(colors.muted) ?? "#8a8a8a"

        let wall = imageURI.map { "<div class=\"wall\" style=\"background-image:url('\($0)')\"></div>" }
            ?? "<div class=\"wall none\">仅配色 · 无壁纸</div>"

        let swatches = [colors.background, colors.panel, colors.accent, colors.accentAlt,
                        colors.secondary, colors.highlight, colors.text, colors.muted]
            .compactMap { CodexThemeService.normalizedHex($0) }
            .map { "<i style=\"background:\($0)\"></i>" }
            .joined()

        let pill = isApplied ? "<span class=\"pill\">使用中</span>" : ""

        return """
        <article class="card">
          <div class="mock" style="--accent:\(accent);--text:\(text);--muted:\(muted);background:\(background)">
            \(wall)
            <div class="chrome">
              <aside>
                <span class="dots"><i></i><i></i><i></i></span>
                <span class="nav on">对话</span><span class="nav">项目</span><span class="nav">设置</span>
              </aside>
              <div class="pane">
                <div class="b user">帮我重构这个函数</div>
                <div class="b bot">好的，我先读一遍现有实现。<em></em></div>
                <div class="composer">输入消息…</div>
              </div>
            </div>
          </div>
          <div class="body">
            <h3>\(self.escape(record.name))\(pill)</h3>
            <p class="sub">\(self.escape(definition.tagline ?? ""))</p>
            <div class="sw">\(swatches)</div>
            \(self.actions(id: record.id, hasWallpaper: record.hasImage))
          </div>
        </article>
        """
    }

    private static func marketCard(listing: CodexThemeListing, previewURI: String?) -> String {
        let media = previewURI.map { "<div class=\"shot\" style=\"background-image:url('\($0)')\"></div>" }
            ?? "<div class=\"shot none\">无预览图</div>"

        let meta = [listing.author, listing.description]
            .compactMap { $0 }
            .filter { $0.isEmpty == false }
            .joined(separator: " · ")

        return """
        <article class="card">
          \(media)
          <div class="body">
            <h3>\(self.escape(listing.name))</h3>
            <p class="sub">\(self.escape(meta))</p>
            \(self.actions(id: listing.id, hasWallpaper: true))
          </div>
        </article>
        """
    }

    // MARK: - 页面

    private static func page(
        installedCards: [String],
        marketGroups: [(name: String, cards: [String])]
    ) -> String {
        var tabs: [String] = []
        var sections: [String] = []

        if installedCards.isEmpty == false {
            tabs.append("<button class=\"tab active\" data-t=\"installed\">已安装 <b>\(installedCards.count)</b></button>")
            sections.append("""
            <section data-s="installed">
              <h2>已安装</h2>
              <p class="hint">按真实注入效果渲染：面板不透明度 62%，壁纸从下方透出。</p>
              <div class="grid">\(installedCards.joined())</div>
            </section>
            """)
        }

        for (index, group) in marketGroups.enumerated() {
            let key = "src\(index)"
            let active = (installedCards.isEmpty && index == 0) ? " active" : ""
            tabs.append("<button class=\"tab\(active)\" data-t=\"\(key)\">\(self.escape(group.name)) <b>\(group.cards.count)</b></button>")
            sections.append("""
            <section data-s="\(key)">
              <h2>\(self.escape(group.name))</h2>
              <p class="hint">未安装。点「应用」会自动下载安装后再应用。</p>
              <div class="grid">\(group.cards.joined())</div>
            </section>
            """)
        }

        let empty = sections.isEmpty
            ? "<p class=\"empty\">还没有任何主题。先回 codex-box 菜单点刷新拉取市场。</p>"
            : ""

        return """
        <!doctype html>
        <html lang="zh-CN"><head>
        <meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
        <title>codex-box 主题库</title>
        <style>
        :root{--bg:#f7f7f8;--fg:#15171c;--sub:#6b7280;--card:#fff;--line:#e5e7eb;
              --brand:#15171c;--brandfg:#fff;--shadow:0 1px 2px #0000000d,0 8px 24px #0000000a;}
        @media (prefers-color-scheme:dark){
          :root{--bg:#0f1014;--fg:#e9eaee;--sub:#9096a2;--card:#181a20;--line:#282b33;
                --brand:#e9eaee;--brandfg:#15171c;--shadow:0 1px 2px #0006,0 8px 24px #0004;}}
        *{box-sizing:border-box}
        body{margin:0;background:var(--bg);color:var(--fg);
             font:14px/1.6 -apple-system,"PingFang SC","Helvetica Neue",sans-serif}
        header{position:sticky;top:0;z-index:20;background:var(--bg);border-bottom:1px solid var(--line)}
        .wrap{max-width:1240px;margin:0 auto;padding:0 28px}
        .top{display:flex;align-items:center;gap:14px;padding:18px 0 12px}
        .top h1{font-size:17px;margin:0;letter-spacing:-.01em}
        .sp{flex:1}
        .tabs{display:flex;gap:6px;overflow-x:auto;padding-bottom:12px}
        .tab{white-space:nowrap;font:inherit;font-size:12.5px;padding:6px 13px;border-radius:999px;
             border:1px solid var(--line);background:transparent;color:var(--sub);cursor:pointer}
        .tab b{font-weight:600;opacity:.6;margin-left:3px}
        .tab.active{background:var(--brand);color:var(--brandfg);border-color:var(--brand)}
        main{max-width:1240px;margin:0 auto;padding:26px 28px 70px}
        section{display:none}
        section.show{display:block}
        section h2{font-size:15px;margin:0 0 2px}
        .hint{color:var(--sub);font-size:12.5px;margin:0 0 18px}
        .grid{display:grid;gap:18px;grid-template-columns:repeat(auto-fill,minmax(300px,1fr))}
        .card{background:var(--card);border:1px solid var(--line);border-radius:14px;
              overflow:hidden;box-shadow:var(--shadow);display:flex;flex-direction:column}
        .shot,.mock{height:172px;position:relative;background-size:cover;background-position:center}
        .shot.none,.wall.none{display:grid;place-items:center;color:var(--sub);font-size:12px;
              background:repeating-linear-gradient(45deg,#00000010 0 8px,transparent 8px 16px)}
        .wall{position:absolute;inset:0;background-size:cover;background-position:center}
        .chrome{position:relative;height:100%;display:flex}
        .chrome aside{width:92px;padding:9px 7px;background:rgba(24,24,24,.62);
              display:flex;flex-direction:column;gap:5px;color:var(--text)}
        .dots{display:flex;gap:4px;margin-bottom:6px}
        .dots i{width:8px;height:8px;border-radius:50%;background:#ffffff3d}
        .nav{font-size:10.5px;padding:4px 6px;border-radius:5px;color:var(--muted)}
        .nav.on{background:var(--accent);color:#fff}
        .pane{flex:1;padding:10px;background:rgba(24,24,24,.62);display:flex;flex-direction:column;
              gap:6px;border-left:1px solid #ffffff1a;color:var(--text)}
        .b{font-size:10.5px;padding:6px 9px;border-radius:8px;max-width:86%}
        .b.user{align-self:flex-end;background:var(--accent);color:#fff}
        .b.bot{background:#ffffff14}
        .b.bot em{display:block;height:2px;width:38px;margin-top:5px;background:var(--accent);border-radius:2px}
        .composer{margin-top:auto;font-size:10.5px;color:var(--muted);padding:6px 9px;
              border-radius:7px;border:1px solid #ffffff26}
        .body{padding:14px 15px 15px;display:flex;flex-direction:column;gap:8px;flex:1}
        .body h3{font-size:14px;margin:0;display:flex;align-items:center;gap:7px}
        .pill{font-size:10px;padding:2px 7px;border-radius:999px;background:#16a34a;color:#fff;font-weight:500}
        .sub{color:var(--sub);font-size:12px;margin:0;min-height:1.6em;
             display:-webkit-box;-webkit-line-clamp:2;-webkit-box-orient:vertical;overflow:hidden}
        .sw{display:flex;gap:4px}
        .sw i{width:15px;height:15px;border-radius:4px;border:1px solid #00000014}
        .acts{display:flex;gap:7px;margin-top:auto;padding-top:4px}
        .btn{font:inherit;font-size:12px;padding:6px 12px;border-radius:8px;cursor:pointer;
             border:1px solid var(--line);background:transparent;color:var(--fg)}
        .btn.primary{background:var(--brand);color:var(--brandfg);border-color:var(--brand)}
        .btn:disabled{opacity:.5;cursor:default}
        .empty{color:var(--sub)}
        #toast{position:fixed;left:50%;bottom:26px;transform:translateX(-50%) translateY(160%);
               background:var(--brand);color:var(--brandfg);padding:11px 18px;border-radius:11px;
               font-size:13px;box-shadow:var(--shadow);transition:transform .25s;z-index:50;
               display:flex;align-items:center;gap:12px;max-width:82vw}
        #toast.show{transform:translateX(-50%) translateY(0)}
        #toast button{font:inherit;font-size:12px;padding:5px 11px;border-radius:7px;cursor:pointer;
               border:none;background:var(--brandfg);color:var(--brand);white-space:nowrap}
        </style></head><body>
        <header><div class="wrap">
          <div class="top">
            <h1>codex-box 主题库</h1><span class="sp"></span>
            <button class="btn" onclick="restartCodex()">重启 Codex</button>
          </div>
          <div class="tabs">\(tabs.joined())</div>
        </div></header>
        <main>\(sections.joined())\(empty)</main>
        <div id="toast"><span id="tmsg"></span><span id="tact"></span></div>
        <script>
        const tabs=[...document.querySelectorAll('.tab')],secs=[...document.querySelectorAll('section')];
        function show(k){tabs.forEach(t=>t.classList.toggle('active',t.dataset.t===k));
          secs.forEach(s=>s.classList.toggle('show',s.dataset.s===k));}
        tabs.forEach(t=>t.onclick=()=>show(t.dataset.t));
        if(tabs.length){const a=document.querySelector('.tab.active');show(a?a.dataset.t:tabs[0].dataset.t);}
        let timer;
        function toast(msg,label,fn){
          document.getElementById('tmsg').textContent=msg;
          const a=document.getElementById('tact');a.innerHTML='';
          if(label){const b=document.createElement('button');b.textContent=label;
            b.onclick=()=>{a.innerHTML='';fn();};a.appendChild(b);}
          const el=document.getElementById('toast');el.classList.add('show');
          clearTimeout(timer);timer=setTimeout(()=>el.classList.remove('show'),label?15000:4200);
        }
        async function apply(id,wallpaper){
          const bs=[...document.querySelectorAll('.btn')];bs.forEach(b=>b.disabled=true);
          toast(wallpaper?'正在下载并应用（含壁纸，会重启 Codex）…':'正在应用…');
          try{
            const r=await fetch('/apply?id='+encodeURIComponent(id)+'&wallpaper='+wallpaper);
            const j=await r.json();
            if(j.ok){
              toast(j.message, j.needsRestart?'立即重启 Codex':null, j.needsRestart?restartCodex:null);
              // 装完刷新页面，让「已安装」分组同步
              setTimeout(()=>location.reload(), 1600);
            } else { toast(j.message||'失败'); }
          }catch(e){toast('请求失败：'+e);}
          finally{bs.forEach(b=>b.disabled=false);}
        }
        async function restartCodex(){
          toast('正在重启 Codex…');
          try{const r=await fetch('/restart-codex');const j=await r.json();toast(j.message);}
          catch(e){toast('重启失败：'+e);}
        }
        </script></body></html>
        """
    }
}
