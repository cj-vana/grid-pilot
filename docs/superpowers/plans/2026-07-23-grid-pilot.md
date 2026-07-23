# GridPilot Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Native macOS menu-bar app mapping an Intech Grid PBF4 to Spotify/audio/display/Claude-Code actions, with AI-driven natural-language config editing.

**Architecture:** Single SPM executable (AppKit, LSUIElement). Event flow: CoreMIDI → MappingEngine (coalescing + gestures) → ActionRegistry executors. JSON config with hot-reload, learn mode, and an AICustomizer that shells out to `codex exec` / `claude -p` and validates before applying.

**Tech Stack:** Swift 6.4 toolchain (language mode 5), AppKit, CoreMIDI, CoreAudio, NSAppleScript, CGEvent, SMAppService. No third-party dependencies.

## Global Constraints

- macOS 13+ (`platforms: [.macOS(.v13)]`); Apple Silicon primary.
- No third-party Swift dependencies.
- Private APIs (DisplayServices, CoreBrightness) only via `dlopen`/`dlsym`, isolated behind protocols, failure = disable that mapping + log.
- All user-facing errors → log file + menu-bar badge; never modal alert storms.
- Continuous actions coalesced to ≤ 30 Hz, latest-value-wins.
- Config path `~/.config/gridpilot/config.json`; backups `~/.config/gridpilot/backups/<ISO8601>.json`; log `~/Library/Logs/GridPilot.log`.
- Binary named `gridpilot`; with subcommand args runs CLI, with none launches menu-bar app.

---

### Task 1: SPM scaffold + Config model + validation

**Files:** `Package.swift`, `Sources/GridPilot/Core/Config.swift`, `Sources/GridPilot/Core/ConfigValidator.swift`, `Sources/GridPilot/Support/Log.swift`, `Tests/GridPilotTests/ConfigTests.swift`, `.gitignore`

**Interfaces (Produces):**
```swift
struct Config: Codable, Equatable {
  var version: Int                      // 1
  var midi: MIDIConfig                  // deviceName: "Grid", channel: Int? (nil = any)
  var longPressMs: Int                  // 400
  var controls: [String: ControlDef]    // "P1"... ControlDef{cc: Int, kind: .continuous|.button}
  var mappings: [String: Mapping]       // Mapping{action|tap/longPress: ActionSpec}
  var ai: AIConfig                      // provider: "codex"|"claude", codex/claude: {model, effort}
  var notify: NotifyConfig              // midiOut: [NotifyMIDI], flashIcon: Bool
  var contextKeys: [String: [String: KeySpec]]  // action name → bundle id → key
}
struct ActionSpec: Codable, Equatable { var action: String; var params: [String: JSONValue]? }
enum JSONValue: Codable, Equatable { case string(String), number(Double), bool(Bool), array([JSONValue]), object([String: JSONValue]) }
static Config.default -> Config        // full PBF4 approved mapping
func ConfigValidator.validate(_ c: Config) -> [String]  // human-readable problems, empty = ok
```
- [ ] Package.swift (tools 6.0, language mode v5), stub main. `swift build` passes.
- [ ] Tests: default config round-trips through JSON; validator catches unknown action, duplicate CC, missing tap/action, bad param type. RED → implement → GREEN. Commit.

### Task 2: MappingEngine + gestures + coalescing

**Files:** `Sources/GridPilot/Core/MappingEngine.swift`, `Sources/GridPilot/Core/ButtonGesture.swift`, `Sources/GridPilot/Core/Coalescer.swift`, `Tests/GridPilotTests/EngineTests.swift`

**Interfaces (Produces):**
```swift
protocol ActionSink: AnyObject { func run(_ spec: ActionSpec, value: Float?) }  // value ∈ 0...1 for continuous, nil for button fire
final class MappingEngine {
  init(config: Config, sink: ActionSink, clock: @escaping () -> UInt64 = ..., schedule: @escaping (TimeInterval, @escaping () -> Void) -> Void = ...)
  func handle(cc: Int, value: Int, channel: Int)
  func update(config: Config)
}
```
Button semantics: value ≥ 64 press, < 64 release. Long-press fires AT threshold (injectable scheduler for tests); release before threshold = tap on release. Coalescer: per-control trailing-edge throttle 33 ms, injectable clock.
- [ ] Tests: continuous routes with normalized value; coalescer drops intermediate values but always delivers last; tap vs long-press with fake clock/scheduler; unmapped CC ignored; config hot-swap changes routing. TDD. Commit.

### Task 3: MIDI listener with reconnect

**Files:** `Sources/GridPilot/Core/MIDIListener.swift`

**Interfaces:** `final class MIDIListener { init(deviceName: String, onEvent: @escaping (Int, Int, Int) -> Void, onStateChange: @escaping (Bool) -> Void); func start(); func send(bytes: [UInt8]) }` — MIDIClientCreateWithBlock + MIDIInputPortCreateWithProtocol (MIDI 1.0 UMP → parse CC status 0xB). Notification `kMIDIMsgObjectAdded/Removed` triggers rescan. `send` targets the Grid destination for LED/notify.
- [ ] Implement; verified live against hardware later (Task 11). Unit-testable UMP/legacy packet parse extracted as `parseCC(words:)` free function + test. Commit.

### Task 4: Executors A — CoreAudio + system

**Files:** `Sources/GridPilot/Actions/AudioActions.swift`, `Tests/GridPilotTests/ZoneTests.swift`

**Interfaces:**
```swift
enum Audio {  // all AudioObjectSetPropertyData on kAudioObjectSystemObject defaults
  static func setOutputVolume(_ v: Float); static func setInputVolume(_ v: Float)
  static func setAlertVolume(_ v: Float)          // NSSound alert via AppleScript fallback `set volume alert volume`
  static func outputDevices() -> [(id: AudioDeviceID, name: String)]  // devices with output streams, alphabetical, aggregates excluded
  static func setDefaultOutput(_ id: AudioDeviceID)
}
func zoneIndex(value: Float, zones: Int) -> Int   // shared by P3/P4; hysteresis lives in caller (fire only on change)
```
- [ ] `zoneIndex` TDD (edges 0.0/1.0, single zone). Implement audio calls. Commit.

### Task 5: Executors B — AppleScript, keystroke, shell, screenshot

**Files:** `Sources/GridPilot/Actions/ScriptActions.swift`, `Sources/GridPilot/Actions/KeystrokeAction.swift`, `Tests/GridPilotTests/TemplateTests.swift`

**Interfaces:**
```swift
enum Scripts {
  @discardableResult static func runAppleScript(_ src: String) -> Result<String, String>
  static func spotify(_ cmd: String)               // "playpause" | "next track" | "set sound volume to N" | "player position"
  static func newITermTab(command: String)          // creates window if none; writes text
  static func selectITermTab(index: Int)
  static func runShell(_ command: String)           // /bin/zsh -c, async, logged
  static func screenshot(interactive: Bool)         // screencapture -i -c / -c
}
enum Keystroke { static func send(key: KeySpec) }   // CGEvent to HID tap; KeySpec{keyCode: Int, modifiers: [String]}
func substitute(_ template: String, value: Float?) -> String  // {{value}} 0-127 int, {{percent}} 0-100 int, {{float}} 0-1
```
- [ ] `substitute` TDD. Implement executors. Commit.

### Task 6: Executors C — private APIs (brightness, Night Shift)

**Files:** `Sources/GridPilot/Actions/PrivateAPIs.swift`

**Interfaces:** `protocol BrightnessControl { func set(_ v: Float) -> Bool }`; `DisplayServicesBrightness` dlopens `/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices`, dlsym `DisplayServicesSetBrightness` `(int, float) -> int`, main display id 1 via `CGMainDisplayID()`. `NightShift` uses objc runtime: `CBBlueLightClient` from CoreBrightness, `setStrength:commit:`, plus `setEnabled:` true when strength > 0. Both return false (and log once) if symbols missing.
- [ ] Implement; guarded so failure only disables the mapping. Commit.

### Task 7: ActionRegistry + ContextRouter

**Files:** `Sources/GridPilot/Actions/ActionRegistry.swift`, `Sources/GridPilot/Actions/ContextRouter.swift`, `Tests/GridPilotTests/RegistryTests.swift`

**Interfaces:**
```swift
final class ActionRegistry: ActionSink {
  init(config: Config, midiSend: @escaping ([UInt8]) -> Void)
  func run(_ spec: ActionSpec, value: Float?)
  func update(config: Config)
  static let builtins: [String: BuiltinMeta]  // name → {params doc, continuous|button} — drives validator + ai-schema doc gen
}
```
Built-in action names (exact): `displayBrightness, micVolume, systemVolume, alertVolume, spotifyVolume, nightShiftWarmth, itermTabPicker, outputDeviceDial, contextEscape, newClaudeSession, newCodexSession, screenshotRegion, screenshotFull, spotifyPlayPause, spotifyNextTrack, shell, applescript, keystroke, midiSend`.
ContextRouter: `frontmostBundleID()` via NSWorkspace; `contextEscape` looks up `config.contextKeys["contextEscape"][bundleID]` (defaults: iTerm `com.googlecode.iterm2` → Esc 53, ChatGPT `com.openai.chat` → Esc 53), else no-op. Zone actions keep last-index state for hysteresis.
- [ ] Registry TDD with spy executors (shell/applescript/keystroke routed, unknown logged, zone hysteresis). Commit.

### Task 8: ConfigStore (load/save/watch/backup/rollback)

**Files:** `Sources/GridPilot/Core/ConfigStore.swift`, `Tests/GridPilotTests/StoreTests.swift`

**Interfaces:**
```swift
final class ConfigStore {
  init(path: URL = ~/.config/gridpilot/config.json)
  var config: Config { get }
  var onChange: ((Config) -> Void)?
  func loadOrCreate() -> Config           // writes Config.default if missing
  func apply(_ new: Config, backup: Bool) throws
  func rollback() throws -> Config        // most recent backup
  func startWatching()                    // DispatchSource, debounced 300ms, validates before firing
}
```
- [ ] TDD with temp dirs: create-on-missing, backup rotation (keep 20), rollback, invalid hand-edit rejected + logged (keeps old). Commit.

### Task 9: AICustomizer

**Files:** `Sources/GridPilot/AI/AICustomizer.swift`, `Sources/GridPilot/AI/AIPrompt.swift`, `docs/ai-schema.md`, `Tests/GridPilotTests/AITests.swift`

**Interfaces:**
```swift
struct AIResult { var newConfig: Config; var summary: [String]; var raw: String }  // summary = human diff lines
final class AICustomizer {
  init(store: ConfigStore, runner: @escaping (_ argv: [String], _ stdin: String?) -> Result<String, String> = ProcessRunner.run)
  func customize(request: String, completion: @escaping (Result<AIResult, String>) -> Void)  // background queue
  static func argv(for ai: AIConfig, promptFile: URL, outFile: URL) -> [String]
  static func extractJSON(_ raw: String) -> String?    // last ```json fence, else largest {..} balance scan
  static func diffSummary(old: Config, new: Config) -> [String]
}
```
Codex argv: `codex exec -m {model} -c model_reasoning_effort={effort} --sandbox read-only --skip-git-repo-check --ephemeral --color never -o {outFile} -` (prompt on stdin; read result from outFile). Claude argv: `claude -p --model {model} --effort {effort} --output-format json` (prompt on stdin; parse `.result` from JSON envelope). Prompt = `docs/ai-schema.md` (embedded via generated Swift string at build? No codegen: read from bundle-adjacent `Resources/ai-schema.md` via SPM resource) + current config JSON + request + "Reply with ONLY the complete new config JSON in a ```json fence."
Validation chain: extractJSON → decode strict → `ConfigValidator.validate` → compile all `applescript` action sources via `NSAppleScript.compileAndReturnError` (skipped in CLI-less tests) → diffSummary. Apply happens in caller after user confirms.
- [ ] TDD with fake runner: fenced/unfenced/garbage output, validation rejection, claude JSON envelope parse, diff summary wording. Commit.

### Task 10: App shell — menu bar, learn mode, notify, login item, CLI

**Files:** `Sources/GridPilot/main.swift`, `Sources/GridPilot/App/AppDelegate.swift`, `Sources/GridPilot/App/MenuBarController.swift`, `Sources/GridPilot/App/LearnController.swift`, `Sources/GridPilot/App/CustomizeWindow.swift`, `Sources/GridPilot/App/CLI.swift`

**Interfaces:** main: `if CommandLine.arguments.count > 1 → CLI.run(args) exit` else NSApplication + AppDelegate. CLI subcommands: `ai "<request>" [--yes]`, `notify --event <name>`, `learn`, `doctor`, `version`. `notify` posts `DistributedNotificationCenter` name `io.gridpilot.notify`; app listener flashes icon 3s + sends `config.notify.midiOut` bytes. Learn: NSPanel stepping through P1…B4, capturing first *stable new* CC (continuous: ≥3 distinct values; button: 127/0 pair), writes `controls`. Doctor prints: MIDI device found?, AXIsProcessTrusted, screen-capture preflight, Spotify/iTerm installed, codex/claude CLIs on PATH. Menu: status line, Pause ⌘P, Learn…, Customize with AI…, Revert Last AI Change, AI Provider ▸ (codex/claude + model/effort editable via config), Open Config, View Log, Launch at Login (SMAppService.mainApp), Quit.
- [ ] Implement (no unit tests — thin AppKit glue; logic already tested). Build. Commit.

### Task 11: Bundle script + live verification

**Files:** `scripts/make-app.sh`, `scripts/install.sh`

make-app.sh: `swift build -c release`, assemble `dist/GridPilot.app/Contents/{MacOS/gridpilot,Info.plist,Resources/ai-schema.md}`, Info.plist: LSUIElement=true, NSAppleEventsUsageDescription, CFBundleIdentifier `io.gridpilot.app`, min 13.0; `codesign --force --deep -s - dist/GridPilot.app`. install.sh: copy to /Applications, open.
- [ ] Build app, launch, verify: MIDI connect log, menu appears, `gridpilot doctor` output sane. Live-test what TCC allows non-interactively; document the rest as first-run grants. Commit.

### Task 12: Repo polish + publish

**Files:** `README.md`, `CONTRIBUTING.md`, `LICENSE` (MIT), `CHANGELOG.md`, `.github/workflows/ci.yml` (macos-15: swift build + swift test), `.github/ISSUE_TEMPLATE/{bug_report,feature_request}.yml`, `.github/PULL_REQUEST_TEMPLATE.md`, `docs/claude-code-hook-example.md`

README: what/why, hardware, install, learn mode, full default mapping table, AI customize usage + model/effort config, permissions table, Claude Code notify hook snippet, troubleshooting, architecture map for contributors.
- [ ] Write docs; `gh repo create cj-vana/grid-pilot --public --source . --push`; `gh repo edit` description + topics; verify CI green (or fix). Commit(s).

## Self-Review (done)

Spec coverage: mapping (T1 default config, T4-T7 executors), learn (T10), AI layer + model/effort choice (T9, menu in T10), notify/LED (T3 send, T10 listener, T12 hook doc), permissions (T10 doctor, T12 README), errors (Log in T1, isolation in T6), tests (T1,2,4,5,7,8,9), distribution (T11, T12). Placeholders: none — interfaces exact; executor bodies are single-API calls named per Apple SDK. Type consistency: ActionSpec/Config/ActionSink names verified across tasks.
