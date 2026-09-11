import Foundation

final class HeartFeatureProcessor {
    private let windowSeconds: Double
    private let stepSeconds: Double
    private let interpolationLimitSeconds: Double
    private let outlierSDMultiplier: Double

    private var samples: [HeartSample] = []
    private var lastProcessedWindowEndS: Double = 0

    init(
        windowSeconds: Double = 20.0,
        stepSeconds: Double = 10.0,
        interpolationLimitSeconds: Double = 10.0,
        outlierSDMultiplier: Double = 3.0
    ) {
        self.windowSeconds = windowSeconds
        self.stepSeconds = stepSeconds
        self.interpolationLimitSeconds = interpolationLimitSeconds
        self.outlierSDMultiplier = outlierSDMultiplier
    }

    func append(hr: Double, hrv: Double?, timestampS: Double) -> [HeartFeatureWindow] {
        guard hr.isFinite, hr > 0 else { return [] }

        samples.append(HeartSample(t: timestampS, hr: hr, hrv: hrv?.isFinite == true ? hrv : nil))
        samples.sort { $0.t < $1.t }
        trimSamples(currentTimeS: timestampS)

        return processWindows(currentTimeS: timestampS)
    }

    private func trimSamples(currentTimeS: Double) {
        let cutoff = currentTimeS - 120.0
        samples.removeAll { $0.t < cutoff }
    }

    private func processWindows(currentTimeS: Double) -> [HeartFeatureWindow] {
        guard let firstTime = samples.first?.t,
              currentTimeS - firstTime >= windowSeconds
        else { return [] }

        var windows: [HeartFeatureWindow] = []
        var nextWindowEnd = lastProcessedWindowEndS == 0
            ? firstTime + windowSeconds
            : lastProcessedWindowEndS + stepSeconds

        while currentTimeS >= nextWindowEnd {
            let windowStart = nextWindowEnd - windowSeconds
            let windowSamples = samples.filter { $0.t >= windowStart && $0.t < nextWindowEnd }

            if !windowSamples.isEmpty {
                windows.append(extractFeatures(from: windowSamples, startS: windowStart, endS: nextWindowEnd))
            }

            lastProcessedWindowEndS = nextWindowEnd
            nextWindowEnd += stepSeconds
        }

        return windows
    }

    private func extractFeatures(from windowSamples: [HeartSample], startS: Double, endS: Double) -> HeartFeatureWindow {
        let masked = maskOutliers(windowSamples)
        let interpolated = interpolateShortGaps(masked)
        let values = interpolated.compactMap(\.hr)

        guard !values.isEmpty else {
            return HeartFeatureWindow(
                windowStartS: startS,
                windowEndS: endS,
                hrMean: .nan,
                hrvMean: .nan,
                sdnnProxy: .nan,
                hrSlope: .nan
            )
        }

        let rrApproxMs = values.map { 60_000.0 / $0 }

        return HeartFeatureWindow(
            windowStartS: startS,
            windowEndS: endS,
            hrMean: mean(values),
            hrvMean: mean(interpolated.compactMap(\.hrv)),
            sdnnProxy: standardDeviation(rrApproxMs),
            hrSlope: slope(values)
        )
    }

    private func maskOutliers(_ windowSamples: [HeartSample]) -> [TimedHeartValue] {
        let values = windowSamples.map(\.hr)
        let mu = mean(values)
        let sd = standardDeviation(values)

        guard sd.isFinite, sd > 0 else {
            return windowSamples.map { TimedHeartValue(t: $0.t, hr: $0.hr, hrv: $0.hrv) }
        }

        let low = mu - outlierSDMultiplier * sd
        let high = mu + outlierSDMultiplier * sd

        return windowSamples.map { sample in
            let isOutlier = sample.hr < low || sample.hr > high
            return TimedHeartValue(t: sample.t, hr: isOutlier ? nil : sample.hr, hrv: sample.hrv)
        }
    }

    private func interpolateShortGaps(_ values: [TimedHeartValue]) -> [TimedHeartValue] {
        var result = values
        guard result.count > 2 else { return result }

        var index = 0
        while index < result.count {
            guard result[index].hr == nil else {
                index += 1
                continue
            }

            let gapStart = index
            while index < result.count, result[index].hr == nil {
                index += 1
            }

            let gapEnd = index - 1
            let before = gapStart - 1
            let after = index

            guard before >= 0,
                  after < result.count,
                  let beforeHR = result[before].hr,
                  let afterHR = result[after].hr
            else { continue }

            let gapSeconds = result[after].t - result[before].t
            guard gapSeconds <= interpolationLimitSeconds else { continue }

            let beforeTime = result[before].t
            let afterTime = result[after].t
            for fillIndex in gapStart...gapEnd {
                let alpha = (result[fillIndex].t - beforeTime) / max(afterTime - beforeTime, .leastNonzeroMagnitude)
                result[fillIndex].hr = beforeHR + alpha * (afterHR - beforeHR)
            }
        }

        return result
    }

    private func mean(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return .nan }
        return values.reduce(0, +) / Double(values.count)
    }

    private func standardDeviation(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return .nan }

        let mu = mean(values)
        let variance = values.reduce(0) { total, value in
            let diff = value - mu
            return total + diff * diff
        } / Double(values.count)

        return sqrt(variance)
    }

    private func slope(_ values: [Double]) -> Double {
        guard values.count > 2 else { return .nan }

        let xMean = Double(values.count - 1) / 2.0
        let yMean = mean(values)
        var numerator = 0.0
        var denominator = 0.0

        for (index, value) in values.enumerated() {
            let x = Double(index)
            numerator += (x - xMean) * (value - yMean)
            denominator += (x - xMean) * (x - xMean)
        }

        guard denominator > 0 else { return .nan }
        return numerator / denominator
    }
}

private struct HeartSample {
    let t: Double
    let hr: Double
    let hrv: Double?
}

private struct TimedHeartValue {
    let t: Double
    var hr: Double?
    let hrv: Double?
}
