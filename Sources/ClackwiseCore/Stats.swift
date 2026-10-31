import Foundation
import CoreGraphics

/// Aggregate statistics for later tuning. Holds only counts: no text, no key order, no times.
/// Per key: number of presses and a histogram of its impacts (→ median, to find keys that read weak).
public struct StatsFile: Codable {
    public struct Binning: Codable {
        public var lowestBinMg = LogBins.lowerG(0) * 1000
        public var ratioPerBin = exp(LogBins.width)
        public var bins = LogBins.count
    }
    public struct KeyStat: Codable {
        public var presses = 0
        public var medianImpactMg: Double?
        /// Sparse instant-impact histogram: bin index → count.
        public var impactBins: [String: Int] = [:]
    }

    public var about = "Clackwise aggregate stats. Counts only: no typed text, no key order, no timestamps."
    public var savedOn = ""                   // calendar day of the last save
    public var binning = Binning()
    public var presses = 0
    public var noSensor = 0                   // sensor not streaming: played at normal level
    public var impactInstant = [Int](repeating: 0, count: LogBins.count)
    public var impactPeak = [Int](repeating: 0, count: LogBins.count)
    public var gainDb = [Int](repeating: 0, count: 25)   // 1 dB bins, −24 … 0
    public var perKey: [String: KeyStat] = [:]
    /// Key event → sound out (estimate incl. device latency), 0.5 ms bins from 0.
    public var latencyMsHalfBins = [Int](repeating: 0, count: 200)
    // Optional so files from older builds still decode.
    /// Velocity v2 layer position played, 20 bins over 0 (soft) … 1 (hard).
    public var layerPosition: [Int]?
    /// Shock-onset measurement (OnsetMonitor), counters only.
    public var onsets: OnsetStats?

    public init() {}
}

public final class Stats {
    public let url: URL
    private var file: StatsFile
    private var dirty = false
    private let lock = NSLock()

    public static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Clackwise", isDirectory: true)
    }

    public init(url: URL = Stats.directory.appendingPathComponent("stats.json")) {
        self.url = url
        file = (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(StatsFile.self, from: $0) } ?? StatsFile()
    }

    public var snapshot: StatsFile { lock.lock(); defer { lock.unlock() }; return file }

    /// One key press: its instant impact (nil = sensor not streaming) and the velocity it played at.
    public func recordPress(code: CGKeyCode, instant: Double?, velocity: Velocity, v2: Bool) {
        lock.lock(); defer { lock.unlock() }
        file.presses += 1
        if instant == nil { file.noSensor += 1 }
        if let g = instant { file.impactInstant[LogBins.index(g)] += 1 }
        file.gainDb[max(0, min(24, Int((velocity.gainDb + 24).rounded())))] += 1
        if v2 {
            var lp = file.layerPosition ?? [Int](repeating: 0, count: 20)
            lp[max(0, min(19, Int(velocity.layer * 20)))] += 1
            file.layerPosition = lp
        }
        let name = KeycodeMap.name(for: code)
        var k = file.perKey[name] ?? StatsFile.KeyStat()
        k.presses += 1
        if let g = instant { k.impactBins[String(LogBins.index(g)), default: 0] += 1 }
        file.perKey[name] = k
        dirty = true
    }

    /// Full-peak impact (measured 20 ms later in both modes).
    public func recordPeak(_ g: Double?) {
        guard let g else { return }
        lock.lock(); file.impactPeak[LogBins.index(g)] += 1; dirty = true; lock.unlock()
    }

    public func recordLatency(_ ms: [Double]) {
        guard !ms.isEmpty else { return }
        lock.lock(); defer { lock.unlock() }
        for v in ms { file.latencyMsHalfBins[max(0, min(199, Int(v * 2)))] += 1 }
        dirty = true
    }

    /// Adds counters collected by the onset monitor since the last call.
    public func addOnsets(_ delta: OnsetStats) {
        lock.lock(); defer { lock.unlock() }
        var o = file.onsets ?? OnsetStats()
        o.add(delta)
        file.onsets = o
        dirty = true
    }

    public func reset() {
        lock.lock(); file = StatsFile(); dirty = true; lock.unlock()
        save()
    }

    /// Writes the JSON if anything changed (atomic replace, user-only permissions).
    public func save() {
        lock.lock()
        guard dirty else { lock.unlock(); return }
        for (name, var k) in file.perKey {
            var w = [Double](repeating: 0, count: LogBins.count)
            for (i, c) in k.impactBins { if let i = Int(i), i < w.count { w[i] = Double(c) } }
            k.medianImpactMg = LogBins.quantile(w, 0.5).map { (exp($0) * 1000 * 100).rounded() / 100 }
            file.perKey[name] = k
        }
        let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd"
        file.savedOn = df.string(from: Date())
        let snapshot = file
        dirty = false
        lock.unlock()
        writeJSON(snapshot, to: url)
    }
}

/// Learned adaptation, persisted next to the stats.
public struct AdaptationFile: Codable {
    public var calibrationSource: String
    public var instant: AdaptiveTracker?
    public var peak: AdaptiveTracker?
    /// Velocity v2 (per-key corrected impacts), valid for `v2Source`.
    public var v2Source: String?
    public var v2Instant: AdaptiveTracker?
    public var v2Peak: AdaptiveTracker?

    public init(calibrationSource: String, instant: AdaptiveTracker?, peak: AdaptiveTracker?,
                v2Source: String?, v2Instant: AdaptiveTracker?, v2Peak: AdaptiveTracker?) {
        self.calibrationSource = calibrationSource; self.instant = instant; self.peak = peak
        self.v2Source = v2Source; self.v2Instant = v2Instant; self.v2Peak = v2Peak
    }

    public static var url: URL { Stats.directory.appendingPathComponent("adaptation.json") }

    public static func load() -> AdaptationFile? {
        (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(AdaptationFile.self, from: $0) }
    }
}

public func writeJSON<T: Encodable>(_ value: T, to url: URL) {
    let enc = JSONEncoder()
    enc.outputFormatting = [.prettyPrinted, .sortedKeys]
    guard let data = try? enc.encode(value) else { return }
    try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                             attributes: [.posixPermissions: 0o700])
    try? data.write(to: url, options: [.atomic])
    try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
}
