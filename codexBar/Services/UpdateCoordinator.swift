import AppKit
import Combine
import CryptoKit
import Foundation

private let defaultAutomaticUpdateCheckInterval: TimeInterval = 24 * 60 * 60

enum AppUpdateError: LocalizedError {
    case missingReleasesURL
    case invalidCurrentVersion(String)
    case invalidReleaseVersion(String)
    case invalidResponse
    case unexpectedStatusCode(Int)
    case noInstallableStableRelease
    case noCompatibleArtifact(UpdateArtifactArchitecture)
    case failedToOpenDownloadURL(URL)
    case automaticUpdateUnavailable
    case missingArtifactDigest
    case artifactDigestMismatch
    case updateExtractionFailed(String)
    case updateBundleNotFound
    case invalidUpdateBundle(String)
    case updateInstallPermissionDenied(String)
    case updateHelperLaunchFailed(String)

    var errorDescription: String? {
        switch self {
        case .missingReleasesURL:
            return L.updateErrorMissingReleasesURL
        case let .invalidCurrentVersion(version):
            return L.updateErrorInvalidCurrentVersion(version)
        case let .invalidReleaseVersion(version):
            return L.updateErrorInvalidReleaseVersion(version)
        case .invalidResponse:
            return L.updateErrorInvalidResponse
        case let .unexpectedStatusCode(statusCode):
            return L.updateErrorUnexpectedStatusCode(statusCode)
        case .noInstallableStableRelease:
            return L.updateErrorNoInstallableStableRelease
        case let .noCompatibleArtifact(architecture):
            return L.updateErrorNoCompatibleArtifact(architecture.displayName)
        case let .failedToOpenDownloadURL(url):
            return L.updateErrorFailedToOpenDownloadURL(url.absoluteString)
        case .automaticUpdateUnavailable:
            return L.updateErrorAutomaticUpdateUnavailable
        case .missingArtifactDigest:
            return L.updateErrorMissingArtifactDigest
        case .artifactDigestMismatch:
            return L.updateErrorArtifactDigestMismatch
        case let .updateExtractionFailed(message):
            return L.updateErrorExtractionFailed(message)
        case .updateBundleNotFound:
            return L.updateErrorBundleNotFound
        case let .invalidUpdateBundle(message):
            return L.updateErrorInvalidBundle(message)
        case let .updateInstallPermissionDenied(path):
            return L.updateErrorInstallPermissionDenied(path)
        case let .updateHelperLaunchFailed(message):
            return L.updateErrorHelperLaunchFailed(message)
        }
    }
}

protocol AppUpdateReleaseLoading {
    func loadLatestRelease() async throws -> AppUpdateRelease
}

protocol AppUpdateEnvironmentProviding {
    var currentVersion: String { get }
    var bundleURL: URL { get }
    var architecture: UpdateArtifactArchitecture { get }
    var githubReleasesURL: URL? { get }
}

protocol AppSignatureInspecting {
    func inspect(bundleURL: URL) -> AppSignatureInspection
}

protocol AppGatekeeperInspecting {
    func inspect(bundleURL: URL) -> AppGatekeeperInspection
}

protocol AppUpdateCapabilityEvaluating {
    func blockers(
        for release: AppUpdateRelease,
        environment: AppUpdateEnvironmentProviding
    ) -> [AppUpdateBlocker]
}

protocol AppUpdateActionExecuting {
    func execute(_ availability: AppUpdateAvailability) async throws
}

protocol AppUpdateAutomaticCheckCancelling {
    func cancel()
}

protocol AppUpdateAutomaticCheckScheduling {
    func scheduleRepeating(
        every interval: TimeInterval,
        operation: @escaping @Sendable @MainActor () async -> Void
    ) -> AppUpdateAutomaticCheckCancelling
}

struct AppSignatureInspection: Equatable {
    var hasUsableSignature: Bool
    var summary: String
}

struct AppGatekeeperInspection: Equatable {
    var passesAssessment: Bool
    var summary: String
}

final class TaskBasedAutomaticCheckHandle: AppUpdateAutomaticCheckCancelling {
    private var task: Task<Void, Never>?

    init(task: Task<Void, Never>) {
        self.task = task
    }

    func cancel() {
        self.task?.cancel()
        self.task = nil
    }

    deinit {
        self.cancel()
    }
}

struct TaskBasedAutomaticCheckScheduler: AppUpdateAutomaticCheckScheduling {
    func scheduleRepeating(
        every interval: TimeInterval,
        operation: @escaping @Sendable @MainActor () async -> Void
    ) -> AppUpdateAutomaticCheckCancelling {
        let clampedInterval = max(interval, 1)
        let sleepNanoseconds = UInt64(clampedInterval * 1_000_000_000)

        let task = Task {
            while Task.isCancelled == false {
                do {
                    try await Task.sleep(nanoseconds: sleepNanoseconds)
                } catch {
                    return
                }

                guard Task.isCancelled == false else { return }
                await operation()
            }
        }

        return TaskBasedAutomaticCheckHandle(task: task)
    }
}

struct LiveAppUpdateEnvironment: AppUpdateEnvironmentProviding {
    var currentVersion: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        return version?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? version! : "0.0.0"
    }

    var bundleURL: URL {
        Bundle.main.bundleURL
    }

    var architecture: UpdateArtifactArchitecture {
        #if arch(arm64)
        return .arm64
        #elseif arch(x86_64)
        return .x86_64
        #else
        return .universal
        #endif
    }

    var githubReleasesURL: URL? {
        guard let rawValue = Bundle.main.object(forInfoDictionaryKey: "CodexBarGitHubReleasesURL") as? String,
              rawValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            return nil
        }
        return URL(string: rawValue)
    }
}

struct LiveGitHubReleasesUpdateLoader: AppUpdateReleaseLoading {
    var environment: AppUpdateEnvironmentProviding
    var session: URLSession = .shared

    func loadLatestRelease() async throws -> AppUpdateRelease {
        guard let releasesURL = self.environment.githubReleasesURL else {
            throw AppUpdateError.missingReleasesURL
        }

        var request = URLRequest(url: releasesURL)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("codex-box", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await self.session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw AppUpdateError.invalidResponse
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            throw AppUpdateError.unexpectedStatusCode(httpResponse.statusCode)
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let releases: [GitHubReleaseIndexEntry]

        do {
            releases = try decoder.decode([GitHubReleaseIndexEntry].self, from: data)
        } catch {
            throw AppUpdateError.invalidResponse
        }

        guard let release = GitHubReleaseAdapter.firstInstallableStableRelease(from: releases) else {
            throw AppUpdateError.noInstallableStableRelease
        }

        return release
    }
}

struct LocalCodesignSignatureInspector: AppSignatureInspecting {
    func inspect(bundleURL: URL) -> AppSignatureInspection {
        let output = Self.captureOutput(
            launchPath: "/usr/bin/codesign",
            arguments: ["-dv", "--verbose=4", bundleURL.path]
        )

        let trimmedOutput = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedOutput.isEmpty == false else {
            return AppSignatureInspection(
                hasUsableSignature: false,
                summary: L.updateSignatureUnknown
            )
        }

        let lines = trimmedOutput.split(separator: "\n").map(String.init)
        let signatureLine = lines.first(where: { $0.hasPrefix("Signature=") }) ?? "Signature=unknown"
        let teamLine = lines.first(where: { $0.hasPrefix("TeamIdentifier=") }) ?? "TeamIdentifier=unknown"
        let summary = "\(signatureLine); \(teamLine)"
        let isAdHoc = signatureLine.localizedCaseInsensitiveContains("adhoc")
        let teamMissing = teamLine.localizedCaseInsensitiveContains("not set")

        return AppSignatureInspection(
            hasUsableSignature: isAdHoc == false && teamMissing == false,
            summary: summary
        )
    }

    fileprivate static func captureOutput(
        launchPath: String,
        arguments: [String]
    ) -> String {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: launchPath)
        task.arguments = arguments

        let outputPipe = Pipe()
        task.standardOutput = outputPipe
        task.standardError = outputPipe

        do {
            try task.run()
            task.waitUntilExit()
            let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
            return String(data: data, encoding: .utf8) ?? ""
        } catch {
            return error.localizedDescription
        }
    }
}

struct LocalGatekeeperInspector: AppGatekeeperInspecting {
    func inspect(bundleURL: URL) -> AppGatekeeperInspection {
        let output = LocalCodesignSignatureInspector.captureOutput(
            launchPath: "/usr/sbin/spctl",
            arguments: ["-a", "-vv", bundleURL.path]
        )

        let trimmedOutput = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedOutput.isEmpty == false else {
            return AppGatekeeperInspection(
                passesAssessment: false,
                summary: L.updateSignatureUnknown
            )
        }

        let passesAssessment = trimmedOutput.localizedCaseInsensitiveContains("accepted")
            && trimmedOutput.localizedCaseInsensitiveContains("no usable signature") == false
        let summary = trimmedOutput.split(separator: "\n").prefix(2).joined(separator: " | ")

        return AppGatekeeperInspection(
            passesAssessment: passesAssessment,
            summary: summary
        )
    }
}

struct DefaultAppUpdateCapabilityEvaluator: AppUpdateCapabilityEvaluating {
    var signatureInspector: AppSignatureInspecting
    var gatekeeperInspector: AppGatekeeperInspecting
    var automaticUpdaterAvailable: Bool
    var allowsDigestVerifiedUpdatesWithoutTrustedSignature = false

    func blockers(
        for release: AppUpdateRelease,
        environment: AppUpdateEnvironmentProviding
    ) -> [AppUpdateBlocker] {
        var blockers: [AppUpdateBlocker] = []

        if release.deliveryMode == .guidedDownload {
            blockers.append(.guidedDownloadOnlyRelease)
        }

        if let minimumAutomaticUpdateVersion = release.minimumAutomaticUpdateVersion,
           let currentVersion = AppSemanticVersion(environment.currentVersion),
           let minimumVersion = AppSemanticVersion(minimumAutomaticUpdateVersion),
           currentVersion < minimumVersion {
            blockers.append(
                .bootstrapRequired(
                    currentVersion: environment.currentVersion,
                    minimumAutomaticVersion: minimumAutomaticUpdateVersion
                )
            )
        }

        if self.automaticUpdaterAvailable == false {
            blockers.append(.automaticUpdaterUnavailable)
        }

        let hasPinnedDigests = release.artifacts.isEmpty == false
            && release.artifacts.allSatisfy(\.hasValidSHA256)
        if self.allowsDigestVerifiedUpdatesWithoutTrustedSignature == false || hasPinnedDigests == false {
            let signatureInspection = self.signatureInspector.inspect(bundleURL: environment.bundleURL)
            if signatureInspection.hasUsableSignature == false {
                blockers.append(.missingTrustedSignature(summary: signatureInspection.summary))
            }

            let gatekeeperInspection = self.gatekeeperInspector.inspect(bundleURL: environment.bundleURL)
            if gatekeeperInspection.passesAssessment == false {
                blockers.append(.failingGatekeeperAssessment(summary: gatekeeperInspection.summary))
            }
        }

        let installLocation = Self.installLocation(for: environment.bundleURL)
        if installLocation == .other {
            blockers.append(.unsupportedInstallLocation(installLocation))
        }

        return blockers
    }

    static func installLocation(for bundleURL: URL) -> UpdateInstallLocation {
        let standardizedPath = bundleURL.standardizedFileURL.path
        let homeDirectory = FileManager.default.homeDirectoryForCurrentUser.path
        let userApplications = URL(fileURLWithPath: homeDirectory, isDirectory: true)
            .appendingPathComponent("Applications", isDirectory: true)
            .path

        if standardizedPath.hasPrefix("/Applications/") || standardizedPath == "/Applications" {
            return .applications
        }
        if standardizedPath.hasPrefix(userApplications + "/") || standardizedPath == userApplications {
            return .userApplications
        }
        return .other
    }
}

enum AppUpdateArtifactSelector {
    static func selectArtifact(
        for architecture: UpdateArtifactArchitecture,
        artifacts: [AppUpdateArtifact]
    ) throws -> AppUpdateArtifact {
        let architecturePreference: [UpdateArtifactArchitecture]
        switch architecture {
        case .arm64:
            architecturePreference = [.arm64, .universal]
        case .x86_64:
            architecturePreference = [.x86_64, .universal]
        case .universal:
            architecturePreference = [.universal, .arm64, .x86_64]
        }

        let formatPreference: [UpdateArtifactFormat] = [.dmg, .zip]

        for preferredFormat in formatPreference {
            for preferredArchitecture in architecturePreference {
                if let artifact = artifacts.first(where: {
                    $0.architecture == preferredArchitecture && $0.format == preferredFormat
                }) {
                    return artifact
                }
            }
        }

        throw AppUpdateError.noCompatibleArtifact(architecture)
    }
}

actor AppUpdateInstaller {
    private let fileManager = FileManager.default

    func prepareAndLaunch(
        availability: AppUpdateAvailability,
        currentBundleURL: URL
    ) async throws {
        guard availability.selectedArtifact.hasValidSHA256,
              let expectedDigest = availability.selectedArtifact.sha256?.lowercased() else {
            throw AppUpdateError.missingArtifactDigest
        }

        let workURL = self.fileManager.temporaryDirectory
            .appendingPathComponent("codex-box-update-\(UUID().uuidString)", isDirectory: true)
        try self.fileManager.createDirectory(at: workURL, withIntermediateDirectories: true)

        do {
            let (temporaryDownloadURL, _) = try await URLSession.shared.download(
                from: availability.selectedArtifact.downloadURL
            )
            let payloadURL = workURL.appendingPathComponent(
                "update.\(availability.selectedArtifact.format.rawValue)"
            )
            try self.fileManager.moveItem(at: temporaryDownloadURL, to: payloadURL)

            guard try Self.sha256(of: payloadURL) == expectedDigest else {
                throw AppUpdateError.artifactDigestMismatch
            }

            let extractedBundleURL = try self.extractBundle(
                artifact: availability.selectedArtifact,
                payloadURL: payloadURL,
                workURL: workURL
            )
            try Self.validateBundle(
                extractedBundleURL,
                replacing: currentBundleURL,
                expectedVersion: availability.release.version
            )
            try self.stageAndLaunchHelper(
                extractedBundleURL: extractedBundleURL,
                currentBundleURL: currentBundleURL,
                workURL: workURL
            )
        } catch {
            try? self.fileManager.removeItem(at: workURL)
            throw error
        }
    }

    private func extractBundle(
        artifact: AppUpdateArtifact,
        payloadURL: URL,
        workURL: URL
    ) throws -> URL {
        switch artifact.format {
        case .dmg:
            let mountURL = workURL.appendingPathComponent("mount", isDirectory: true)
            try self.fileManager.createDirectory(at: mountURL, withIntermediateDirectories: true)
            try Self.run(
                "/usr/bin/hdiutil",
                ["attach", "-nobrowse", "-readonly", "-mountpoint", mountURL.path, payloadURL.path]
            )
            defer {
                try? Self.run("/usr/bin/hdiutil", ["detach", mountURL.path, "-force"])
            }
            guard let bundleURL = Self.findAppBundle(in: mountURL) else {
                throw AppUpdateError.updateBundleNotFound
            }
            let extractedURL = workURL.appendingPathComponent("extracted.app", isDirectory: true)
            try Self.run("/usr/bin/ditto", [bundleURL.path, extractedURL.path])
            return extractedURL

        case .zip:
            let extractedRootURL = workURL.appendingPathComponent("extracted", isDirectory: true)
            try self.fileManager.createDirectory(at: extractedRootURL, withIntermediateDirectories: true)
            try Self.run("/usr/bin/ditto", ["-x", "-k", payloadURL.path, extractedRootURL.path])
            guard let bundleURL = Self.findAppBundle(in: extractedRootURL) else {
                throw AppUpdateError.updateBundleNotFound
            }
            return bundleURL
        }
    }

    private func stageAndLaunchHelper(
        extractedBundleURL: URL,
        currentBundleURL: URL,
        workURL: URL
    ) throws {
        let targetURL = currentBundleURL.standardizedFileURL
        let parentURL = targetURL.deletingLastPathComponent()
        guard self.fileManager.isWritableFile(atPath: parentURL.path) else {
            throw AppUpdateError.updateInstallPermissionDenied(parentURL.path)
        }

        let nonce = UUID().uuidString
        let stagedURL = parentURL.appendingPathComponent(".codex-box-update-\(nonce).app", isDirectory: true)
        let backupURL = parentURL.appendingPathComponent(".codex-box-backup-\(nonce).app", isDirectory: true)
        try Self.run("/usr/bin/ditto", [extractedBundleURL.path, stagedURL.path])

        let helperURL = workURL.appendingPathComponent("install-update.zsh")
        try Self.helperScript.write(to: helperURL, atomically: true, encoding: .utf8)
        try self.fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helperURL.path)

        let process = Process()
        process.executableURL = helperURL
        process.arguments = [
            String(ProcessInfo.processInfo.processIdentifier),
            targetURL.path,
            stagedURL.path,
            backupURL.path,
            workURL.path,
        ]
        do {
            try process.run()
        } catch {
            try? self.fileManager.removeItem(at: stagedURL)
            throw AppUpdateError.updateHelperLaunchFailed(error.localizedDescription)
        }
    }

    static func sha256(of fileURL: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let data = try handle.read(upToCount: 1_048_576) ?? Data()
            guard data.isEmpty == false else { break }
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func validateBundle(
        _ candidateURL: URL,
        replacing currentBundleURL: URL,
        expectedVersion: String
    ) throws {
        guard let candidateBundle = Bundle(url: candidateURL),
              let currentBundle = Bundle(url: currentBundleURL) else {
            throw AppUpdateError.invalidUpdateBundle(L.updateValidationUnreadableBundle)
        }
        guard candidateBundle.bundleIdentifier == currentBundle.bundleIdentifier else {
            throw AppUpdateError.invalidUpdateBundle(L.updateValidationBundleIdentifierMismatch)
        }
        let candidateVersion = candidateBundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        guard candidateVersion == expectedVersion else {
            throw AppUpdateError.invalidUpdateBundle(
                L.updateValidationVersionMismatch(candidateVersion ?? "?", expectedVersion)
            )
        }
        do {
            try Self.run("/usr/bin/codesign", ["--verify", "--deep", "--strict", candidateURL.path])
        } catch {
            throw AppUpdateError.invalidUpdateBundle(L.updateValidationCodeSignatureFailed)
        }
    }

    private static func findAppBundle(in rootURL: URL) -> URL? {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey]
        guard let enumerator = FileManager.default.enumerator(
            at: rootURL,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return nil }

        for case let url as URL in enumerator where url.pathExtension.lowercased() == "app" {
            return url
        }
        return nil
    }

    private static func run(_ executable: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let output = String(data: data, encoding: .utf8) ?? ""
            throw AppUpdateError.updateExtractionFailed(
                output.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
    }

    static let helperScript = #"""
    #!/bin/zsh
    set -u
    parent_pid="$1"
    target="$2"
    staged="$3"
    backup="$4"
    work="$5"

    for _ in {1..600}; do
      kill -0 "$parent_pid" 2>/dev/null || break
      sleep 0.1
    done

    if kill -0 "$parent_pid" 2>/dev/null; then
      /bin/rm -rf "$staged" "$work"
      exit 1
    fi

    if [[ -e "$target" ]]; then
      /bin/mv "$target" "$backup" || exit 1
    fi

    if /bin/mv "$staged" "$target"; then
      if [[ "${CODEX_BOX_UPDATE_SKIP_RELAUNCH:-0}" != "1" ]]; then
        /usr/bin/open -n "$target"
      fi
      /bin/rm -rf "$backup" "$work"
      exit 0
    fi

    if [[ -e "$backup" && ! -e "$target" ]]; then
      /bin/mv "$backup" "$target"
      if [[ "${CODEX_BOX_UPDATE_SKIP_RELAUNCH:-0}" != "1" ]]; then
        /usr/bin/open -n "$target"
      fi
    fi
    /bin/rm -rf "$staged" "$work"
    exit 1
    """#
}

struct LiveAppUpdateActionExecutor: AppUpdateActionExecuting {
    var environment: AppUpdateEnvironmentProviding
    var installer = AppUpdateInstaller()

    func execute(_ availability: AppUpdateAvailability) async throws {
        guard availability.isAutomaticUpdateAllowed else {
            guard NSWorkspace.shared.open(availability.selectedArtifact.downloadURL) else {
                throw AppUpdateError.failedToOpenDownloadURL(availability.selectedArtifact.downloadURL)
            }
            return
        }

        try await self.installer.prepareAndLaunch(
            availability: availability,
            currentBundleURL: self.environment.bundleURL
        )
        await MainActor.run {
            NSApp.terminate(nil)
        }
    }
}

@MainActor
final class UpdateCoordinator: ObservableObject {
    static let shared = UpdateCoordinator()

    @Published private(set) var state: UpdateCoordinatorState = .idle
    @Published private(set) var pendingAvailability: AppUpdateAvailability?

    private let releaseLoader: AppUpdateReleaseLoading
    private let environment: AppUpdateEnvironmentProviding
    private let capabilityEvaluator: AppUpdateCapabilityEvaluating
    private let actionExecutor: AppUpdateActionExecuting
    private let automaticCheckScheduler: AppUpdateAutomaticCheckScheduling
    private let automaticCheckInterval: TimeInterval

    private var hasStarted = false
    private var automaticCheckHandle: AppUpdateAutomaticCheckCancelling?

    convenience init() {
        let environment = LiveAppUpdateEnvironment()
        self.init(
            releaseLoader: LiveGitHubReleasesUpdateLoader(environment: environment),
            environment: environment,
            capabilityEvaluator: DefaultAppUpdateCapabilityEvaluator(
                signatureInspector: LocalCodesignSignatureInspector(),
                gatekeeperInspector: LocalGatekeeperInspector(),
                automaticUpdaterAvailable: true,
                allowsDigestVerifiedUpdatesWithoutTrustedSignature: true
            ),
            actionExecutor: LiveAppUpdateActionExecutor(environment: environment),
            automaticCheckScheduler: TaskBasedAutomaticCheckScheduler(),
            automaticCheckInterval: defaultAutomaticUpdateCheckInterval
        )
    }

    convenience init(
        releaseLoader: AppUpdateReleaseLoading,
        environment: AppUpdateEnvironmentProviding,
        capabilityEvaluator: AppUpdateCapabilityEvaluating,
        actionExecutor: AppUpdateActionExecuting
    ) {
        self.init(
            releaseLoader: releaseLoader,
            environment: environment,
            capabilityEvaluator: capabilityEvaluator,
            actionExecutor: actionExecutor,
            automaticCheckScheduler: TaskBasedAutomaticCheckScheduler(),
            automaticCheckInterval: defaultAutomaticUpdateCheckInterval
        )
    }

    init(
        releaseLoader: AppUpdateReleaseLoading,
        environment: AppUpdateEnvironmentProviding,
        capabilityEvaluator: AppUpdateCapabilityEvaluating,
        actionExecutor: AppUpdateActionExecuting,
        automaticCheckScheduler: AppUpdateAutomaticCheckScheduling,
        automaticCheckInterval: TimeInterval
    ) {
        self.releaseLoader = releaseLoader
        self.environment = environment
        self.capabilityEvaluator = capabilityEvaluator
        self.actionExecutor = actionExecutor
        self.automaticCheckScheduler = automaticCheckScheduler
        self.automaticCheckInterval = automaticCheckInterval
    }

    var isChecking: Bool {
        if case .checking = self.state {
            return true
        }
        return false
    }

    func start() {
        guard self.hasStarted == false else { return }
        self.hasStarted = true

        self.automaticCheckHandle = self.automaticCheckScheduler.scheduleRepeating(
            every: self.automaticCheckInterval
        ) { [weak self] in
            guard let self else { return }
            await self.checkForUpdates(trigger: .automaticDaily)
        }

        Task {
            await self.checkForUpdates(trigger: .automaticStartup)
        }
    }

    func stop() {
        self.automaticCheckHandle?.cancel()
        self.automaticCheckHandle = nil
        self.hasStarted = false
    }

    func handleToolbarAction() async {
        if let pendingAvailability = self.pendingAvailability {
            await self.execute(pendingAvailability)
        } else {
            await self.checkForUpdates(trigger: .manual)
        }
    }

    func checkForUpdates(trigger: UpdateCheckTrigger) async {
        guard self.isChecking == false else { return }

        self.state = .checking(trigger)

        do {
            let release = try await self.releaseLoader.loadLatestRelease()
            if let availability = try self.resolveAvailability(from: release) {
                self.pendingAvailability = availability
                self.state = .updateAvailable(availability)
            } else {
                self.pendingAvailability = nil
                self.state = .upToDate(
                    currentVersion: self.environment.currentVersion,
                    checkedVersion: release.version
                )
            }
        } catch {
            let message = error.localizedDescription
            self.state = .failed(message)
        }
    }

    private func resolveAvailability(from release: AppUpdateRelease) throws -> AppUpdateAvailability? {
        guard let currentVersion = AppSemanticVersion(self.environment.currentVersion) else {
            throw AppUpdateError.invalidCurrentVersion(self.environment.currentVersion)
        }
        guard let releaseVersion = AppSemanticVersion(release.version) else {
            throw AppUpdateError.invalidReleaseVersion(release.version)
        }
        guard currentVersion < releaseVersion else {
            return nil
        }

        let selectedArtifact = try AppUpdateArtifactSelector.selectArtifact(
            for: self.environment.architecture,
            artifacts: release.artifacts
        )

        return AppUpdateAvailability(
            currentVersion: self.environment.currentVersion,
            release: release,
            selectedArtifact: selectedArtifact,
            blockers: self.capabilityEvaluator.blockers(
                for: release,
                environment: self.environment
            )
        )
    }

    private func execute(_ availability: AppUpdateAvailability) async {
        self.state = .executing(availability)

        do {
            try await self.actionExecutor.execute(availability)
            self.pendingAvailability = availability
            self.state = .updateAvailable(availability)
        } catch {
            let message = error.localizedDescription
            self.state = .failed(message)
        }
    }
}

private extension UpdateArtifactArchitecture {
    var displayName: String {
        switch self {
        case .arm64:
            return "Apple Silicon"
        case .x86_64:
            return "Intel"
        case .universal:
            return L.updateArchitectureUniversal
        }
    }
}
