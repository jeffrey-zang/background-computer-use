import Foundation
import CoreGraphics
import CoreText
import BCUShared

/// Where display-relative points land in a video frame: `scale` pixels per
/// point, after `offset` (pixels), top-left origin.
public struct FrameMapping: Equatable {
    public var scale: CGFloat
    public var offset: CGPoint
    public init(scale: CGFloat, offset: CGPoint) { self.scale = scale; self.offset = offset }
    public func point(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x * scale + offset.x, y: p.y * scale + offset.y) }
    public func rect(_ r: CGRect) -> CGRect {
        CGRect(x: r.minX * scale + offset.x, y: r.minY * scale + offset.y, width: r.width * scale, height: r.height * scale)
    }
}

/// Draws what the agent did over a frame of its recording: a caption bar
/// for the step under way (red for a failure), a box on the element it
/// acted on, a ripple where it clicked, keycaps for keys, an arrow for a
/// scroll or drag, and the time and step count.
public enum RecordingOverlay {
    /// How long after a step starts its box, ripple and keycaps show.
    static let markMs = 1600.0
    static let rippleMs = 700.0

    /// The least time a step's caption shows: steps that follow one another
    /// faster than that (or between two frames) each still get read.
    static let captionHoldMs = 800.0

    /// When each step's caption comes up: when it starts, or once the one
    /// before it has had `captionHoldMs`, whichever is later.
    public static func captionTimes(_ flat: [RecordedStep]) -> [Double] {
        var out: [Double] = []
        for s in flat { out.append(max(s.t, (out.last ?? -.infinity) + captionHoldMs)) }
        return out
    }

    /// The step whose caption shows at `t` (see `captionTimes`).
    public static func captionStep(_ flat: [RecordedStep], at t: Double) -> RecordedStep? {
        let times = captionTimes(flat)
        guard let i = times.lastIndex(where: { $0 <= t }) else { return nil }
        return flat[i]
    }

    /// Times a frame has to be drawn at, besides the captured ones, so every
    /// step's caption and marks are in the video: when each caption comes up
    /// and when each step starts.
    public static func renderTimes(_ flat: [RecordedStep]) -> [Double] {
        Array(Set(captionTimes(flat) + flat.map(\.t))).sorted()
    }

    /// Steps whose marks (box, ripple, keycaps, arrows) show at `t`.
    public static func marking(_ flat: [RecordedStep], at t: Double) -> [RecordedStep] {
        flat.filter { s in
            guard s.t <= t else { return false }
            let until = max(s.t + markMs, (s.end ?? s.t) + 600)
            return t <= until
        }
    }

    /// Draws over `ctx`, a `size` frame (bottom-left origin, as CoreGraphics
    /// has it), at `t` ms into the video. `total`: tool calls in the recording.
    public static func draw(in ctx: CGContext, size: CGSize, t: Double, flat: [RecordedStep], total: Int,
                            mapping: FrameMapping, label: String, redactAll: Bool, covers: [CGWindowID: CGRect] = [:]) {
        let W = size.width, H = size.height
        let u = max(0.55, min(1.4, W / 1600))
        func flip(_ r: CGRect) -> CGRect { CGRect(x: r.minX, y: H - r.maxY, width: r.width, height: r.height) }
        func flipP(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x, y: H - p.y) }
        let blue = CGColor(red: 0.16, green: 0.52, blue: 1, alpha: 1)
        let red = CGColor(red: 0.93, green: 0.2, blue: 0.2, alpha: 1)

        // With all typed text hidden, the fields it went into are covered
        // from then on (a password field shows only dots anyway).
        if redactAll {
            for s in flat where s.t <= t && s.hidesText(redactAll: true) {
                // The window it went into, where that window is in this frame
                // (the field can scroll, the window can move), else where it was.
                let area = s.coverWindow.flatMap { covers[$0] } ?? s.cover ?? s.target.flatMap { $0.secure ? nil : $0.frame }
                guard let area else { continue }
                let r = flip(mapping.rect(area).insetBy(dx: -2 * u, dy: -2 * u))
                ctx.setFillColor(CGColor(gray: 0.55, alpha: 1))
                ctx.addPath(CGPath(roundedRect: r, cornerWidth: 5 * u, cornerHeight: 5 * u, transform: nil)); ctx.fillPath()
                let l = line("hidden", font(min(18 * u, r.height * 0.6), bold: true), CGColor(gray: 1, alpha: 1))
                drawLine(ctx, l, x: r.minX + 8 * u, baseline: r.midY - r.height * 0.18)
            }
        }

        // Marks first, under the caption bar.
        for s in marking(flat, at: t) {
            let color = s.isError ? red : blue
            let age = t - s.t
            if let target = s.target {
                let r = flip(mapping.rect(target.frame).insetBy(dx: -3 * u, dy: -3 * u))
                let path = CGPath(roundedRect: r, cornerWidth: 6 * u, cornerHeight: 6 * u, transform: nil)
                ctx.setFillColor(color.copy(alpha: 0.14)!)
                ctx.addPath(path); ctx.fillPath()
                ctx.setStrokeColor(color)
                ctx.setLineWidth(3.5 * u)
                ctx.addPath(path); ctx.strokePath()
            }
            if let p = s.point.map(mapping.point) {
                let c = flipP(p)
                if let to = s.dragTo.map(mapping.point) {
                    arrow(ctx, from: c, to: flipP(to), color: color, width: 4 * u)
                } else if s.tool == "scroll" {
                    let a = Args(s.args)
                    let dy = CGFloat(a.int("dy") ?? 0), dx = CGFloat(a.int("dx") ?? 0)
                    let len = 70 * u
                    let d = hypot(dx, dy)
                    if d > 0 { arrow(ctx, from: c, to: CGPoint(x: c.x + dx / d * len, y: c.y - dy / d * len), color: color, width: 6 * u) }
                }
                if s.clicked {
                    if age < rippleMs {
                        let k = CGFloat(age / rippleMs)
                        let rad = (10 + 34 * k) * u
                        ctx.setStrokeColor(color.copy(alpha: 0.9 * (1 - k))!)
                        ctx.setLineWidth(4 * u)
                        ctx.strokeEllipse(in: CGRect(x: c.x - rad, y: c.y - rad, width: rad * 2, height: rad * 2))
                    }
                    ctx.setFillColor(color.copy(alpha: 0.85)!)
                    let dot = 7 * u
                    ctx.fillEllipse(in: CGRect(x: c.x - dot, y: c.y - dot, width: dot * 2, height: dot * 2))
                    ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.95))
                    ctx.setLineWidth(2 * u)
                    ctx.strokeEllipse(in: CGRect(x: c.x - dot, y: c.y - dot, width: dot * 2, height: dot * 2))
                }
            }
        }

        let barH = 96 * u
        // Keycaps, above the caption bar.
        if let s = marking(flat, at: t).last(where: { $0.tool == "press_key" && !$0.hidesText(redactAll: redactAll) }) {
            let a = Args(s.args)
            let caps = RecordingText.keycaps(key: a.string("key") ?? "?", modifiers: a.strings("modifiers") ?? [])
            let font = font(30 * u, bold: true)
            let lines = caps.map { line($0, font, CGColor(gray: 0.1, alpha: 1)) }
            let widths = lines.map { max(54 * u, width($0) + 30 * u) }
            let capH = 58 * u, gap = 10 * u
            var x = (W - widths.reduce(0, +) - gap * CGFloat(caps.count - 1)) / 2
            let y = barH + 22 * u
            for (i, l) in lines.enumerated() {
                let r = CGRect(x: x, y: y, width: widths[i], height: capH)
                ctx.setFillColor(CGColor(gray: 0, alpha: 0.35))
                ctx.addPath(CGPath(roundedRect: r.offsetBy(dx: 0, dy: -4 * u), cornerWidth: 10 * u, cornerHeight: 10 * u, transform: nil)); ctx.fillPath()
                ctx.setFillColor(CGColor(gray: 0.97, alpha: 1))
                ctx.addPath(CGPath(roundedRect: r, cornerWidth: 10 * u, cornerHeight: 10 * u, transform: nil)); ctx.fillPath()
                ctx.setStrokeColor(s.isError ? red : CGColor(gray: 0.6, alpha: 1)); ctx.setLineWidth(2 * u)
                ctx.addPath(CGPath(roundedRect: r, cornerWidth: 10 * u, cornerHeight: 10 * u, transform: nil)); ctx.strokePath()
                drawLine(ctx, l, x: r.midX - width(l) / 2, baseline: r.minY + capH * 0.33)
                x += widths[i] + gap
            }
        }

        // The caption bar.
        if let s = captionStep(flat, at: t) {
            let failed = s.isError
            ctx.setFillColor(failed ? CGColor(red: 0.72, green: 0.1, blue: 0.1, alpha: 0.92) : CGColor(gray: 0.06, alpha: 0.86))
            ctx.fill(CGRect(x: 0, y: 0, width: W, height: barH))
            var counter = "STEP \(s.n)/\(total)"
            if let sub = s.sub, let parent = flat.first(where: { $0.n == s.n && $0.sub == nil }) { counter += " · \(sub)/\(parent.steps.count)" }
            let pillFont = font(19 * u, bold: true)
            let pill = line(counter, pillFont, CGColor(gray: 1, alpha: 1))
            let pillR = CGRect(x: 18 * u, y: barH / 2 - 17 * u, width: width(pill) + 24 * u, height: 34 * u)
            ctx.setFillColor(failed ? CGColor(red: 0.45, green: 0.02, blue: 0.02, alpha: 1) : blue)
            ctx.addPath(CGPath(roundedRect: pillR, cornerWidth: 17 * u, cornerHeight: 17 * u, transform: nil)); ctx.fillPath()
            drawLine(ctx, pill, x: pillR.minX + 12 * u, baseline: pillR.minY + 11 * u)
            let textX = pillR.maxX + 20 * u
            let room = W - textX - 18 * u
            let caption = RecordingText.caption(tool: s.tool, args: s.args, target: s.target, hidden: s.hidesText(redactAll: redactAll))
            let top = line((failed ? "✗ " : "") + caption, font(27 * u, bold: true), CGColor(gray: 1, alpha: 1))
            drawLine(ctx, truncated(top, room), x: textX, baseline: barH - 40 * u)
            var detail: String
            if s.end == nil {
                detail = "running…"
            } else {
                detail = RecordingText.outcome(s.result, isError: failed)
                if let wait = s.waits.first { detail += "  ·  " + wait }
                detail += "  ·  \(Int(s.durationMs)) ms"
            }
            let bottom = line(detail, font(19 * u, bold: false), CGColor(gray: 1, alpha: failed ? 0.95 : 0.78))
            drawLine(ctx, truncated(bottom, room), x: textX, baseline: 20 * u)
        }

        // Top right: REC, the time and the session.
        let rec = line("REC  \(RecordingText.clock(t))", font(20 * u, bold: true), CGColor(gray: 1, alpha: 1))
        let labelLine = line(RecordingText.clip(label, 40), font(17 * u, bold: false), CGColor(gray: 1, alpha: 0.85))
        let boxW = max(width(rec) + 52 * u, width(labelLine) + 28 * u)
        // Below the menu bar, which has the clock in that corner.
        let box = CGRect(x: W - boxW - 16 * u, y: H - 44 * u - 66 * u, width: boxW, height: 66 * u)
        ctx.setFillColor(CGColor(gray: 0.06, alpha: 0.78))
        ctx.addPath(CGPath(roundedRect: box, cornerWidth: 12 * u, cornerHeight: 12 * u, transform: nil)); ctx.fillPath()
        ctx.setFillColor(red)
        ctx.fillEllipse(in: CGRect(x: box.minX + 14 * u, y: box.maxY - 30 * u, width: 14 * u, height: 14 * u))
        drawLine(ctx, rec, x: box.minX + 38 * u, baseline: box.maxY - 29 * u)
        drawLine(ctx, labelLine, x: box.minX + 14 * u, baseline: box.minY + 11 * u)
    }

    private static func arrow(_ ctx: CGContext, from a: CGPoint, to b: CGPoint, color: CGColor, width: CGFloat) {
        ctx.setStrokeColor(color); ctx.setFillColor(color); ctx.setLineWidth(width); ctx.setLineCap(.round)
        ctx.move(to: a); ctx.addLine(to: b); ctx.strokePath()
        let ang = atan2(b.y - a.y, b.x - a.x), head = width * 4
        ctx.move(to: b)
        ctx.addLine(to: CGPoint(x: b.x - head * cos(ang - .pi / 7), y: b.y - head * sin(ang - .pi / 7)))
        ctx.addLine(to: CGPoint(x: b.x - head * cos(ang + .pi / 7), y: b.y - head * sin(ang + .pi / 7)))
        ctx.closePath(); ctx.fillPath()
    }

    private static func font(_ size: CGFloat, bold: Bool) -> CTFont {
        CTFontCreateUIFontForLanguage(bold ? .emphasizedSystem : .system, size, nil) ?? CTFontCreateWithName("Helvetica" as CFString, size, nil)
    }

    private static func line(_ s: String, _ font: CTFont, _ color: CGColor) -> CTLine {
        let attrs: [NSAttributedString.Key: Any] = [NSAttributedString.Key(kCTFontAttributeName as String): font,
                                                    NSAttributedString.Key(kCTForegroundColorAttributeName as String): color]
        return CTLineCreateWithAttributedString(NSAttributedString(string: s, attributes: attrs))
    }

    private static func width(_ l: CTLine) -> CGFloat { CGFloat(CTLineGetTypographicBounds(l, nil, nil, nil)) }

    private static func truncated(_ l: CTLine, _ w: CGFloat) -> CTLine {
        guard width(l) > w else { return l }
        let runs = CTLineGetGlyphRuns(l) as! [CTRun]
        let attrs = runs.first.map { CTRunGetAttributes($0) as! [NSAttributedString.Key: Any] } ?? [:]
        let dots = CTLineCreateWithAttributedString(NSAttributedString(string: "…", attributes: attrs))
        return CTLineCreateTruncatedLine(l, Double(w), .end, dots) ?? l
    }

    private static func drawLine(_ ctx: CGContext, _ l: CTLine, x: CGFloat, baseline: CGFloat) {
        ctx.saveGState()
        ctx.textMatrix = .identity
        ctx.textPosition = CGPoint(x: x, y: baseline)
        CTLineDraw(l, ctx)
        ctx.restoreGState()
    }
}

/// The recording's action list: `actions.md` for people, `actions.json`
/// for programs. One entry per tool call, in order, failures and reads
/// included, a batch's steps under it.
public enum ActionList {
    public struct Info {
        public var started: Date
        public var durationMs: Double
        public var source: String
        public var windowID: Int?
        public var fps: Int
        public var frames: Int
        public var size: CGSize
        public var label: String
        public var redactAll: Bool
        public var video: String
        public var notes: [String]
        public init(started: Date, durationMs: Double, source: String, windowID: Int?, fps: Int, frames: Int, size: CGSize,
                    label: String, redactAll: Bool, video: String, notes: [String] = []) {
            self.started = started; self.durationMs = durationMs; self.source = source; self.windowID = windowID
            self.fps = fps; self.frames = frames; self.size = size; self.label = label; self.redactAll = redactAll
            self.video = video; self.notes = notes
        }
    }

    static func iso(_ d: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: d)
    }

    static func entry(_ s: RecordedStep, redactAll: Bool) -> JSONObject {
        var e: JSONObject = [
            "n": s.number, "tool": s.tool, "t": (s.t / 10).rounded() / 100, "time": RecordingText.clock(s.t),
            "duration_ms": Int(s.durationMs.rounded()),
            "caption": RecordingText.caption(tool: s.tool, args: s.args, target: s.target, hidden: s.hidesText(redactAll: redactAll)),
            "args": sanitized(s.exportedArgs(redactAll: redactAll)), "result": s.end == nil ? "" : s.result, "error": s.isError,
        ]
        if s.end == nil { e["unfinished"] = true }
        if let t = s.target {
            e["target"] = ["element": t.element, "role": t.role, "label": t.label, "secure": t.secure,
                           "frame": ["x": Int(t.frame.minX.rounded()), "y": Int(t.frame.minY.rounded()),
                                     "w": Int(t.frame.width.rounded()), "h": Int(t.frame.height.rounded())]] as JSONObject
        }
        if let p = s.point { e["point"] = ["x": Int(p.x.rounded()), "y": Int(p.y.rounded()), "click": s.clicked] as JSONObject }
        if let d = s.dragTo { e["drag_to"] = ["x": Int(d.x.rounded()), "y": Int(d.y.rounded())] }
        if !s.waits.isEmpty { e["waits"] = s.waits }
        if !s.steps.isEmpty { e["steps"] = s.steps.map { entry($0, redactAll: redactAll) } }
        return e
    }

    /// Arguments as JSON can hold them.
    static func sanitized(_ a: JSONObject) -> JSONObject {
        var out: JSONObject = [:]
        for (k, v) in a {
            if JSONSerialization.isValidJSONObject(["v": v]) { out[k] = v } else { out[k] = "\(v)" }
        }
        return out
    }

    public static func json(_ steps: [RecordedStep], info: Info) -> Data {
        let all = StepLog.flatten(steps)
        let obj: JSONObject = [
            "version": 1,
            "video": info.video,
            "started_at": iso(info.started),
            "duration_s": (info.durationMs / 100).rounded() / 10,
            "source": info.windowID.map { ["kind": "window", "window_id": $0] as JSONObject } ?? ["kind": "display"],
            "session": info.label,
            "fps": info.fps, "frames": info.frames,
            "width": Int(info.size.width), "height": Int(info.size.height),
            "typed_text_hidden": info.redactAll,
            "tool_calls": steps.count,
            // Tool calls that failed; a batch that stopped on a step is one.
            "failed": steps.filter(\.isError).count,
            "failed_actions": all.filter { $0.isError && $0.tool != "batch" }.count,
            "coordinates": "Points on the agent display, top-left origin" + (info.windowID != nil ? " (the video shows only the window)" : ""),
            "notes": info.notes,
            "actions": steps.map { entry($0, redactAll: info.redactAll) },
        ]
        return (try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys])) ?? Data()
    }

    static let reads: Set<String> = ["get_window_state", "screenshot", "status", "list_windows", "list_apps", "guard_report"]

    public static func markdown(_ steps: [RecordedStep], info: Info) -> String {
        let all = StepLog.flatten(steps)
        let failed = steps.filter(\.isError).count
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd HH:mm:ss"
        var out = ["# What the agent did", ""]
        out.append("\(info.label) · recorded \(df.string(from: info.started)) · \(RecordingText.clock(info.durationMs)) · "
                   + (info.windowID.map { "window \($0)" } ?? "the agent display")
                   + " · \(steps.count) tool call\(steps.count == 1 ? "" : "s")" + (failed > 0 ? ", \(failed) failed" : ""))
        out.append("")
        out.append("Video: [\(info.video)](\(info.video)) (\(Int(info.size.width))x\(Int(info.size.height)), \(info.frames) frames, captured at up to \(info.fps) fps). Each time below is where the step starts in the video.")
        if info.redactAll { out.append("Typed text is hidden in this recording.") }
        for n in info.notes { out.append(n) }
        out.append("")
        func block(_ s: RecordedStep, indent: String) {
            let caption = RecordingText.caption(tool: s.tool, args: s.args, target: s.target, hidden: s.hidesText(redactAll: info.redactAll))
            let mark = s.isError ? "❌ " : ""
            let lead = s.sub == nil ? "\(s.n)." : "\(s.sub!)."
            var head = "\(indent)\(lead) `\(RecordingText.clock(s.t))` \(mark)**\(md(caption))**"
            head += " — \(md(RecordingText.clip(RecordingText.outcome(s.result, isError: s.isError), 220)))"
            head += s.end == nil ? " (unfinished)" : " (\(Int(s.durationMs)) ms)"
            out.append(head)
            let sub = indent + "   "
            if let t = s.target {
                out.append("\(sub)- target: \(t.role)\(t.label.isEmpty ? "" : " \"\(md(t.label))\""), element \(t.element), at (\(Int(t.frame.minX)), \(Int(t.frame.minY))) \(Int(t.frame.width))×\(Int(t.frame.height))\(t.secure ? ", password field" : "")")
            }
            if let p = s.point { out.append("\(sub)- \(s.clicked ? "clicked" : "pointed") at (\(Int(p.x)), \(Int(p.y)))") }
            for w in s.waits { out.append("\(sub)- \(md(w))") }
            let args = sanitized(s.exportedArgs(redactAll: info.redactAll)).filter { $0.key != "window_id" || s.tool == "release_window" }
            if !args.isEmpty, let d = try? JSONSerialization.data(withJSONObject: args, options: [.sortedKeys]), let a = String(data: d, encoding: .utf8) {
                out.append("\(sub)- args: `\(a.replacingOccurrences(of: "`", with: "'"))`")
            }
            let lines = s.result.split(separator: "\n", omittingEmptySubsequences: false)
            if s.steps.isEmpty, lines.count > 1 || reads.contains(s.tool) {
                out.append("\(sub)<details><summary>\(reads.contains(s.tool) ? "What it read" : "Full result") (\(lines.count) lines)</summary>")
                out.append("")
                out.append("\(sub)```")
                for l in lines.prefix(400) { out.append(sub + l.replacingOccurrences(of: "```", with: "'''")) }
                if lines.count > 400 { out.append(sub + "… \(lines.count - 400) more lines") }
                out.append("\(sub)```")
                out.append("\(sub)</details>")
            }
            for c in s.steps { block(c, indent: sub) }
        }
        for s in steps { block(s, indent: "") }
        out.append("")
        return out.joined(separator: "\n")
    }

    private static func md(_ s: String) -> String {
        s.replacingOccurrences(of: "*", with: "\\*").replacingOccurrences(of: "_", with: "\\_").replacingOccurrences(of: "<", with: "&lt;")
    }
}
