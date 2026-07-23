import Foundation

/// Failures in this layer are plain human-readable strings — they go straight
/// into the customize window / CLI output, never get matched on.
extension String: @retroactive Error {}

struct AIResult {
    var newConfig: Config
    var summary: [String]
    var raw: String
}

enum ProcessRunner {
    /// Runs argv with optional stdin, returns stdout. AI agents think for a
    /// while, so the timeout is generous.
    static func run(_ argv: [String], stdin: String?) -> Result<String, String> {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = argv
        let outPipe = Pipe(), errPipe = Pipe(), inPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        process.standardInput = inPipe
        do {
            try process.run()
        } catch {
            return .failure("could not launch \(argv.first ?? "?"): \(error.localizedDescription)")
        }
        if let stdin {
            inPipe.fileHandleForWriting.write(Data(stdin.utf8))
        }
        try? inPipe.fileHandleForWriting.close()

        let deadline = Date().addingTimeInterval(600)
        // Drain stdout on a reader thread so a chatty agent can't fill the
        // pipe and deadlock us.
        var stdoutData = Data()
        let reader = Thread {
            stdoutData = outPipe.fileHandleForReading.readDataToEndOfFile()
        }
        reader.start()
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.2)
        }
        if process.isRunning {
            process.terminate()
            return .failure("\(argv.first ?? "?") timed out after 10 minutes")
        }
        while reader.isExecuting { Thread.sleep(forTimeInterval: 0.05) }
        let stdout = String(data: stdoutData, encoding: .utf8) ?? ""
        if process.terminationStatus != 0 {
            let err = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            return .failure("exit \(process.terminationStatus): \(err.suffix(400))")
        }
        return .success(stdout)
    }
}

final class AICustomizer {
    private let store: ConfigStore
    private let runner: ([String], String?) -> Result<String, String>
    private let compileAppleScript: Bool

    init(
        store: ConfigStore,
        runner: @escaping ([String], String?) -> Result<String, String> = ProcessRunner.run,
        compileAppleScript: Bool = true
    ) {
        self.store = store
        self.runner = runner
        self.compileAppleScript = compileAppleScript
    }

    /// Builds argv for the configured provider. Codex writes its last message
    /// to `outFile` (clean, no log noise); Claude prints a JSON envelope.
    static func argv(for ai: AIConfig, outFile: URL) -> [String] {
        switch ai.provider {
        case "claude":
            return ["claude", "-p", "--model", ai.claude.model, "--effort", ai.claude.effort,
                    "--output-format", "json"]
        default:
            return ["codex", "exec",
                    "-m", ai.codex.model,
                    "-c", "model_reasoning_effort=\"\(ai.codex.effort)\"",
                    "--sandbox", "read-only",
                    "--skip-git-repo-check",
                    "--ephemeral",
                    "--color", "never",
                    "-o", outFile.path,
                    "-"]
        }
    }

    /// Pulls the config JSON out of agent output: last ```json fence wins,
    /// else the largest brace-balanced object.
    static func extractJSON(_ raw: String) -> String? {
        if let fenced = lastFencedBlock(raw) { return fenced }
        return largestBalancedObject(raw)
    }

    static func diffSummary(old: Config, new: Config) -> [String] {
        var lines: [String] = []
        for name in Config.controlNames {
            let oldMap = old.mappings[name], newMap = new.mappings[name]
            if oldMap != newMap {
                lines.append("\(name): \(describe(oldMap)) → \(describe(newMap))")
            }
            if old.controls[name] != new.controls[name] {
                lines.append("\(name) hardware: cc \(old.controls[name]?.cc ?? -1) → cc \(new.controls[name]?.cc ?? -1)")
            }
        }
        for name in Set(new.mappings.keys).subtracting(Config.controlNames) {
            lines.append("\(name): added \(describe(new.mappings[name]))")
        }
        if old.ai != new.ai { lines.append("ai settings changed") }
        if old.contextKeys != new.contextKeys { lines.append("context key tables changed") }
        if old.notify != new.notify { lines.append("notify/LED settings changed") }
        if old.longPressMs != new.longPressMs { lines.append("longPressMs: \(old.longPressMs) → \(new.longPressMs)") }
        if old.midi != new.midi { lines.append("midi device settings changed") }
        return lines.isEmpty ? ["no effective change"] : lines
    }

    func customize(request: String, completion: @escaping (Result<AIResult, String>) -> Void) {
        let config = store.config
        let prompt = AIPrompt.build(request: request, currentConfig: config)
        let outFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("gridpilot-ai-\(UUID().uuidString).txt")
        let argv = Self.argv(for: config.ai, outFile: outFile)

        // Strong self: the in-flight request keeps the customizer alive until
        // its completion runs, even if the caller drops it.
        DispatchQueue.global(qos: .userInitiated).async {
            defer { try? FileManager.default.removeItem(at: outFile) }
            let outcome = self.runner(argv, prompt)
            let finish: (Result<AIResult, String>) -> Void = { r in DispatchQueue.main.async { completion(r) } }

            switch outcome {
            case .failure(let message):
                finish(.failure(message))
            case .success(let stdout):
                let raw = self.agentMessage(provider: config.ai.provider, stdout: stdout, outFile: outFile)
                guard let json = Self.extractJSON(raw) else {
                    finish(.failure("no JSON found in agent reply:\n\(raw.suffix(400))"))
                    return
                }
                do {
                    let proposed = try Config.decode(Data(json.utf8))
                    let problems = ConfigValidator.validate(proposed)
                    guard problems.isEmpty else {
                        finish(.failure("agent produced invalid config: \(problems.joined(separator: "; "))"))
                        return
                    }
                    if let scriptError = self.checkAppleScripts(in: proposed) {
                        finish(.failure(scriptError))
                        return
                    }
                    let summary = Self.diffSummary(old: config, new: proposed)
                    finish(.success(AIResult(newConfig: proposed, summary: summary, raw: raw)))
                } catch {
                    finish(.failure("agent JSON did not decode: \(error.localizedDescription)"))
                }
            }
        }
    }

    /// Called after the user confirms the diff.
    func apply(_ result: AIResult) throws {
        try store.apply(result.newConfig, backup: true)
        Log.info("AI change applied: \(result.summary.joined(separator: " | "))")
    }

    private func agentMessage(provider: String, stdout: String, outFile: URL) -> String {
        if provider == "claude" {
            // claude -p --output-format json → {"result": "...", ...}
            if let data = stdout.data(using: .utf8),
               let envelope = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let result = envelope["result"] as? String {
                return result
            }
            return stdout
        }
        if let fromFile = try? String(contentsOf: outFile, encoding: .utf8), !fromFile.isEmpty {
            return fromFile
        }
        return stdout
    }

    private func checkAppleScripts(in config: Config) -> String? {
        guard compileAppleScript else { return nil }
        for (name, mapping) in config.mappings {
            for spec in [mapping.action, mapping.tap, mapping.longPress].compactMap({ $0 }) where spec.action == "applescript" {
                guard let source = spec.string("source") else { continue }
                // Compile with placeholder values so templates don't trip the parser.
                let compiled = substitute(source, value: 0.5)
                var error: NSDictionary?
                if NSAppleScript(source: compiled)?.compileAndReturnError(&error) != true {
                    let message = error?[NSAppleScript.errorMessage] as? String ?? "syntax error"
                    return "AppleScript in \(name) does not compile: \(message)"
                }
            }
        }
        return nil
    }

    private static func describe(_ mapping: Mapping?) -> String {
        guard let mapping else { return "(unmapped)" }
        var parts: [String] = []
        if let a = mapping.action { parts.append(a.action) }
        if let t = mapping.tap { parts.append("tap:\(t.action)") }
        if let l = mapping.longPress { parts.append("hold:\(l.action)") }
        return parts.isEmpty ? "(empty)" : parts.joined(separator: ", ")
    }

    private static func lastFencedBlock(_ raw: String) -> String? {
        let pattern = "```(?:json)?\\s*\\n([\\s\\S]*?)```"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let matches = regex.matches(in: raw, range: NSRange(raw.startIndex..., in: raw))
        guard let last = matches.last, let range = Range(last.range(at: 1), in: raw) else { return nil }
        let candidate = String(raw[range]).trimmingCharacters(in: .whitespacesAndNewlines)
        return candidate.hasPrefix("{") ? candidate : nil
    }

    private static func largestBalancedObject(_ raw: String) -> String? {
        var best: String?
        var depth = 0
        var start: String.Index?
        var inString = false
        var escaped = false
        for index in raw.indices {
            let char = raw[index]
            if escaped { escaped = false; continue }
            switch char {
            case "\\" where inString: escaped = true
            case "\"": inString.toggle()
            case "{" where !inString:
                if depth == 0 { start = index }
                depth += 1
            case "}" where !inString:
                depth -= 1
                if depth == 0, let s = start {
                    let candidate = String(raw[s...index])
                    if candidate.count > (best?.count ?? 0) { best = candidate }
                }
            default: break
            }
        }
        return best
    }
}
