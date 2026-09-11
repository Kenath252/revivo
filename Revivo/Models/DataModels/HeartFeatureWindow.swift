import Foundation

struct HeartFeatureWindow: Codable {
    let windowStartS: Double
    let windowEndS: Double
    let hrMean: Double
    let hrvMean: Double
    let sdnnProxy: Double
    let hrSlope: Double
}
