import AppKit

/// "Customize with AI" — type a request, the configured agent proposes a new
/// config, you see the diff, then apply or cancel.
final class CustomizeWindowController: NSObject, NSWindowDelegate {
    private let store: ConfigStore
    private let onClose: () -> Void
    private var window: NSWindow!
    private var requestField: NSTextView!
    private var statusLabel: NSTextField!
    private var diffView: NSTextView!
    private var runButton: NSButton!
    private var applyButton: NSButton!
    private var spinner: NSProgressIndicator!
    private var pendingResult: AIResult?

    init(store: ConfigStore, onClose: @escaping () -> Void) {
        self.store = store
        self.onClose = onClose
        super.init()
        buildWindow()
    }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        window.center()
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(requestField)
    }

    func windowWillClose(_ notification: Notification) {
        onClose()
    }

    private func buildWindow() {
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 460),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered, defer: false
        )
        window.title = "Customize with AI"
        window.delegate = self
        window.isReleasedWhenClosed = false
        let content = NSView(frame: window.contentLayoutRect)
        content.autoresizingMask = [.width, .height]
        window.contentView = content

        let hint = NSTextField(labelWithString: "Describe the change — e.g. \"make F3 control Spotify seek\" or \"add a long-press on B1 that opens Slack\"")
        hint.frame = NSRect(x: 20, y: 420, width: 520, height: 30)
        hint.autoresizingMask = [.width, .minYMargin]
        hint.textColor = .secondaryLabelColor
        hint.font = .systemFont(ofSize: 11)
        hint.lineBreakMode = .byWordWrapping
        hint.maximumNumberOfLines = 2
        content.addSubview(hint)

        let requestScroll = NSScrollView(frame: NSRect(x: 20, y: 340, width: 520, height: 76))
        requestScroll.autoresizingMask = [.width, .minYMargin]
        requestField = NSTextView(frame: requestScroll.bounds)
        requestField.font = .systemFont(ofSize: 13)
        requestField.isRichText = false
        requestScroll.documentView = requestField
        requestScroll.hasVerticalScroller = true
        requestScroll.borderType = .bezelBorder
        content.addSubview(requestScroll)

        runButton = NSButton(title: "Run \(store.config.ai.provider)", target: self, action: #selector(run))
        runButton.frame = NSRect(x: 20, y: 300, width: 140, height: 30)
        runButton.autoresizingMask = [.minYMargin]
        runButton.keyEquivalent = "\r"
        content.addSubview(runButton)

        spinner = NSProgressIndicator(frame: NSRect(x: 170, y: 305, width: 20, height: 20))
        spinner.style = .spinning
        spinner.isHidden = true
        spinner.autoresizingMask = [.minYMargin]
        content.addSubview(spinner)

        statusLabel = NSTextField(labelWithString: "")
        statusLabel.frame = NSRect(x: 200, y: 305, width: 340, height: 20)
        statusLabel.autoresizingMask = [.width, .minYMargin]
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.lineBreakMode = .byTruncatingTail
        content.addSubview(statusLabel)

        let diffScroll = NSScrollView(frame: NSRect(x: 20, y: 60, width: 520, height: 230))
        diffScroll.autoresizingMask = [.width, .height]
        diffView = NSTextView(frame: diffScroll.bounds)
        diffView.isEditable = false
        diffView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        diffScroll.documentView = diffView
        diffScroll.hasVerticalScroller = true
        diffScroll.borderType = .bezelBorder
        content.addSubview(diffScroll)

        applyButton = NSButton(title: "Apply Change", target: self, action: #selector(apply))
        applyButton.frame = NSRect(x: 400, y: 20, width: 140, height: 30)
        applyButton.autoresizingMask = [.minXMargin, .maxYMargin]
        applyButton.isEnabled = false
        content.addSubview(applyButton)
    }

    @objc private func run() {
        let request = requestField.string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !request.isEmpty else { return }
        pendingResult = nil
        applyButton.isEnabled = false
        runButton.isEnabled = false
        spinner.isHidden = false
        spinner.startAnimation(nil)
        let ai = store.config.ai
        let model = ai.provider == "claude" ? ai.claude.model : ai.codex.model
        statusLabel.stringValue = "Asking \(ai.provider) (\(model))… this can take a minute"
        diffView.string = ""

        AICustomizer(store: store).customize(request: request) { [weak self] result in
            guard let self else { return }
            self.spinner.stopAnimation(nil)
            self.spinner.isHidden = true
            self.runButton.isEnabled = true
            switch result {
            case .success(let ai):
                self.pendingResult = ai
                self.statusLabel.stringValue = "Proposed change — review and apply:"
                self.diffView.string = ai.summary.map { "• \($0)" }.joined(separator: "\n")
                self.applyButton.isEnabled = true
            case .failure(let message):
                self.statusLabel.stringValue = "Failed"
                self.diffView.string = message
            }
        }
    }

    @objc private func apply() {
        guard let result = pendingResult else { return }
        do {
            try AICustomizer(store: store).apply(result)
            statusLabel.stringValue = "Applied ✓ (Revert Last Change in the menu undoes this)"
            applyButton.isEnabled = false
            pendingResult = nil
        } catch {
            statusLabel.stringValue = "Apply failed"
            diffView.string = error.localizedDescription
        }
    }
}
