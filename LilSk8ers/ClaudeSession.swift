import Foundation

enum AgentProvider: String, CaseIterable {
    case claudeCode = "claude_code"
    case openAICodex = "openai_codex"

    static let defaultsKey = "selectedProvider"
    static let softTokenBudget = 100_000

    var menuTitle: String {
        switch self {
        case .claudeCode:
            return "Claude Code"
        case .openAICodex:
            return "OpenAI (Codex)"
        }
    }

    var badgeTitle: String {
        switch self {
        case .claudeCode:
            return "CLAUDE"
        case .openAICodex:
            return "OPENAI"
        }
    }

    var placeholder: String {
        switch self {
        case .claudeCode:
            return "Ask Claude Code..."
        case .openAICodex:
            return "Ask OpenAI..."
        }
    }

    var missingInstallMessage: String {
        switch self {
        case .claudeCode:
            return """
            Claude Code CLI not found.

            To install, run this in Terminal:
              curl -fsSL https://claude.ai/install.sh | sh

            Or download from https://claude.ai/download
            """
        case .openAICodex:
            return """
            OpenAI Codex CLI not found.

            Make sure `codex` is installed and available on your shell PATH.
            """
        }
    }

    var launchFailureMessage: String {
        switch self {
        case .claudeCode:
            return """
            Failed to launch Claude Code CLI.

            Make sure Claude Code is installed and up to date:
              curl -fsSL https://claude.ai/install.sh | sh
            """
        case .openAICodex:
            return """
            Failed to launch OpenAI Codex CLI.

            Make sure `codex` is installed and authenticated.
            """
        }
    }

    var executableName: String {
        switch self {
        case .claudeCode:
            return "claude"
        case .openAICodex:
            return "codex"
        }
    }

    var fallbackPaths: [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        switch self {
        case .claudeCode:
            return [
                "\(home)/.local/bin/claude",
                "\(home)/.claude/local/bin/claude",
                "/usr/local/bin/claude",
                "/opt/homebrew/bin/claude"
            ]
        case .openAICodex:
            return [
                "\(home)/.local/bin/codex",
                "/usr/local/bin/codex",
                "/opt/homebrew/bin/codex"
            ]
        }
    }

    var usageBudgetTokens: Int { Self.softTokenBudget }

    static var current: AgentProvider {
        guard let raw = UserDefaults.standard.string(forKey: defaultsKey),
              let provider = AgentProvider(rawValue: raw) else {
            return .claudeCode
        }
        return provider
    }

    static func setCurrent(_ provider: AgentProvider) {
        UserDefaults.standard.set(provider.rawValue, forKey: defaultsKey)
    }
}

final class AgentSession {
    struct UsageSnapshot {
        let provider: AgentProvider
        let sessionAge: TimeInterval
        let completedTurns: Int
        let estimatedContextTokens: Int
        let contextBudgetTokens: Int
        let estimatedContextPercent: Double
        let lastTurnDuration: TimeInterval?
        let liveTurnDuration: TimeInterval?
        let lastTurnInputTokens: Int
        let lastTurnOutputTokens: Int
        let currentTurnInputTokens: Int
        let currentTurnOutputTokens: Int
        let totalInputTokens: Int
        let totalOutputTokens: Int
        let isBusy: Bool
        let pendingMessages: Int
    }

    private var process: Process?
    private var inputPipe: Pipe?
    private var outputPipe: Pipe?
    private var errorPipe: Pipe?
    private var lineBuffer = ""
    private var pendingMessages: [String] = []
    private var codexStderr = ""
    private var resolvedCLIPath: String?
    private(set) var isRunning = false
    private(set) var isBusy = false
    private var isStarting = false
    private var isReadyForMessages = false
    private var sessionResetAt = Date()
    private var currentTurnStartedAt: Date?
    private var currentAssistantTurnText = ""
    private var currentTurnInputTokens = 0
    private var currentTurnOutputTokens = 0
    private var lastTurnInputTokens = 0
    private var lastTurnOutputTokens = 0
    private var lastTurnDuration: TimeInterval?
    private var totalInputTokens = 0
    private var totalOutputTokens = 0
    private var completedTurns = 0

    static private var resolvedPaths: [AgentProvider: String] = [:]
    static private var shellEnvironment: [String: String]?

    let provider: AgentProvider

    var onText: ((String) -> Void)?
    var onError: ((String) -> Void)?
    var onToolUse: ((String, [String: Any]) -> Void)?
    var onToolResult: ((String, Bool) -> Void)?
    var onSessionReady: (() -> Void)?
    var onTurnComplete: (() -> Void)?
    var onProcessExit: (() -> Void)?
    var onUsageChanged: ((UsageSnapshot) -> Void)?

    struct Message {
        enum Role { case user, assistant, error, toolUse, toolResult }
        let role: Role
        let text: String
    }
    var history: [Message] = []

    init(provider: AgentProvider = AgentProvider.current) {
        self.provider = provider
    }

    var usageSnapshot: UsageSnapshot {
        makeUsageSnapshot()
    }

    // MARK: - Process Lifecycle

    static private func captureShellEnvironment(completion: @escaping ([String: String]) -> Void) {
        if let env = shellEnvironment {
            completion(env)
            return
        }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/zsh")
        proc.arguments = ["-l", "-i", "-c", "echo '---ENV_START---' && env && echo '---ENV_END---'"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = Pipe()
        proc.terminationHandler = { _ in
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8) ?? ""
            DispatchQueue.main.async {
                var env: [String: String] = ProcessInfo.processInfo.environment
                if let startRange = output.range(of: "---ENV_START---\n"),
                   let endRange = output.range(of: "\n---ENV_END---") {
                    let envString = String(output[startRange.upperBound..<endRange.lowerBound])
                    for line in envString.components(separatedBy: "\n") {
                        guard let eqRange = line.range(of: "=") else { continue }
                        let key = String(line[line.startIndex..<eqRange.lowerBound])
                        let value = String(line[eqRange.upperBound...])
                        env[key] = value
                    }
                }
                shellEnvironment = env
                completion(env)
            }
        }

        do {
            try proc.run()
        } catch {
            let env = ProcessInfo.processInfo.environment
            shellEnvironment = env
            completion(env)
        }
    }

    static func resolveCLIPath(for provider: AgentProvider, completion: @escaping (String?) -> Void) {
        if let cached = resolvedPaths[provider], shellEnvironment != nil {
            completion(cached)
            return
        }

        captureShellEnvironment { env in
            if let shellPath = env["PATH"] {
                for dir in shellPath.components(separatedBy: ":") where !dir.isEmpty {
                    let candidate = "\(dir)/\(provider.executableName)"
                    if FileManager.default.isExecutableFile(atPath: candidate) {
                        resolvedPaths[provider] = candidate
                        completion(candidate)
                        return
                    }
                }
            }

            for fallback in provider.fallbackPaths where FileManager.default.isExecutableFile(atPath: fallback) {
                resolvedPaths[provider] = fallback
                completion(fallback)
                return
            }

            completion(nil)
        }
    }

    func start() {
        guard !isRunning, !isStarting else { return }
        isStarting = true
        notifyUsageChanged()

        AgentSession.resolveCLIPath(for: provider) { [weak self] path in
            guard let self = self else { return }
            self.isStarting = false

            guard let cliPath = path else {
                self.pendingMessages.removeAll()
                self.handleError(self.provider.missingInstallMessage)
                self.notifyUsageChanged()
                return
            }

            self.resolvedCLIPath = cliPath

            switch self.provider {
            case .claudeCode:
                self.launchClaudeProcess(cliPath)
            case .openAICodex:
                self.isRunning = true
                self.isReadyForMessages = true
                self.onSessionReady?()
                self.notifyUsageChanged()
                self.flushPendingMessagesIfPossible()
            }
        }
    }

    private func launchClaudeProcess(_ cliPath: String) {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: cliPath)
        proc.arguments = [
            "-p",
            "--output-format", "stream-json",
            "--input-format", "stream-json",
            "--verbose",
            "--dangerously-skip-permissions"
        ]
        proc.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        proc.environment = sessionEnvironment()

        let inPipe = Pipe()
        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardInput = inPipe
        proc.standardOutput = outPipe
        proc.standardError = errPipe

        proc.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async {
                self?.isRunning = false
                self?.isBusy = false
                self?.isReadyForMessages = false
                self?.notifyUsageChanged()
                self?.onProcessExit?()
            }
        }

        outPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            if let text = String(data: data, encoding: .utf8) {
                DispatchQueue.main.async {
                    self?.processClaudeOutput(text)
                }
            }
        }

        errPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            if let text = String(data: data, encoding: .utf8) {
                DispatchQueue.main.async {
                    self?.handleError(text)
                }
            }
        }

        do {
            try proc.run()
            process = proc
            inputPipe = inPipe
            outputPipe = outPipe
            errorPipe = errPipe
            isRunning = true
            notifyUsageChanged()
        } catch {
            let msg = "\(provider.launchFailureMessage)\n\nError: \(error.localizedDescription)"
            handleError(msg)
        }
    }

    func send(message: String) {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        guard isRunning, isReadyForMessages, !isBusy else {
            pendingMessages.append(trimmed)
            if !isRunning, !isStarting {
                start()
            }
            return
        }

        isBusy = true
        history.append(Message(role: .user, text: trimmed))
        currentTurnStartedAt = Date()
        currentAssistantTurnText = ""
        currentTurnInputTokens = currentContextTokenEstimate()
        currentTurnOutputTokens = 0
        notifyUsageChanged()

        switch provider {
        case .claudeCode:
            sendToClaude(trimmed)
        case .openAICodex:
            sendToCodex()
        }
    }

    private func sendToClaude(_ message: String) {
        guard let pipe = inputPipe else {
            isBusy = false
            pendingMessages.insert(message, at: 0)
            notifyUsageChanged()
            return
        }

        let payload: [String: Any] = [
            "type": "user",
            "message": [
                "role": "user",
                "content": message
            ]
        ]

        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let jsonStr = String(data: data, encoding: .utf8) else {
            isBusy = false
            notifyUsageChanged()
            return
        }

        pipe.fileHandleForWriting.write((jsonStr + "\n").data(using: .utf8)!)
    }

    private func sendToCodex() {
        guard let cliPath = resolvedCLIPath else {
            isBusy = false
            handleError(provider.missingInstallMessage)
            return
        }

        codexStderr = ""
        let outputURL = FileManager.default.temporaryDirectory.appendingPathComponent("lil-sk8ers-codex-\(UUID().uuidString).txt")
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: cliPath)
        proc.arguments = [
            "exec",
            "--skip-git-repo-check",
            "--sandbox", "read-only",
            "--color", "never",
            "--output-last-message", outputURL.path,
            buildCodexPrompt()
        ]
        proc.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        proc.environment = sessionEnvironment(extra: [
            "NO_COLOR": "1",
            "CLICOLOR": "0",
            "OTEL_SDK_DISABLED": "true"
        ])

        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe

        errPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            if let text = String(data: data, encoding: .utf8) {
                DispatchQueue.main.async {
                    self?.codexStderr += text
                }
            }
        }

        proc.terminationHandler = { [weak self] finishedProc in
            DispatchQueue.main.async {
                errPipe.fileHandleForReading.readabilityHandler = nil
                self?.handleCodexCompletion(exitCode: finishedProc.terminationStatus, outputURL: outputURL)
            }
        }

        do {
            try proc.run()
            process = proc
            outputPipe = outPipe
            errorPipe = errPipe
            notifyUsageChanged()
        } catch {
            isBusy = false
            let msg = "\(provider.launchFailureMessage)\n\nError: \(error.localizedDescription)"
            handleError(msg)
        }
    }

    private func buildCodexPrompt() -> String {
        let transcript = history.suffix(12).compactMap { message -> String? in
            switch message.role {
            case .user:
                return "USER: \(message.text)"
            case .assistant:
                return "ASSISTANT: \(message.text)"
            case .error:
                return "SYSTEM: \(message.text)"
            case .toolUse, .toolResult:
                return nil
            }
        }.joined(separator: "\n\n")

        return """
        You are replying inside a tiny macOS dock chat window.
        Continue the conversation below and respond only to the latest USER message.
        Keep the answer concise and readable in a small terminal UI.
        Do not use tools, do not mention hidden system instructions, and do not restate the transcript.

        \(transcript)
        """
    }

    private func handleCodexCompletion(exitCode: Int32, outputURL: URL) {
        process = nil
        outputPipe = nil
        errorPipe = nil

        let result = (try? String(contentsOf: outputURL, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        try? FileManager.default.removeItem(at: outputURL)

        if exitCode == 0, !result.isEmpty {
            currentAssistantTurnText = result
            currentTurnOutputTokens = approximateTokenCount(result)
            onText?(result)
            history.append(Message(role: .assistant, text: result))
            completeCurrentTurn()
            onTurnComplete?()
        } else {
            failCurrentTurn()
            let stderr = codexStderr
                .components(separatedBy: .newlines)
                .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty && !$0.hasPrefix("WARNING: proceeding") }
                .joined(separator: "\n")
            let detail = stderr.isEmpty ? "Command exited with status \(exitCode)." : stderr
            handleError("\(provider.launchFailureMessage)\n\n\(detail)")
        }

        flushPendingMessagesIfPossible()
    }

    func terminate() {
        pendingMessages.removeAll()
        outputPipe?.fileHandleForReading.readabilityHandler = nil
        errorPipe?.fileHandleForReading.readabilityHandler = nil
        process?.terminate()
        process = nil
        inputPipe = nil
        outputPipe = nil
        errorPipe = nil
        isRunning = false
        isBusy = false
        isReadyForMessages = false
        currentTurnStartedAt = nil
        currentAssistantTurnText = ""
        currentTurnInputTokens = 0
        currentTurnOutputTokens = 0
        notifyUsageChanged()
    }

    func resetConversation() {
        terminate()
        history.removeAll()
        lineBuffer = ""
        codexStderr = ""
        sessionResetAt = Date()
        lastTurnDuration = nil
        lastTurnInputTokens = 0
        lastTurnOutputTokens = 0
        totalInputTokens = 0
        totalOutputTokens = 0
        completedTurns = 0
        notifyUsageChanged()
    }

    // MARK: - Claude NDJSON Parsing

    private func processClaudeOutput(_ text: String) {
        lineBuffer += text
        while let newlineRange = lineBuffer.range(of: "\n") {
            let line = String(lineBuffer[lineBuffer.startIndex..<newlineRange.lowerBound])
            lineBuffer = String(lineBuffer[newlineRange.upperBound...])
            if !line.isEmpty {
                parseClaudeLine(line)
            }
        }
    }

    private func parseClaudeLine(_ line: String) {
        guard let data = line.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }

        let type = json["type"] as? String ?? ""

        switch type {
        case "system":
            let subtype = json["subtype"] as? String ?? ""
            if subtype == "init" {
                isReadyForMessages = true
                onSessionReady?()
                notifyUsageChanged()
                flushPendingMessagesIfPossible()
            }

        case "assistant":
            if let message = json["message"] as? [String: Any],
               let content = message["content"] as? [[String: Any]] {
                for block in content {
                    let blockType = block["type"] as? String ?? ""
                    if blockType == "text", let text = block["text"] as? String {
                        currentAssistantTurnText += text
                        currentTurnOutputTokens = approximateTokenCount(currentAssistantTurnText)
                        onText?(text)
                    } else if blockType == "tool_use" {
                        let toolName = block["name"] as? String ?? "Tool"
                        let input = block["input"] as? [String: Any] ?? [:]
                        let summary = formatToolSummary(toolName: toolName, input: input)
                        history.append(Message(role: .toolUse, text: "\(toolName): \(summary)"))
                        onToolUse?(toolName, input)
                    }
                }
                notifyUsageChanged()
            }

        case "user":
            if let message = json["message"] as? [String: Any],
               let content = message["content"] as? [[String: Any]] {
                for block in content where block["type"] as? String == "tool_result" {
                    let isError = block["is_error"] as? Bool ?? false
                    var summary = ""
                    if let resultInfo = json["tool_use_result"] as? [String: Any] {
                        if let text = resultInfo["type"] as? String, text == "text" {
                            if let file = resultInfo["file"] as? [String: Any],
                               let path = file["filePath"] as? String {
                                let lines = file["totalLines"] as? Int ?? 0
                                summary = "\(path) (\(lines) lines)"
                            }
                        }
                    } else if let resultStr = json["tool_use_result"] as? String {
                        summary = String(resultStr.prefix(80))
                    }
                    if summary.isEmpty, let contentStr = block["content"] as? String {
                        summary = String(contentStr.prefix(80))
                    }
                    history.append(Message(role: .toolResult, text: isError ? "ERROR: \(summary)" : summary))
                    onToolResult?(summary, isError)
                }
                notifyUsageChanged()
            }

        case "result":
            let result = (json["result"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let finalAssistantText = result.isEmpty
                ? currentAssistantTurnText.trimmingCharacters(in: .whitespacesAndNewlines)
                : result
            if !finalAssistantText.isEmpty {
                history.append(Message(role: .assistant, text: finalAssistantText))
            }
            completeCurrentTurn()
            onTurnComplete?()
            flushPendingMessagesIfPossible()

        default:
            break
        }
    }

    private func formatToolSummary(toolName: String, input: [String: Any]) -> String {
        switch toolName {
        case "Bash":
            return input["command"] as? String ?? ""
        case "Read":
            return input["file_path"] as? String ?? ""
        case "Edit", "Write":
            return input["file_path"] as? String ?? ""
        case "Glob":
            return input["pattern"] as? String ?? ""
        case "Grep":
            return input["pattern"] as? String ?? ""
        default:
            if let desc = input["description"] as? String { return desc }
            return input.keys.sorted().prefix(3).joined(separator: ", ")
        }
    }

    private func sessionEnvironment(extra: [String: String] = [:]) -> [String: String] {
        var env = AgentSession.shellEnvironment ?? ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let essentialPaths = [
            "\(home)/.local/bin",
            "\(home)/.local/share/claude/versions",
            "/usr/local/bin",
            "/opt/homebrew/bin"
        ]
        let currentPath = env["PATH"] ?? "/usr/bin:/bin"
        let missingPaths = essentialPaths.filter { !currentPath.contains($0) }
        if !missingPaths.isEmpty {
            env["PATH"] = (missingPaths + [currentPath]).joined(separator: ":")
        }
        env["TERM"] = "dumb"
        extra.forEach { env[$0.key] = $0.value }
        return env
    }

    private func handleError(_ message: String) {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        onError?(trimmed)
        history.append(Message(role: .error, text: trimmed))
        notifyUsageChanged()
    }

    private func flushPendingMessagesIfPossible() {
        guard isRunning, isReadyForMessages, !isBusy, !pendingMessages.isEmpty else { return }
        let next = pendingMessages.removeFirst()
        notifyUsageChanged()
        send(message: next)
    }

    private func completeCurrentTurn() {
        isBusy = false
        if let startedAt = currentTurnStartedAt {
            lastTurnDuration = Date().timeIntervalSince(startedAt)
        }
        lastTurnInputTokens = currentTurnInputTokens
        lastTurnOutputTokens = currentTurnOutputTokens
        totalInputTokens += currentTurnInputTokens
        totalOutputTokens += currentTurnOutputTokens
        completedTurns += 1
        currentTurnStartedAt = nil
        currentTurnInputTokens = 0
        currentTurnOutputTokens = 0
        currentAssistantTurnText = ""
        notifyUsageChanged()
    }

    private func failCurrentTurn() {
        isBusy = false
        if let startedAt = currentTurnStartedAt {
            lastTurnDuration = Date().timeIntervalSince(startedAt)
        }
        currentTurnStartedAt = nil
        currentTurnInputTokens = 0
        currentTurnOutputTokens = 0
        currentAssistantTurnText = ""
        notifyUsageChanged()
    }

    private func notifyUsageChanged() {
        onUsageChanged?(makeUsageSnapshot())
    }

    private func makeUsageSnapshot(referenceDate: Date = Date()) -> UsageSnapshot {
        let estimatedContextTokens = currentContextTokenEstimate()
        let budget = provider.usageBudgetTokens
        let percent = budget > 0 ? Double(estimatedContextTokens) / Double(budget) : 0
        let liveTurnDuration = currentTurnStartedAt.map { referenceDate.timeIntervalSince($0) }

        return UsageSnapshot(
            provider: provider,
            sessionAge: referenceDate.timeIntervalSince(sessionResetAt),
            completedTurns: completedTurns,
            estimatedContextTokens: estimatedContextTokens,
            contextBudgetTokens: budget,
            estimatedContextPercent: percent,
            lastTurnDuration: lastTurnDuration,
            liveTurnDuration: liveTurnDuration,
            lastTurnInputTokens: lastTurnInputTokens,
            lastTurnOutputTokens: lastTurnOutputTokens,
            currentTurnInputTokens: currentTurnInputTokens,
            currentTurnOutputTokens: currentTurnOutputTokens,
            totalInputTokens: totalInputTokens,
            totalOutputTokens: totalOutputTokens,
            isBusy: isBusy,
            pendingMessages: pendingMessages.count
        )
    }

    private func currentContextTokenEstimate() -> Int {
        switch provider {
        case .openAICodex:
            return approximateTokenCount(buildCodexPrompt())
        case .claudeCode:
            return approximateTokenCount(buildUsageTranscript())
        }
    }

    private func buildUsageTranscript() -> String {
        history.map { message in
            switch message.role {
            case .user:
                return "USER: \(message.text)"
            case .assistant:
                return "ASSISTANT: \(message.text)"
            case .error:
                return "SYSTEM: \(message.text)"
            case .toolUse:
                return "TOOL: \(message.text)"
            case .toolResult:
                return "RESULT: \(message.text)"
            }
        }.joined(separator: "\n\n")
    }

    private func approximateTokenCount(_ text: String) -> Int {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return 0 }
        return max(1, Int(ceil(Double(trimmed.count) / 4.0)))
    }
}

typealias ClaudeSession = AgentSession
