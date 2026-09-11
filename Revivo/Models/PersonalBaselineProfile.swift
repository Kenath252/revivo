import Foundation

struct PersonalBaselineProfile: Codable {
    let participantId: String
    let sourceSessionDirectory: String
    let createdAtS: Double
    let seqMidpoint: Double
    let neutralPollCount: Int
    let nonNeutralPollCount: Int
    let lookbackSeconds: Double
    let defaultCompositeThreshold: Double
    let calibratedCompositeThreshold: Double
    let features: [String: PersonalFeatureBaseline]
}

struct PersonalFeatureBaseline: Codable {
    let mean: Double
    let standardDeviation: Double
    let rangeMinimum: Double
    let rangeMaximum: Double
    let neutralWindowCount: Int
    let fullDayWindowCount: Int
}
