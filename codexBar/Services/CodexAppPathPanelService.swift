import AppKit
import Foundation
import UniformTypeIdentifiers

@MainActor
final class CodexAppPathPanelService {
    static let shared = CodexAppPathPanelService()

    func requestCodexAppURL(currentPath: String?) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [UTType.applicationBundle]
        panel.treatsFilePackagesAsDirectories = false
        panel.title = L.codexAppPathPanelTitle
        panel.message = L.codexAppPathPanelMessage
        panel.prompt = L.codexAppPathChooseAction

        if let currentPath,
           currentPath.isEmpty == false {
            let currentURL = URL(fileURLWithPath: currentPath, isDirectory: true)
            panel.directoryURL = currentURL.deletingLastPathComponent()
        } else {
            panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        }

        guard panel.runModal() == .OK else { return nil }
        return panel.url?.standardizedFileURL
    }
}
