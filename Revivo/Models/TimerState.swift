//
//  TimerState.swift
//  Revivo
//
//  Created by Uduwara Perera on 10/11/2025.
//

import Foundation

struct TimerState {
    var timeElapsed: TimeInterval = 0
    var isRunning: Bool = false
    var isStopped: Bool {
        !isRunning && timeElapsed == 0
    }
    
    var timeString: String {
        let totalSeconds = Int(timeElapsed)           // Convert to integer seconds
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60              // Use modulus to get remaining seconds
        return String(format: "%02d:%02d", minutes, seconds)
        }
}
