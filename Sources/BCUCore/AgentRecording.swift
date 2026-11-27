import AppKit
import AVFoundation
import BCUShared

/// A video of the agent at work that it started with `start_recording`:
/// the agent display (or one window) captured continuously, every tool call
/// drawn onto it when it stops, and the list of those calls beside it.
///
/// Frames are one-shot ScreenCaptureKit screenshots, as the live preview
/// takes (`FrameStream`), written as they come to `raw.mp4`. `finish` then
/// reads that back, draws each step over its frames (knowing by then how
/// many steps there were and how each ended) and writes `recording.mp4`
/// (H.264, which QuickTime plays), `actions.md` and `actions.json`, all
/// readable only by the user.
public final class AgentRecording {
    public struct Output {
        public let dir: URL
        public let video: URL
        public let markdown: URL
        public let json: URL
        public let audio: URL?
        public let durationMs: Double
        public let frames: Int
        public let size: CGSize
        public let toolCalls: Int
        public let failed: Int
        public let notes: [String]
    }

    static let defaultFPS = 12
    /// Capture stops after this long; what was captured is kept.
    static let maxMs = 30 * 60 * 1000.0
    /// Recordings kept: older ones are deleted when a new one is saved.
    static let keep = 20

    public let dir: URL
    public let windowID: CGWindowID?
    public let fps: Int
    public let steps: StepLog
    public let label: String
    private let display: AgentDisplay
    private let startMs: Double
    private let started = Date()
    private let size: CGSize
    private let onDisplayFrame: (CGImage) -> Void
    /// Gets a window recording's frames (at most twice a second), so the
    /// history, which waits for a pause in the app's captures that a
    /// recording never leaves, keeps up.
    private let onWindowFrame: (CGWindowID, CGImage) -> Void
    private var lastWindowFrameMs = 0.0
    /// Whether the session still has a window (a recording of one stops
    /// showing it once it's released: it may be the user's again).
    private let owns: (CGWindowID) -> Bool
    /// A covered window's place on screen, with any sheet reaching past it.
    private let area: (CGWindowID) -> CGRect?
    private var windowReleased = false
    private let queue = DispatchQueue(label: "bcu.agent-recording", qos: .userInitiated)
    private var timer: DispatchSourceTimer?
    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    private let lock = NSLock()
    /// Per frame written: its time (ms) and where display points land in it.
    private var mappings: [(t: Int64, map: FrameMapping)] = []
    /// Per frame, where the windows that hidden typing went into were then
    /// (display points), so their cover follows them.
    private var coverMaps: [[CGWindowID: CGRect]] = []
    private var coversBefore: [CGWindowID: CGRect] = [:]
    /// Per frame, where each followed password field was (by step number).
    private var fieldMaps: [[String: CGRect]] = []
    private var fieldsBefore: [String: CGRect] = [:]
    private var lastPts: Int64 = -1
    /// Captures under way (on `queue`), and a group to wait for them.
    private var pending = 0
    private let inFlight = DispatchGroup()
    private let captureQueue = DispatchQueue(label: "bcu.agent-recording.capture", qos: .userInitiated, attributes: .concurrent)
    private var _capturing = true
    private var capped = false
    /// When capture stopped at `maxMs`: the video ends there.
    private var cutoffMs: Double?
    private var windowGone = false
    public var rawURL: URL { dir.appendingPathComponent("raw.mp4") }

    /// Where recordings go: `agent-recordings/` beside the engine's other state.
    public static var directory: URL { BCUPaths.supportDirectory.appendingPathComponent("agent-recordings", isDirectory: true) }

    /// A folder name that sorts by time.
    static func folderName(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss-SSS"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f.string(from: date)
    }

    /// The video's size for a source of `points`: one pixel per point, even
    /// (H.264 wants it), at most 1920 wide.
    static func videoSize(_ points: CGSize) -> CGSize {
        let s = min(1, 1920 / max(points.width, 1))
        func even(_ v: CGFloat) -> CGFloat { max(2, (v * s / 2).rounded(.down) * 2) }
        return CGSize(width: even(points.width), height: even(points.height))
    }

    /// Where a source rect (display points) goes in a `canvas`: as big as
    /// fits, centered.
    static func fit(_ source: CGSize, in canvas: CGSize) -> CGRect {
        guard source.width > 0, source.height > 0 else { return CGRect(origin: .zero, size: canvas) }
        let s = min(canvas.width / source.width, canvas.height / source.height)
        let w = source.width * s, h = source.height * s
        return CGRect(x: (canvas.width - w) / 2, y: (canvas.height - h) / 2, width: w, height: h)
    }

    /// `onDisplayFrame` gets each whole-display frame (for the history, which
    /// then needs no captures of its own meanwhile).
    init(display: AgentDisplay, windowID: CGWindowID?, fps: Int, label: String, redactAll: Bool,
         owns: @escaping (CGWindowID) -> Bool = { _ in true },
         area: @escaping (CGWindowID) -> CGRect? = { WindowList.info($0)?.bounds },
         onWindowFrame: @escaping (CGWindowID, CGImage) -> Void = { _, _ in },
         onDisplayFrame: @escaping (CGImage) -> Void) throws {
        self.display = display
        self.windowID = windowID
        self.fps = min(30, max(2, fps))
        self.label = label
        self.onDisplayFrame = onDisplayFrame
        self.onWindowFrame = onWindowFrame
        self.owns = owns
        self.area = area
        let fm = FileManager.default
        try fm.createDirectory(at: Self.directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        // Made without intermediates, so it fails if it's there already: two
        // sessions starting in the same millisecond each get their own.
        var d = Self.directory.appendingPathComponent(Self.folderName(started), isDirectory: true)
        var i = 2
        while true {
            do {
                try fm.createDirectory(at: d, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
                break
            } catch where fm.fileExists(atPath: d.path) && i < 1000 {
                d = Self.directory.appendingPathComponent(Self.folderName(started) + "-\(i)", isDirectory: true)
                i += 1
            }
        }
        dir = d
        Self.markActive(d, true)
        var points = CGSize(width: display.bounds.width, height: display.bounds.height)
        if let windowID, let wb = WindowList.info(windowID)?.bounds { points = wb.size }
        size = Self.videoSize(points)

        let w = try AVAssetWriter(outputURL: dir.appendingPathComponent("raw.mp4"), fileType: .mp4)
        let inp = AVAssetWriterInput(mediaType: .video, outputSettings: Self.videoSettings(size, bitrate: 10_000_000))
        inp.expectsMediaDataInRealTime = true
        inp.mediaTimeScale = 1000
        w.movieTimeScale = 1000
        let ad = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: inp, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: Int(size.width),
            kCVPixelBufferHeightKey as String: Int(size.height),
        ])
        guard w.canAdd(inp) else { throw ToolError("couldn't set up the video writer") }
        w.add(inp)
        guard w.startWriting() else { throw ToolError("couldn't start the video: \(w.error.map { "\($0)" } ?? "unknown error")") }
        w.startSession(atSourceTime: .zero)
        writer = w
        input = inp
        adaptor = ad
        // The video's clock starts once the writer is ready (setting it up
        // can take a second), with the first frame.
        let start = nowMs()
        startMs = start
        steps = StepLog(redactAll: redactAll) { nowMs() - start }
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: 1.0 / Double(self.fps), leeway: .milliseconds(5))
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t
    }

    static func videoSettings(_ size: CGSize, bitrate: Int) -> [String: Any] {
        [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(size.width),
            AVVideoHeightKey: Int(size.height),
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: bitrate,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                AVVideoMaxKeyFrameIntervalKey: 60,
                AVVideoAllowFrameReorderingKey: false,
            ] as [String: Any],
        ]
    }

    /// Still capturing (not stopped, not past `maxMs`).
    public var isCapturing: Bool { lock.lock(); defer { lock.unlock() }; return _capturing }
    public var elapsedMs: Double { nowMs() - startMs }

    /// Starts a capture, unless one is under way already (a one-shot
    /// screenshot takes about 60–100 ms at the video's size; more at once
    /// slow down everyone else's captures, the cover a key swap puts up
    /// included). Runs on `queue`.
    private func tick() {
        guard isCapturing else { return }
        if elapsedMs > Self.maxMs {
            lock.lock(); capped = true; cutoffMs = elapsedMs; _capturing = false; lock.unlock()
            timer?.cancel()
            return
        }
        guard pending < Self.maxInFlight, display.isRunning else { return }
        pending += 1
        inFlight.enter()
        captureQueue.async { [self] in
            let shot = grab()
            queue.async { [self] in
                pending -= 1
                if let shot { write(shot.image, source: shot.source) }
                inFlight.leave()
            }
        }
    }

    static let maxInFlight = 1

    /// A frame of what's recorded, and the display points it shows.
    private func grab() -> (image: CGImage, source: CGRect)? {
        let live = display.liveBounds
        let b = live.isEmpty ? display.bounds : live
        // Covered windows' places before the capture (see `write`).
        var before: [CGWindowID: CGRect] = [:]
        for id in steps.coverWindows() where id != windowID {
            if let wb = area(id) { before[id] = wb.offsetBy(dx: -b.minX, dy: -b.minY) }
        }
        var fieldsBefore: [String: CGRect] = [:]
        for (key, el) in steps.coverFields() {
            if let f = AX.frame(el), f.width > 0 { fieldsBefore[key] = f.offsetBy(dx: -b.minX, dy: -b.minY) }
        }
        lock.lock(); coversBefore = before; self.fieldsBefore = fieldsBefore; lock.unlock()
        if let windowID {
            // Released (handed back to the user, or left open for them): not
            // the session's to film any more, wherever it is.
            guard owns(windowID) else { lock.lock(); windowReleased = true; lock.unlock(); return nil }
            guard let wb = WindowList.info(windowID)?.bounds else { lock.lock(); windowGone = true; lock.unlock(); return nil }
            guard let image = Capture.recordingWindowFrame(windowID) else { return nil }
            // Released while the screenshot was being taken: it may already
            // show the window on the user's screen.
            guard owns(windowID) else { lock.lock(); windowReleased = true; lock.unlock(); return nil }
            // Resized or moved while it was taken: the picture and its geometry may not match.
            // Moved, too: the frame's place on the display would be off.
            guard WindowList.info(windowID)?.bounds == wb else { return nil }
            if nowMs() - lastWindowFrameMs >= 500 {
                lastWindowFrameMs = nowMs()
                onWindowFrame(windowID, image)
            }
            let covered = Capture.coveredRect(image, bounds: wb, display: b)
            return (image, covered.offsetBy(dx: -b.minX, dy: -b.minY))
        }
        guard let image = Capture.display(display, pixelsPerPoint: size.width / max(b.width, 1)) else { return nil }
        onDisplayFrame(image)
        return (image, CGRect(origin: .zero, size: b.size))
    }

    /// Adds a frame at the current time. Runs on `queue`.
    private func write(_ image: CGImage, source: CGRect) {
        guard input.isReadyForMoreMediaData, let pool = adaptor.pixelBufferPool else { return }
        let pts = Int64(elapsedMs.rounded())
        guard pts > lastPts else { return }
        // A capture that finishes past the cap: its steps aren't drawn, so neither is it.
        lock.lock(); let cut = cutoffMs; lock.unlock()
        if let cut, Double(pts) > cut { return }
        var buffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
        guard let buffer else { return }
        let fit = Self.fit(source.size, in: size)
        CVPixelBufferLockBaseAddress(buffer, [])
        if let ctx = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: Int(size.width), height: Int(size.height), bitsPerComponent: 8,
                               bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpaceCreateDeviceRGB(),
                               bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) {
            ctx.setFillColor(CGColor(red: 0.11, green: 0.11, blue: 0.12, alpha: 1))
            ctx.fill(CGRect(origin: .zero, size: size))
            ctx.interpolationQuality = .high
            ctx.draw(image, in: CGRect(x: fit.minX, y: size.height - fit.maxY, width: fit.width, height: fit.height))
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        if adaptor.append(buffer, withPresentationTime: CMTime(value: pts, timescale: 1000)) {
            let scale = fit.width / max(source.width, 1)
            let map = FrameMapping(scale: scale, offset: CGPoint(x: fit.minX - source.minX * scale, y: fit.minY - source.minY * scale))
            // The display's origin as macOS has it now (the cached bounds lag
            // a rearrangement), the same moment as the windows' places.
            let live = display.liveBounds
            let b = live.isEmpty ? display.bounds : live
            var covers: [CGWindowID: CGRect] = [:]
            lock.lock(); let coversBefore = self.coversBefore; lock.unlock()
            let first = steps.firstCovers()
            for id in steps.coverWindows() {
                // The recorded window itself: where this frame shows it (the
                // same reading of its place as the mapping), not a later one.
                if id == windowID { covers[id] = source; continue }
                // Where it was when the capture started and where it is now,
                // together: it may have moved while the screenshot was taken.
                if let wb = area(id) {
                    let now = wb.offsetBy(dx: -b.minX, dy: -b.minY)
                    // Newly covered while it was taken: where the typing started, too.
                    covers[id] = (coversBefore[id] ?? first[id]).map { $0.union(now) } ?? now
                } else if let then = coversBefore[id] {
                    // Gone meanwhile: the frame may still show it where it was.
                    covers[id] = then
                }
            }
            var fields: [String: CGRect] = [:]
            lock.lock(); let fieldsBefore = self.fieldsBefore; lock.unlock()
            let firstFields = steps.firstFieldFrames()
            for (key, el) in steps.coverFields() {
                // Before and after the capture together: it may have scrolled meanwhile.
                if let f = AX.frame(el), f.width > 0 {
                    let now = f.offsetBy(dx: -b.minX, dy: -b.minY)
                    // Newly followed while it was taken: where it was typed into, too.
                    fields[key] = (fieldsBefore[key] ?? firstFields[key]).map { $0.union(now) } ?? now
                } else if let then = fieldsBefore[key] {
                    fields[key] = then
                }
            }
            lock.lock(); mappings.append((pts, map)); coverMaps.append(covers); fieldMaps.append(fields); lock.unlock()
            lastPts = pts
        }
    }

    /// Stops capturing, draws the steps onto the video and writes the
    /// files. Blocks while it renders (about a second per 10 s of video).
    /// `audio`: a file of the session's sound to keep beside the video.
    /// `failing` gets the error before the lists are written for the last
    /// time, when there's no video.
    func finish(audio: URL? = nil, failing: ((String) -> Void)? = nil) throws -> Output {
        // One more frame, so the video shows the call that stops it, then
        // no more: the timer would keep starting captures while this waits.
        queue.sync { tick() }
        lock.lock(); _capturing = false; lock.unlock()
        timer?.cancel()
        queue.sync {}
        inFlight.wait()
        let durationMs = elapsedMs
        input.markAsFinished()
        let done = DispatchSemaphore(value: 0)
        writer.endSession(atSourceTime: CMTime(value: max(lastPts, 0) + 1, timescale: 1000))
        writer.finishWriting { done.signal() }
        done.wait()
        lock.lock(); let maps = mappings; let covers = coverMaps; let fields = fieldMaps; let wasCapped = capped; let gone = windowGone, released = windowReleased; lock.unlock()
        defer { Self.markActive(dir, false) }
        var notes: [String] = []
        if wasCapped { notes.append("Capture stopped after \(Int(Self.maxMs / 60_000)) minutes; later steps are listed but not in the video.") }
        if released { notes.append("The window was released before the recording stopped; the video ends with its last frame before that.") }
        else if gone { notes.append("The window closed before the recording stopped; the video ends with its last frame.") }
        steps.redactAgain()
        let all = steps.all
        let video = dir.appendingPathComponent("recording.mp4")
        let md = dir.appendingPathComponent("actions.md"), js = dir.appendingPathComponent("actions.json")
        func writeLists(_ notes: [String]) throws {
            let info = ActionList.Info(started: started, durationMs: durationMs, source: windowID == nil ? "display" : "window",
                                       windowID: windowID.map(Int.init), fps: fps, frames: maps.count, size: size, label: label,
                                       redactAll: steps.redactAll, video: video.lastPathComponent, notes: notes)
            try ActionList.markdown(all, info: info).write(to: md, atomically: true, encoding: .utf8)
            try ActionList.json(all, info: info).write(to: js, options: .atomic)
            for f in [md, js] { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: f.path) }
        }
        // The list first: whatever happens to the video, the record of what
        // the agent did is kept.
        try writeLists(notes)
        guard writer.status == .completed, !maps.isEmpty else {
            let message = "no frames were recorded (\(writer.error.map { "\($0)" } ?? "the display showed nothing")), so there's no video. The action list is saved: \(md.path) and \(js.lastPathComponent) beside it."
            failing?(message)
            try? writeLists(notes + ["No video: no frames were recorded."])
            throw ToolError(message)
        }
        do {
            // Past the cap, steps are in the lists only.
            lock.lock(); let cutoff = cutoffMs; lock.unlock()
            try render(raw: rawURL, to: video, maps: maps, covers: covers, fields: fields, steps: all, endMs: min(durationMs, cutoff ?? .infinity), cutoff: cutoff)
        } catch {
            let message = "\(error), so there's no video. The action list is saved: \(md.path) and \(js.lastPathComponent) beside it."
            failing?(message)
            try? writeLists(notes + ["No video: \(error)"])
            throw ToolError(message)
        }
        try? FileManager.default.removeItem(at: rawURL)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: video.path)
        var audioOut: URL?
        if let audio, FileManager.default.fileExists(atPath: audio.path) {
            let dest = dir.appendingPathComponent("audio" + (audio.pathExtension.isEmpty ? "" : "." + audio.pathExtension))
            if (try? FileManager.default.copyItem(at: audio, to: dest)) != nil {
                audioOut = dest
                try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: dest.path)
                notes.append("The session's sound is in [\(dest.lastPathComponent)](\(dest.lastPathComponent)), from when it started playing (it isn't in the video).")
                try writeLists(notes)
            }
        }
        Self.prune(keeping: dir)
        let flat = StepLog.flatten(all)
        return Output(dir: dir, video: video, markdown: md, json: js, audio: audioOut, durationMs: durationMs, frames: maps.count,
                      size: size, toolCalls: all.count, failed: all.filter(\.isError).count, notes: notes)
    }

    /// Reads `raw` back frame by frame, draws the steps over each and writes `out`.
    /// `cutoff`: capture stopped there (at `maxMs`); nothing after it is drawn.
    private func render(raw: URL, to out: URL, maps: [(t: Int64, map: FrameMapping)], covers: [[CGWindowID: CGRect]] = [],
                        fields: [[String: CGRect]] = [],
                        steps all: [RecordedStep], endMs: Double,
                        cutoff: Double? = nil) throws {
        let asset = AVURLAsset(url: raw)
        guard let track = try Capture.blocking(timeoutMs: 30_000, { try await asset.loadTracks(withMediaType: .video) }).first else {
            throw ToolError("the raw video has no frames")
        }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        output.alwaysCopiesSampleData = false
        reader.add(output)
        try? FileManager.default.removeItem(at: out)
        let w = try AVAssetWriter(outputURL: out, fileType: .mp4)
        w.shouldOptimizeForNetworkUse = true
        let inp = AVAssetWriterInput(mediaType: .video, outputSettings: Self.videoSettings(size, bitrate: 5_000_000))
        inp.expectsMediaDataInRealTime = false
        inp.mediaTimeScale = 1000
        w.movieTimeScale = 1000
        let ad = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: inp, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: Int(size.width),
            kCVPixelBufferHeightKey as String: Int(size.height),
        ])
        w.add(inp)
        guard reader.startReading(), w.startWriting() else { throw ToolError("couldn't render the video: \(reader.error ?? w.error.map { $0 as Error } ?? ToolError("?"))") }
        w.startSession(atSourceTime: .zero)
        let limit = cutoff ?? .infinity
        let flat = StepLog.flatten(all).filter { $0.t <= limit }
        // Frames are drawn at the captured times and, from the last frame
        // captured before, at each `renderTimes`: a step that came and went
        // between two captures still gets its caption and marks.
        var extra = RecordingOverlay.renderTimes(flat).filter { $0 <= limit }.map { Int64($0.rounded()) }[...]
        var mi = 0
        var last: CMTime = .zero
        var lastMs: Int64 = -1
        var prevRaw: CGImage?
        func context(_ px: CVPixelBuffer) -> CGContext? {
            CGContext(data: CVPixelBufferGetBaseAddress(px), width: CVPixelBufferGetWidth(px), height: CVPixelBufferGetHeight(px),
                      bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(px), space: CGColorSpaceCreateDeviceRGB(),
                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        }
        func waitForWriter() throws {
            // A writer that failed (a full disk, the encoder) never gets
            // ready again: stop instead of waiting for it.
            while !inp.isReadyForMoreMediaData {
                if w.status == .failed || w.status == .cancelled {
                    reader.cancelReading()
                    throw ToolError("couldn't write the video: \(w.error.map { "\($0)" } ?? "the writer stopped")")
                }
                usleep(2000)
            }
        }
        func mapping(_ ms: Int64) -> FrameMapping {
            while mi + 1 < maps.count && maps[mi + 1].t <= ms { mi += 1 }
            return maps[mi].map
        }
        func coversAt(_ ms: Int64) -> [CGWindowID: CGRect] {
            _ = mapping(ms)
            return mi < covers.count ? covers[mi] : [:]
        }
        func fieldsAt(_ ms: Int64) -> [String: CGRect] {
            _ = mapping(ms)
            return mi < fields.count ? fields[mi] : [:]
        }
        /// The last captured picture again, at `ms`, with what's going on then.
        func copyOfLast(at ms: Int64) throws {
            guard ms > lastMs, let pool = ad.pixelBufferPool else { return }
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
            guard let buffer else { return }
            CVPixelBufferLockBaseAddress(buffer, [])
            if let ctx = context(buffer) {
                // Before the first capture: a plain background, not a later
                // picture (which could show what a step after then typed).
                if let raw = prevRaw {
                    ctx.draw(raw, in: CGRect(origin: .zero, size: size))
                } else {
                    ctx.setFillColor(CGColor(red: 0.11, green: 0.11, blue: 0.12, alpha: 1))
                    ctx.fill(CGRect(origin: .zero, size: size))
                }
                RecordingOverlay.draw(in: ctx, size: size, t: Double(ms), flat: flat, total: all.count, mapping: mapping(ms),
                                      label: label, redactAll: steps.redactAll, covers: coversAt(ms), fields: fieldsAt(ms))
            }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            try waitForWriter()
            let at = CMTime(value: ms, timescale: 1000)
            if ad.append(buffer, withPresentationTime: at) { last = at; lastMs = ms }
        }
        while let sample = output.copyNextSampleBuffer() {
            guard let px = CMSampleBufferGetImageBuffer(sample) else { continue }
            let pts = CMSampleBufferGetPresentationTimeStamp(sample)
            let ms = Int64((pts.seconds * 1000).rounded())
            CVPixelBufferLockBaseAddress(px, [])
            let raw = context(px)?.makeImage()
            CVPixelBufferUnlockBaseAddress(px, [])
            while let e = extra.first, e < ms { extra.removeFirst(); try copyOfLast(at: e) }
            guard ms > lastMs else { continue }
            CVPixelBufferLockBaseAddress(px, [])
            if let ctx = context(px) {
                prevRaw = raw
                RecordingOverlay.draw(in: ctx, size: size, t: Double(ms), flat: flat, total: all.count, mapping: mapping(ms),
                                      label: label, redactAll: steps.redactAll, covers: coversAt(ms), fields: fieldsAt(ms))
            }
            CVPixelBufferUnlockBaseAddress(px, [])
            try waitForWriter()
            if ad.append(px, withPresentationTime: pts) { last = pts; lastMs = ms }
        }
        // Steps after the last frame: on copies of it.
        for e in extra where e > lastMs { try copyOfLast(at: e) }
        inp.markAsFinished()
        // The last frame stays up a moment, so the last step can be read.
        let endAt = max(CMTime(value: Int64(endMs.rounded()), timescale: 1000), last + CMTime(value: 1500, timescale: 1000))
        w.endSession(atSourceTime: endAt)
        let done = DispatchSemaphore(value: 0)
        w.finishWriting { done.signal() }
        done.wait()
        guard w.status == .completed else { throw ToolError("couldn't write the video: \(w.error.map { "\($0)" } ?? "unknown error")") }
    }

    /// Recordings being made or saved right now, in any session: pruning leaves them alone.
    private static let activeLock = NSLock()
    private static var active: Set<String> = []
    static func markActive(_ dir: URL, _ on: Bool) {
        activeLock.lock(); defer { activeLock.unlock() }
        if on { active.insert(dir.standardizedFileURL.path) } else { active.remove(dir.standardizedFileURL.path) }
    }

    /// Deletes all but the newest `keep` recordings, never one under way or `keeping`.
    static func prune(keeping: URL) {
        let fm = FileManager.default
        let dirs = ((try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [])
            .filter(\.hasDirectoryPath).sorted { $0.lastPathComponent > $1.lastPathComponent }
        activeLock.lock(); let busy = active; activeLock.unlock()
        for d in Self.prunable(dirs, keep: keep, protected: busy.union([keeping.standardizedFileURL.path])) {
            try? fm.removeItem(at: d)
        }
    }

    /// Of `dirs` (newest first), the ones past the newest `keep` that aren't `protected` (paths).
    static func prunable(_ dirs: [URL], keep: Int, protected: Set<String>) -> [URL] {
        dirs.dropFirst(keep).filter { !protected.contains($0.standardizedFileURL.path) }
    }
}
