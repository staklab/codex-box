import AppKit
import SwiftUI

// MARK: - 运行档案

/// 多账号隔离运行区块。
/// 每个档案有独立的 CODEX_HOME，因此各账号的 auth.json 互不共享，
/// 不会出现 refresh token 相互轮换作废的问题。
struct CodexProfilesSectionView: View {
    @ObservedObject var service: CodexProfileService
    @State private var isCreating = false
    @State private var draftName = ""
    @State private var message: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "person.2.badge.gearshape")
                    .foregroundColor(.secondary)
                Text("运行档案")
                    .font(.caption.weight(.semibold))
                    .foregroundColor(.secondary)
                Spacer(minLength: 0)
                Button {
                    self.isCreating.toggle()
                    self.draftName = ""
                } label: {
                    Image(systemName: self.isCreating ? "xmark.circle" : "plus.circle")
                }
                .buttonStyle(.borderless)
                .help("新建一个使用独立 CODEX_HOME 的运行档案")
            }

            if self.isCreating {
                HStack(spacing: 6) {
                    TextField("档案名称，如：pro 主号", text: self.$draftName)
                        .textFieldStyle(.roundedBorder)
                        .font(.caption)
                    Button("创建") { self.createProfile() }
                        .buttonStyle(.borderless)
                        .disabled(self.draftName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }

            if self.service.profiles.isEmpty {
                Text("尚无档案。新建后可用独立账号并行跑多个项目，互不干扰。")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(self.service.profiles) { profile in
                    CodexProfileRowView(
                        profile: profile,
                        service: self.service,
                        onMessage: { self.message = $0 }
                    )
                }
            }

            if let message = self.message {
                Text(message)
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func createProfile() {
        do {
            let profile = try self.service.createProfile(name: self.draftName)
            self.isCreating = false
            self.draftName = ""
            self.message = "已创建「\(profile.name)」。首次启动后需在该档案里单独登录一次。"
        } catch {
            self.message = error.localizedDescription
        }
    }
}

struct CodexProfileRowView: View {
    let profile: CodexProfile
    @ObservedObject var service: CodexProfileService
    let onMessage: (String) -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 6) {
            VStack(alignment: .leading, spacing: 1) {
                Text(self.profile.name)
                    .font(.caption)
                    .lineLimit(1)
                Text(self.profile.codexHomePath)
                    .font(.system(size: 9))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 0)

            Button {
                self.launch()
            } label: {
                Image(systemName: "play.circle")
            }
            .buttonStyle(.borderless)
            .help("在新终端窗口中以该档案启动 codex")

            if self.isHovering {
                Button {
                    self.remove()
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .help("删除档案（数据移入废纸篓）")
            }
        }
        .padding(.vertical, 2)
        .onHover { self.isHovering = $0 }
    }

    private func launch() {
        do {
            try self.service.launchCLI(profile: self.profile, workingDirectory: nil)
            self.onMessage("已在终端中启动「\(self.profile.name)」")
        } catch {
            self.onMessage(error.localizedDescription)
        }
    }

    private func remove() {
        let alert = NSAlert()
        alert.messageText = "删除档案「\(self.profile.name)」？"
        alert.informativeText = "该档案的 CODEX_HOME 目录会被移入废纸篓，可从废纸篓恢复。"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "删除")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        do {
            try self.service.deleteProfile(id: self.profile.id, removeData: true)
            self.onMessage("已删除「\(self.profile.name)」")
        } catch {
            self.onMessage(error.localizedDescription)
        }
    }
}

// MARK: - 皮肤

struct CodexSkinSectionView: View {
    @ObservedObject var themeService: CodexThemeService
    @ObservedObject var injectionService: CodexSkinInjectionService
    @State private var message: String?
    @State private var isBusy = false
    @State private var needsRestart = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "paintpalette")
                    .foregroundColor(.secondary)
                Text("皮肤")
                    .font(.caption.weight(.semibold))
                    .foregroundColor(.secondary)
                Spacer(minLength: 0)
                if self.themeService.isLoadingMarket || self.isBusy {
                    ProgressView().controlSize(.mini)
                }
                Button {
                    Task { await self.openPreview() }
                } label: {
                    Image(systemName: "eye")
                }
                .buttonStyle(.borderless)
                .disabled(self.themeService.state.installed.isEmpty && self.themeService.listings.isEmpty)
                .help("在浏览器中预览：已安装的 + 市场里可下载的")

                Button {
                    Task { await self.refreshMarket() }
                } label: {
                    Image(systemName: "arrow.clockwise.circle")
                }
                .buttonStyle(.borderless)
                .help("刷新皮肤市场（所有已启用的库）")
            }

            if self.themeService.listings.isEmpty {
                Text("点右上角刷新，从 CodexPlusPlus-Themes 拉取皮肤列表。")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                HStack(spacing: 6) {
                    Text("市场 \(self.themeService.listings.count) 套 · \(self.groupedCount) 个库")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer(minLength: 0)
                    Button("打开主题库") { Task { await self.openPreview() } }
                        .buttonStyle(.borderless)
                        .font(.caption2)
                }

                if self.themeService.lastRefreshIssues.isEmpty == false {
                    Text("部分库拉取失败：" + self.themeService.lastRefreshIssues.joined(separator: "；"))
                        .font(.system(size: 9))
                        .foregroundColor(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            ForEach(self.themeService.state.installed, id: \.id) { installed in
                HStack(spacing: 6) {
                    Text(installed.name)
                        .font(.caption)
                        .lineLimit(1)
                    if self.themeService.state.appliedThemeID == installed.id {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.accentColor)
                            .font(.system(size: 10))
                    }
                    Spacer(minLength: 0)
                    Button("应用") { self.apply(installed.id) }
                        .buttonStyle(.borderless)
                        .font(.caption2)
                    Button {
                        self.uninstall(installed.id)
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                }
                .padding(.vertical, 1)
            }

            if self.themeService.state.installed.isEmpty == false {
                Divider().padding(.vertical, 2)

                Button {
                    Task { await self.enableWallpaper() }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "photo.on.rectangle.angled")
                        Text("启用壁纸（会重启 Codex）")
                    }
                    .font(.caption2)
                }
                .buttonStyle(.borderless)
                .disabled(self.themeService.state.appliedThemeID == nil)

                Text("壁纸需要以调试端口重启 Codex 并注入样式；期间本机进程可控制该窗口。配色部分不依赖此开关。")
                    .font(.system(size: 9))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if self.themeService.state.appliedThemeID != nil {
                    Button("恢复默认配色") { self.revert() }
                        .buttonStyle(.borderless)
                        .font(.caption2)
                }
            }

            if self.needsRestart {
                Button {
                    Task { await self.restartCodex() }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.clockwise")
                        Text("立即重启 Codex 生效")
                    }
                    .font(.caption2.weight(.semibold))
                }
                .buttonStyle(.borderless)
            }

            if let message = self.message {
                Text(message)
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// 只统计库的数量。
    /// 早先这里对全部条目做 Dictionary(grouping:) 并渲染成菜单项，
    /// dreamskin 接入后条目上百，每次弹层渲染都要重算重建——这是弹出卡顿的主因。
    /// 完整浏览交给浏览器主题库，菜单只保留概要。
    private var groupedCount: Int {
        Set(self.themeService.listings.compactMap { $0.sourceName }).count
    }

    private func openPreview() async {
        self.isBusy = true
        defer { self.isBusy = false }
        do {
            try await CodexThemePreviewService.generateAndOpen(themeService: self.themeService)
            self.message = "预览已在浏览器中打开。"
        } catch {
            self.message = error.localizedDescription
        }
    }

    private func refreshMarket() async {
        do {
            try await self.themeService.refreshMarket()
            self.message = "市场已更新：\(self.themeService.listings.count) 套主题"
        } catch {
            self.message = error.localizedDescription
        }
    }

    private func install(_ listing: CodexThemeListing) async {
        self.isBusy = true
        defer { self.isBusy = false }
        do {
            let record = try await self.themeService.install(listing)
            self.message = "已安装「\(record.name)」\(record.hasImage ? "（含壁纸）" : "（无壁纸）")"
        } catch {
            self.message = error.localizedDescription
        }
    }

    /// 应用主题。
    ///
    /// 必须走注入。实测结论：`config.toml` 的 `[desktop.appearance*ChromeTheme]`
    /// **不驱动界面配色**——把 surface 写成 #ff0000 重启后界面仍是默认 #181818，
    /// 那张表只有 `opaqueWindows` 之类的窗口属性会生效。
    /// 真正决定界面的是 `--wb-*` / `--color-background-*` 这组 CSS 变量，
    /// 只能通过 CDP 注入覆盖，所以应用主题必然要重启 Codex 并接入调试端口。
    private func apply(_ id: String) {
        let alert = NSAlert()
        alert.messageText = "应用主题需要重启 Codex"
        alert.informativeText = "Codex 将以调试端口重启，codex-box 通过它注入主题配色与壁纸。\n\n"
            + "说明：Codex 的界面配色无法通过配置文件修改，只能注入——这是换肤的唯一可行方式。"
            + "调试端口开启期间，本机上的任何进程都能控制该窗口；关闭 Codex 后端口即消失。"
        alert.alertStyle = .informational
        alert.addButton(withTitle: "重启并应用")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        Task { await self.applyWithInjection(id) }
    }

    private func applyWithInjection(_ id: String) async {
        self.isBusy = true
        defer { self.isBusy = false }
        do {
            // config.toml 仍然写：opaqueWindows 之类的窗口属性确实由它生效
            try self.themeService.applyNativeColors(themeID: id)

            _ = try await self.injectionService.launchCodexWithDebugging()
            try await self.injectionService.injectSkin(themeID: id, themeService: self.themeService)
            self.needsRestart = false
            self.message = "已应用（Codex 已重启并注入）。"
        } catch {
            self.message = error.localizedDescription
        }
    }


    /// 普通重启 Codex（不带调试端口）。带壁纸的走「启用壁纸」那条路。
    private func restartCodex() async {
        self.isBusy = true
        defer { self.isBusy = false }
        let running = NSWorkspace.shared.runningApplications
            .filter { $0.bundleIdentifier == "com.openai.codex" }
        for application in running { application.terminate() }
        for _ in 0..<40 {
            if NSWorkspace.shared.runningApplications
                .contains(where: { $0.bundleIdentifier == "com.openai.codex" }) == false { break }
            try? await Task.sleep(for: .milliseconds(250))
        }
        guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.openai.codex") else {
            self.message = "找不到 Codex 桌面版"
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        _ = try? await NSWorkspace.shared.openApplication(at: appURL, configuration: configuration)
        self.needsRestart = false
        self.message = "Codex 已重启。"
    }

    private func revert() {
        do {
            try self.themeService.revertNativeColors()
            self.message = "已移除本工具写入的主题表。"
        } catch {
            self.message = error.localizedDescription
        }
    }

    private func uninstall(_ id: String) {
        do {
            try self.themeService.uninstall(id: id)
            self.message = "已卸载。"
        } catch {
            self.message = error.localizedDescription
        }
    }

    private func enableWallpaper() async {
        guard let themeID = self.themeService.state.appliedThemeID else { return }

        let alert = NSAlert()
        alert.messageText = "启用壁纸需要重启 Codex"
        alert.informativeText = """
        Codex 将以远程调试端口重新启动，codex-box 通过该端口注入壁纸样式。

        注意：调试端口开启期间，本机上的任何进程都可以连上去控制该窗口。这是注入式皮肤的固有代价。
        关闭 Codex 后端口即消失；下次普通启动不会带调试端口，也就没有壁纸。
        """
        alert.alertStyle = .warning
        alert.addButton(withTitle: "重启并启用")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        self.isBusy = true
        defer { self.isBusy = false }
        do {
            _ = try await self.injectionService.launchCodexWithDebugging()
            try await self.injectionService.injectSkin(themeID: themeID, themeService: self.themeService)
            self.message = "壁纸已注入。"
        } catch {
            self.message = error.localizedDescription
        }
    }
}

// MARK: - 账号网关

/// 让 Codex 经由 codex-box 本地网关发请求，从而按账号切换而不改写 auth.json。
struct CodexGatewaySectionView: View {
    @ObservedObject var coordinator: CodexGatewayCoordinator
    @ObservedObject var store: TokenStore
    @State private var message: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "arrow.triangle.branch")
                    .foregroundColor(.secondary)
                Text("账号网关")
                    .font(.caption.weight(.semibold))
                    .foregroundColor(.secondary)
                Spacer(minLength: 0)
                Toggle("", isOn: Binding(
                    get: { self.coordinator.isEnabled },
                    set: { self.setEnabled($0) }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
            }

            if self.coordinator.isEnabled {
                Text("Codex 正经由 127.0.0.1:1456 发请求，可在上方账号列表切换。auth.json 不受影响。")
                    .font(.system(size: 9))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Button {
                    self.emergencyRestore()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "exclamationmark.arrow.circlepath")
                        Text("紧急还原为官方直连")
                    }
                    .font(.caption2)
                }
                .buttonStyle(.borderless)
            } else {
                Text("开启后可切换账号发请求。注意：开启期间 Codex 依赖 codex-box 在运行，退出 codex-box 会自动还原。")
                    .font(.system(size: 9))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let message = self.message {
                Text(message)
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func setEnabled(_ enabled: Bool) {
        do {
            if enabled {
                let alert = NSAlert()
                alert.messageText = "开启账号网关？"
                alert.informativeText = """
                Codex 的请求出口会改为 codex-box 的本地网关（127.0.0.1:1456），
                由网关按账号注入凭据——这样切换账号不需要改写 auth.json，
                也就不会再出现两边互相把对方踢下线的情况。

                代价：开启期间 Codex 依赖 codexbar 在运行。codexbar 退出时会自动还原为官方直连。
                """
                alert.alertStyle = .informational
                alert.addButton(withTitle: "开启")
                alert.addButton(withTitle: "取消")
                guard alert.runModal() == .alertFirstButtonReturn else { return }

                try self.coordinator.enable()
                self.message = "已开启。需重启 Codex 才会走新出口。"
            } else {
                try self.coordinator.disable()
                self.message = "已还原为官方直连。需重启 Codex 生效。"
            }
        } catch {
            self.message = error.localizedDescription
        }
    }

    private func emergencyRestore() {
        do {
            try self.coordinator.disable()
            self.message = "已还原为官方直连（model_provider = \"openai\"）。重启 Codex 生效。"
        } catch {
            self.message = error.localizedDescription
        }
    }
}

// MARK: - 启动与持久化

struct CodexStartupSectionView: View {
    @ObservedObject var persistence: CodexSkinPersistenceService
    @State private var message: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "power")
                    .foregroundColor(.secondary)
                Text("启动")
                    .font(.caption.weight(.semibold))
                    .foregroundColor(.secondary)
                Spacer(minLength: 0)
            }

            Toggle(isOn: Binding(
                get: { self.persistence.launchAtLogin },
                set: { self.setLaunchAtLogin($0) }
            )) {
                Text("开机自动启动 codex-box").font(.caption)
            }
            .toggleStyle(.switch)
            .controlSize(.mini)

            Toggle(isOn: self.$persistence.autoReapplyOnStart) {
                Text("启动时自动恢复上次的主题").font(.caption)
            }
            .toggleStyle(.switch)
            .controlSize(.mini)

            Toggle(isOn: self.$persistence.takeOverCodexLaunch) {
                Text("直接打开 Codex 时自动接管并上皮肤").font(.caption)
            }
            .toggleStyle(.switch)
            .controlSize(.mini)

            if self.persistence.takeOverCodexLaunch {
                Text("你直接打开 Codex 后，codex-box 会立即重启它一次以注入主题——这是皮肤能一直在的唯一办法。")
                    .font(.system(size: 9))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let message = self.message {
                Text(message)
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            try self.persistence.setLaunchAtLogin(enabled)
            self.message = enabled ? "已加入登录项。" : "已移出登录项。"
        } catch {
            self.message = "设置失败：\(error.localizedDescription)"
        }
    }
}
