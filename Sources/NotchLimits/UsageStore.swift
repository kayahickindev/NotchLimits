import Foundation
import Combine

/// Non-Sendable payload of one cswap fetch attempt, hopped back to the main
/// actor by `refreshNow()`.
private enum FetchOutcome: Sendable {
    case success(CSwapListOutput)
    case failure(String)
}

@MainActor
final class UsageStore: ObservableObject {
    @Published private(set) var accounts: [AccountVM] = []
    @Published private(set) var activeNumber: Int? = nil
    @Published private(set) var lastUpdated: Date? = nil
    @Published private(set) var fetchError: String? = nil
    @Published private(set) var switchingAccount: Int? = nil

    // Scripts/nl-usage is an optional shim that merges `cswap list --json`
    // with OpenAI Codex rate limits, emitting the same wire schema (Codex as
    // account slot 99). Installing it at ~/.local/bin/nl-usage opts in; the
    // resolved path is fixed at process start, like the cswap path always was.
    // NOTCHLIMITS_USAGE_CMD (dev runs) replaces both with any executable that
    // answers `list --json`, such as a script that cats a fixture.
    private nonisolated static let cswapExecutablePath =
        ("~/.local/bin/cswap" as NSString).expandingTildeInPath
    private nonisolated static let listExecutablePath: String = {
        if let command = ProcessInfo.processInfo.environment["NOTCHLIMITS_USAGE_CMD"], !command.isEmpty {
            return (command as NSString).expandingTildeInPath
        }
        let shim = ("~/.local/bin/nl-usage" as NSString).expandingTildeInPath
        if FileManager.default.isExecutableFile(atPath: shim) {
            return shim
        }
        return cswapExecutablePath
    }()
    private nonisolated static let logFilePath =
        ("~/Library/Logs/cswap-auto.log" as NSString).expandingTildeInPath

    /// The three panel columns, in display order.
    enum PanelColumn { case max, team, codex }

    /// Claude Max column: every non-Codex account that isn't a Team seat —
    /// a missing/unknown planTier lands here too, so a row is never dropped.
    var maxAccounts: [AccountVM] { accounts.filter { !$0.isCodex && $0.planTier != "team" } }
    /// Claude Team column: non-Codex accounts tagged "team".
    var teamAccounts: [AccountVM] { accounts.filter { !$0.isCodex && $0.planTier == "team" } }
    /// Codex column: grouped by slot/org, unchanged from the two-column build.
    var codexAccounts: [AccountVM] { accounts.filter(\.isCodex) }

    /// The columns that actually have rows, in order Max, Team, Codex. An
    /// empty group is dropped entirely — its header never renders. One or
    /// zero non-empty groups falls back to the original single list.
    var visibleColumns: [(kind: PanelColumn, accounts: [AccountVM])] {
        var columns: [(PanelColumn, [AccountVM])] = []
        if !maxAccounts.isEmpty { columns.append((.max, maxAccounts)) }
        if !teamAccounts.isEmpty { columns.append((.team, teamAccounts)) }
        if !codexAccounts.isEmpty { columns.append((.codex, codexAccounts)) }
        return columns
    }

    /// 1, 2, or 3 — drives the open width. Zero accounts still reads as one
    /// (an empty single column) so the panel never collapses to nothing.
    var columnCount: Int { max(1, visibleColumns.count) }

    /// Rows in the tallest column: the panel's height follows it.
    var listRowCount: Int {
        visibleColumns.map(\.accounts.count).max() ?? accounts.count
    }

    /// Dedicated background queue for the blocking Process/Pipe work — keeps
    /// it off Swift's cooperative thread pool.
    private let fetchQueue = DispatchQueue(label: "com.hayden.notchlimits.usagefetch", qos: .utility)

    // Lifecycle plumbing only, never touched concurrently: mutated exclusively
    // from main-actor methods below, and read once in deinit after the last
    // reference to self is already gone. nonisolated(unsafe) here avoids a
    // deinit/global-actor isolation landmine without hiding a real race.
    private nonisolated(unsafe) var refreshLoopTask: Task<Void, Never>?
    private nonisolated(unsafe) var debounceTask: Task<Void, Never>?
    private nonisolated(unsafe) var logFileSource: DispatchSourceFileSystemObject?

    deinit {
        refreshLoopTask?.cancel()
        debounceTask?.cancel()
        logFileSource?.cancel()
    }

    func start() {
        refreshNow()
        refreshLoopTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 60_000_000_000)
                if Task.isCancelled { break }
                self?.refreshNow()
            }
        }
        watchLogFile()
    }

    func refreshNow() {
        fetchQueue.async { [weak self] in
            let outcome = UsageStore.runCSwapList()
            Task { @MainActor in
                self?.apply(outcome)
            }
        }
    }

    func switchTo(accountNumber: Int) {
        guard switchingAccount == nil, activeNumber != accountNumber else { return }
        switchingAccount = accountNumber
        let arguments = accounts.first { $0.id == accountNumber }?.switchArguments
            ?? ["switch", String(accountNumber), "--json"]
        fetchQueue.async { [weak self] in
            let outcome: FetchOutcome
            if let error = UsageStore.runCSwapSwitch(arguments: arguments) {
                outcome = .failure(error)
            } else {
                outcome = UsageStore.runCSwapList()
            }
            Task { @MainActor in
                self?.switchingAccount = nil
                self?.apply(outcome)
            }
        }
    }

    private func apply(_ outcome: FetchOutcome) {
        switch outcome {
        case .success(let output):
            // Rows show the full email address, which is already unique, so
            // no disambiguation is needed.
            accounts = (output.accounts ?? [])
                .compactMap(AccountVM.init(wire:))
                .sorted { $0.id < $1.id }
            activeNumber = output.activeAccountNumber
            fetchError = nil
            lastUpdated = Date()
        case .failure(let message):
            // Never blank the panel — keep whatever accounts/lastUpdated we had.
            fetchError = message
        }
    }

    // MARK: - Daemon log watch (instant refresh on switch/poll events)

    private func watchLogFile() {
        let fd = open(Self.logFilePath, O_EVTONLY)
        guard fd >= 0 else { return }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend, .rename, .delete],
            queue: fetchQueue
        )
        // A plain closure here would silently infer this method's MainActor
        // isolation, then trap (EXC_BREAKPOINT) when GCD actually invokes it
        // on `fetchQueue`. Typing it `@Sendable` keeps it queue-agnostic;
        // the real hop to MainActor happens via the Task below.
        let handler: @Sendable () -> Void = { [weak self] in
            Task { @MainActor in
                self?.scheduleDebouncedRefresh()
            }
        }
        source.setEventHandler(handler: handler)
        source.setCancelHandler {
            close(fd)
        }
        source.resume()
        logFileSource = source
    }

    private func scheduleDebouncedRefresh() {
        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled else { return }
            self?.refreshNow()
        }
    }

    // MARK: - cswap process (background queue; runs off the main actor)

    /// stdout may carry a leading upgrade-notice line before the JSON payload
    /// — decode from the first '{' onward. 10s kill timeout via a watchdog
    /// that terminates the process without blocking the read.
    private nonisolated static func runCSwapList() -> FetchOutcome {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: listExecutablePath)
        process.arguments = ["list", "--json"]

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
        } catch {
            return .failure("cswap failed to launch: \(error.localizedDescription)")
        }

        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 10) {
            if process.isRunning {
                process.terminate()
            }
        }

        let outputData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard let rawOutput = String(data: outputData, encoding: .utf8), !rawOutput.isEmpty else {
            return .failure("cswap produced no output (exit \(process.terminationStatus))")
        }
        guard let braceIndex = rawOutput.firstIndex(of: "{") else {
            return .failure("cswap output had no JSON payload")
        }
        guard let jsonData = String(rawOutput[braceIndex...]).data(using: .utf8) else {
            return .failure("could not re-encode cswap JSON")
        }

        do {
            let decoded = try JSONDecoder().decode(CSwapListOutput.self, from: jsonData)
            return .success(decoded)
        } catch {
            return .failure("cswap JSON decode failed: \(error.localizedDescription)")
        }
    }

    /// Returns nil on success, otherwise a short message suitable for the
    /// panel footer. The arguments go straight to cswap as an argv array, so
    /// they never cross a shell or need escaping.
    private nonisolated static func runCSwapSwitch(arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: cswapExecutablePath)
        process.arguments = arguments

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
        } catch {
            return "switch failed to launch: \(error.localizedDescription)"
        }

        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 15) {
            if process.isRunning {
                process.terminate()
            }
        }

        let outputData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let errorData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            for data in [errorData, outputData] {
                let message = String(data: data, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if let message, !message.isEmpty { return message }
            }
            return "switch failed (exit \(process.terminationStatus))"
        }
        guard !outputData.isEmpty else { return "switch produced no output" }
        return nil
    }
}
