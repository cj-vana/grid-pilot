import Foundation

enum AIPrompt {
    /// The schema reference sent to the model. `gridpilot schema` prints this
    /// so docs/ai-schema.md never drifts from what the AI actually sees.
    static var schemaDoc: String {
        let actionDocs = Builtins.all
            .sorted { $0.key < $1.key }
            .map { name, meta -> String in
                let kind: String
                switch meta.input {
                case .continuous: kind = "continuous (fader/pot)"
                case .trigger: kind = "button"
                case .either: kind = "any control"
                }
                let params = meta.requiredParams.isEmpty ? "" : " Required params: \(meta.requiredParams.joined(separator: ", "))."
                return "- `\(name)` [\(kind)]: \(meta.doc)\(params)"
            }
            .joined(separator: "\n")

        return """
        # GridPilot config schema

        The config is a single JSON object controlling how an Intech Grid PBF4 MIDI
        controller drives macOS. Controls are named P1-P4 (pots), F1-F4 (faders),
        B1-B4 (buttons).

        Top-level keys (all required):
        - `version`: must be 1.
        - `midi`: `{ "deviceName": string, "channel": int|null }` — null channel = any.
        - `longPressMs`: 100-2000, button hold threshold.
        - `controls`: map of control name → `{ "cc": 0-127, "kind": "continuous"|"button", "type": "cc"|"note" }`.
          `cc` is the CC or note number; `type` says which (Grid buttons send notes).
          type+number pairs must be unique. Do not change these unless asked — they
          were captured from the physical device by learn mode.
        - `mappings`: map of control name → mapping.
          Continuous controls: `{ "action": ActionSpec }`.
          Buttons: `{ "tap": ActionSpec?, "longPress": ActionSpec? }` (at least one).
        - `ai`: `{ "provider": "codex"|"claude", "codex": {"model": string, "effort": string}, "claude": {...} }`.
        - `notify`: `{ "flashIcon": bool, "midiOut": [{"cc": int, "value": int, "channel": int}] }` —
          CCs sent to the Grid when `gridpilot notify` fires (LED feedback).
        - `contextKeys`: action name → bundle id → `{ "keyCode": int, "modifiers": [string]? }`.
          Used by context-aware actions; apps not listed are no-ops.
        - `call` (optional): incoming-call mode. `{ "enabled": bool, "ringTimeoutSec": int,
          "flashLEDs": bool, "apps": { bundleId: { "name": string, "answerKey": KeySpec|null } } }`.
          While a configured app rings, B1 answers (activates the app, sends answerKey if set)
          and B2 silences the ring by muting output; both revert automatically.

        ActionSpec: `{ "action": string, "params": object? }`.

        Available actions:
        \(actionDocs)

        Notes for edits:
        - `shell` and `applescript` let you add behavior that has no builtin —
          e.g. params.command = "open -a Slack". Keep commands non-interactive.
        - Continuous shell/applescript actions receive {{value}} (0-127),
          {{percent}} (0-100), {{float}} (0.00-1.00) substitutions.
        - Key codes: Escape 53, Return 36, Tab 48, Space 49, Delete 51.
        - Bundle ids: iTerm com.googlecode.iterm2, ChatGPT com.openai.chat,
          Terminal com.apple.Terminal, Spotify com.spotify.client.
        """
    }

    static func build(request: String, currentConfig: Config) -> String {
        let configJSON = (try? currentConfig.encodePretty()).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        return """
        You are editing the configuration of GridPilot, a macOS app that maps a MIDI
        controller to desktop actions.

        \(schemaDoc)

        # Current config

        ```json
        \(configJSON)
        ```

        # Requested change

        \(request)

        # Your task

        Produce the COMPLETE updated config JSON implementing the requested change.
        Keep everything you were not asked to change byte-identical. Reply with ONLY
        the full config JSON inside a ```json fenced block — no other prose.
        """
    }
}
