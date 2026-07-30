import Foundation

/// Generates and deploys the LED theme setup to Grid modules over serial —
/// no Grid Editor involved. Stock Simple Color blocks are removed in place so
/// custom modes and MIDI actions survive; writes are verified by read-back.
enum LEDDeployer {
    static let paletteTable = "{{0,60,255,170,0,255,255,30,0},{0,10,80,0,190,190,200,255,255},{80,0,160,255,0,120,255,150,0},{0,20,0,0,180,30,120,255,80},{20,0,0,255,60,0,255,220,0},{10,10,10,120,120,120,255,255,255}}"

    /// Main value-producing events that may contain a Simple Color action.
    /// Event ids come from the protocol's elementEvents table.
    static func colorEventIDs(for element: GridElementType) -> [Int] {
        switch element {
        case .potmeter: return [1]
        case .encoder: return [2, 3]
        case .button: return [3]
        case .endless: return [7, 3]
        case .touch: return [9]
        case .lcd: return []
        }
    }

    /// Removes only editor-generated Simple Color blocks. Block markers make
    /// this safe without understanding or replacing the surrounding actions.
    static func removingSimpleColor(from script: String) -> String {
        var result = script
        let marker = "--[[@sglc]]"
        while let color = result.range(of: marker) {
            let remainder = result[color.upperBound...]
            let end = remainder.range(of: "--[[@")?.lowerBound ?? result.endIndex
            result.removeSubrange(color.lowerBound..<end)
        }
        return result
    }

    /// Theme handler for a module, with number ranges derived from its
    /// position and family layout (cc = 32 + x*16 + element).
    static func systemSetupScript(for module: GridModule) -> String? {
        guard let elements = GridModuleCatalog.elements(hwcfg: module.hwcfg) else { return nil }
        let base = 32 + module.x * 16
        let count = elements.count
        let lcdIndices = elements.indices.filter { elements[$0] == .lcd }
        let lcdTable = lcdIndices.map { "[\($0)]=1" }.joined(separator: ",")
        // Channel = row*4 + page, and the page changes at runtime (utility
        // button). c//4 isolates the row, so the guard survives page flips.
        let row = ((module.y % 4) + 4) % 4

        let ccRanges = contiguousRanges(
            elements.indices.filter {
                switch elements[$0] {
                case .potmeter, .encoder, .endless: return true
                case .button, .touch, .lcd: return false
                }
            }
        )
        let buttonRanges = contiguousRanges(elements.indices.filter { elements[$0] == .button })
        let ccBranch = ccRanges.map { range in
            "if c//4==\(row) and m==176 and p>=\(base + range.lowerBound) and p<=\(base + range.upperBound) then n=p-\(base) end "
        }.joined()
        let noteBranch = buttonRanges.map { range in
            "if c//4==\(row) and(m==144 or m==128)and p>=\(base + range.lowerBound) and p<=\(base + range.upperBound) then n=p-\(base) if m==128 then v=0 end end "
        }.joined()

        // The renderer re-blends gln/gld/glx by phase every frame, so setting
        // anchors + phase is the whole job. Never add glc here: firmware's
        // led_color rewrites all three anchors to {c/20, c/2, c}, flattening
        // the gradient (at value 0 that leaves LEDs stuck near the min color).
        return "--[[@cb]]"
            + "self.T=\(paletteTable)self.q={}self.L={\(lcdTable)}"
            + "self.midirx_cb=function(s,h,e)local c,m,p,v=e[1],e[2],e[3],e[4]"
            + "if c==15 and m==176 and p==20 then local t=s.T[v+1]or s.T[1]for n=0,\(count - 1) do "
            + "if not s.L[n]then gln(n,1,t[1],t[2],t[3])gld(n,1,t[4],t[5],t[6])glx(n,1,t[7],t[8],t[9])"
            + "glp(n,1,(s.q[n]or 0)*2)end end return end "
            + "local n=-1 \(ccBranch)\(noteBranch)"
            + "if n>=0 then s.q[n]=v glp(n,1,v*2)end end"
    }

    private static func contiguousRanges(_ indices: [Int]) -> [ClosedRange<Int>] {
        guard let first = indices.first else { return [] }
        var ranges: [ClosedRange<Int>] = []
        var start = first
        var end = first
        for index in indices.dropFirst() {
            if index == end + 1 {
                end = index
            } else {
                ranges.append(start...end)
                start = index
                end = index
            }
        }
        ranges.append(start...end)
        return ranges
    }

    struct Report {
        var lines: [String] = []
        var failed = false
    }

    /// Full deployment: per module, write the theme handler, remove marked
    /// color actions from element events, verify by fetch, then store.
    static func deploy(client: GridConfigClient) -> Report {
        var report = Report()
        let modules = client.modules
        guard !modules.isEmpty else {
            report.lines.append("no modules discovered")
            report.failed = true
            return report
        }
        var wroteAnything = false
        for module in modules {
            guard let setup = systemSetupScript(for: module) else {
                report.lines.append("\(module.name) (\(module.x),\(module.y)): unknown layout — skipped (learn mode still works)")
                continue
            }
            let writes: [(element: Int, event: Int, script: String, label: String)] = [
                (GridConfigClient.systemElement, GridConfigClient.setupEvent, setup, "theme handler"),
            ]
            for write in writes {
                let current = client.fetchConfig(module: module, element: write.element, event: write.event)
                if case .success(let existing) = current, existing == write.script {
                    continue  // already deployed
                }
                switch client.writeConfig(module: module, element: write.element, event: write.event, script: write.script) {
                case .failure(let message):
                    report.lines.append("✗ \(module.name) \(write.label): \(message)")
                    report.failed = true
                    return report  // stop before storing anything half-written
                case .success:
                    wroteAnything = true
                }
                // Trust nothing: read back and compare.
                switch client.fetchConfig(module: module, element: write.element, event: write.event) {
                case .success(let readBack) where readBack == write.script:
                    report.lines.append("✓ \(module.name) \(write.label) written + verified")
                case .success:
                    report.lines.append("✗ \(module.name) \(write.label): read-back mismatch — NOT storing")
                    report.failed = true
                    return report
                case .failure(let message):
                    report.lines.append("✗ \(module.name) \(write.label): verify failed: \(message)")
                    report.failed = true
                    return report
                }
            }

            guard let elements = GridModuleCatalog.elements(hwcfg: module.hwcfg) else { continue }
            for (index, element) in elements.enumerated() {
                for event in colorEventIDs(for: element) {
                    let label = "element \(index) event \(event)"
                    let existing: String
                    switch client.fetchConfig(module: module, element: index, event: event) {
                    case .success(let script):
                        existing = script
                    case .failure(let message):
                        report.lines.append("✗ \(module.name) \(label): read failed: \(message) — NOT storing")
                        report.failed = true
                        return report
                    }
                    let stripped = removingSimpleColor(from: existing)
                    guard stripped != existing else { continue }
                    switch client.writeConfig(module: module, element: index, event: event, script: stripped) {
                    case .failure(let message):
                        report.lines.append("✗ \(module.name) \(label): \(message)")
                        report.failed = true
                        return report
                    case .success:
                        wroteAnything = true
                    }
                    switch client.fetchConfig(module: module, element: index, event: event) {
                    case .success(let readBack) where readBack == stripped:
                        report.lines.append("✓ \(module.name) \(label) color removed + verified")
                    case .success:
                        report.lines.append("✗ \(module.name) \(label): read-back mismatch — NOT storing")
                        report.failed = true
                        return report
                    case .failure(let message):
                        report.lines.append("✗ \(module.name) \(label): verify failed: \(message)")
                        report.failed = true
                        return report
                    }
                }
            }
        }
        // Always store: a previous interrupted run can leave verified config
        // in RAM only, which a power cycle would silently drop.
        if !wroteAnything {
            report.lines.append("scripts already up to date")
        }
        switch client.storePages() {
        case .success:
            report.lines.append("✓ stored to module flash")
        case .failure(let message):
            report.lines.append("✗ store failed: \(message) (config active in RAM but lost on power cycle)")
            report.failed = true
        }
        return report
    }
}
