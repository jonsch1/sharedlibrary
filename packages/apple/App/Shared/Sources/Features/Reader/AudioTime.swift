import Foundation


func audioTime(_ value: Double) -> String {
    guard value.isFinite, value >= 0 else { return "0:00" }
    let seconds = Int(value)
    return "\(seconds / 60):\(String(format: "%02d", seconds % 60))"
}
