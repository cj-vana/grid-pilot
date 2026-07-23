import Foundation

/// Generates and deploys the LED theme setup to Grid modules over serial —
/// no Grid Editor involved. Scripts are byte-identical to what the editor
/// stores (templates fetched from real hardware), writes are verified by
/// read-back, and identical content is skipped.
enum LEDDeployer {
    /// Default element event scripts with LED color stripped (mode + Auto
    /// MIDI, no Simple Color). Fetched verbatim from a PBF4 on fw 1.5.5.
    static let potEventScript = "--[[@spc]]self:pmo(7)self:pmi(0)self:pma(127)--[[@gms]]self:gms(-1,-1,-1,-1)"
    static let buttonEventScript = "--[[@sbc]]self:bmo(0)self:bmi(0)self:bma(127)--[[@gms]]self:gms(-1,-1,-1,-1)"

    /// Families where we know the element templates well enough to rewrite
    /// element events (verified on hardware or byte-compatible with it).
    static let elementRewriteFamilies: Set<String> = ["PBF4", "PO16", "BU16"]

    static let paletteTable = "{{0,60,255,170,0,255,255,30,0},{0,10,80,0,190,190,200,255,255},{80,0,160,255,0,120,255,150,0},{0,20,0,0,180,30,120,255,80},{20,0,0,255,60,0,255,220,0},{10,10,10,120,120,120,255,255,255}}"

    /// Theme handler for a module, with number ranges derived from its
    /// position and family layout (cc = 32 + x*16 + element).
    static func systemSetupScript(for module: GridModule) -> String? {
        guard let elements = GridModuleCatalog.elements(hwcfg: module.hwcfg) else { return nil }
        let base = 32 + module.x * 16
        let count = elements.count
        // Channel = row*4 + page, and the page changes at runtime (utility
        // button). c//4 isolates the row, so the guard survives page flips.
        let row = ((module.y % 4) + 4) % 4

        // Contiguous button range (all catalog families keep buttons at the tail).
        let firstButton = elements.firstIndex(of: .button)
        let ccEnd = base + (firstButton ?? count) - 1
        let ccBranch = firstButton == 0
            ? ""
            : "if c//4==\(row) and m==176 and p>=\(base) and p<=\(ccEnd) then n=p-\(base) end "
        var noteBranch = ""
        if let firstButton {
            let noteStart = base + firstButton
            let noteEnd = base + count - 1
            noteBranch = "if c//4==\(row) and(m==144 or m==128)and p>=\(noteStart) and p<=\(noteEnd) then n=p-\(base) if m==128 then v=0 end end "
        }

        return "--[[@cb]]"
            + "self.T=\(paletteTable)self.q={}"
            + "self.F=function(t,v,o)local a,b,f if v<64 then a=o b=o+3 f=v*2 else a=o+3 b=o+6 f=(v-64)*2 end return t[a]+((t[b]-t[a])*f)//127 end "
            + "self.midirx_cb=function(s,h,e)local c,m,p,v=e[1],e[2],e[3],e[4]"
            + "if c==15 and m==176 and p==20 then local t=s.T[v+1]or s.T[1]for n=0,\(count - 1) do "
            + "gln(n,1,t[1],t[2],t[3])gld(n,1,t[4],t[5],t[6])glx(n,1,t[7],t[8],t[9])"
            + "local q=s.q[n]or 0 glc(n,1,s.F(t,q,1),s.F(t,q,2),s.F(t,q,3))glp(n,1,q*2)end return end "
            + "local n=-1 \(ccBranch)\(noteBranch)"
            + "if n>=0 then s.q[n]=v glp(n,1,v*2)end end"
    }

    struct Report {
        var lines: [String] = []
        var failed = false
    }

    /// Full deployment: per module, write the theme handler (and element
    /// scripts where templates are known), verify by fetch, then store.
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
            var writes: [(element: Int, event: Int, script: String, label: String)] = [
                (GridConfigClient.systemElement, GridConfigClient.setupEvent, setup, "theme handler"),
            ]
            if elementRewriteFamilies.contains(module.name),
               let elements = GridModuleCatalog.elements(hwcfg: module.hwcfg) {
                for (index, element) in elements.enumerated() {
                    switch element {
                    case .potmeter:
                        writes.append((index, 1, potEventScript, "element \(index)"))
                    case .button:
                        writes.append((index, 3, buttonEventScript, "element \(index)"))
                    default:
                        break
                    }
                }
            } else {
                report.lines.append("\(module.name): element color blocks left as-is (no verified template) — colors may need a one-time Grid Editor cleanup")
            }

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
