import Foundation

public struct LinkMetrics: Sendable, Equatable {
    public var latencyMs: Double
    public var lossFraction: Double
    public var jitterMs: Double
    public var ageSeconds: Double
    public var bandwidthKbps: Double

    public init(latencyMs: Double, lossFraction: Double, jitterMs: Double, ageSeconds: Double, bandwidthKbps: Double) {
        self.latencyMs = latencyMs
        self.lossFraction = lossFraction
        self.jitterMs = jitterMs
        self.ageSeconds = ageSeconds
        self.bandwidthKbps = bandwidthKbps
    }

    /// latency first, then loss, then jitter; young links pay a penalty so a fresh flapping link does not steal traffic.
    public var cost: Double {
        latencyMs + 200 * lossFraction + 5 * jitterMs + (ageSeconds < 5 ? 30 : 0)
    }
}

/// Per-link estimator fed by probe results.
public struct LinkMetricsEstimator: Sendable {
    public static let alpha = 0.2
    public static let lossWindow = 32

    private let bandwidthKbps: Double
    private var upSince: Date
    private var latencyMs: Double?
    private var jitterMs: Double = 0
    private var lossRing: [Bool] = []
    private var lossIndex = 0
    private var probeCount = 0

    public init(bandwidthKbps: Double, upSince: Date) {
        self.bandwidthKbps = bandwidthKbps
        self.upSince = upSince
    }

    private mutating func pushLoss(_ lost: Bool) {
        if lossRing.count < Self.lossWindow {
            lossRing.append(lost)
        } else {
            lossRing[lossIndex % Self.lossWindow] = lost
        }
        lossIndex += 1
    }

    public mutating func recordProbe(rttMs: Double) {
        let sample = rttMs / 2
        if let previous = latencyMs {
            jitterMs = (1 - Self.alpha) * jitterMs + Self.alpha * abs(sample - previous)
            latencyMs = (1 - Self.alpha) * previous + Self.alpha * sample
        } else {
            latencyMs = sample
        }
        probeCount += 1
        pushLoss(false)
    }

    public mutating func recordLoss() {
        pushLoss(true)
    }

    public mutating func flapped(at date: Date) {
        upSince = date
    }

    public func metrics(now: Date) -> LinkMetrics {
        let lossFraction = lossRing.isEmpty ? 0 : Double(lossRing.filter { $0 }.count) / Double(lossRing.count)
        return LinkMetrics(
            latencyMs: latencyMs ?? 0,
            lossFraction: lossFraction,
            jitterMs: jitterMs,
            ageSeconds: now.timeIntervalSince(upSince),
            bandwidthKbps: bandwidthKbps
        )
    }

    public var sampleCount: Int { probeCount }
}
