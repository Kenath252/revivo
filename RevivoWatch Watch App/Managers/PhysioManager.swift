//
//  PhysioManager.swift
//  Revivo
//
//  Created by Uduwara Perera on 17/3/2026.
//


import Foundation

class PhysioManager: ObservableObject {
    static let shared = PhysioManager()
    
    private init() {}
    
    private var isRunning = false
    private var lastSentTime: Date = .distantPast
    
    func startStreaming(updateInterval: TimeInterval = 1.0,
                        onUpdate: @escaping ([String: Any]) -> Void) {
        
        guard !isRunning else { return }
        isRunning = true
        
        // Start workout (this enables realtime HR/HRV)
        WorkoutManager.shared.startWorkout()
        
        // Observe HR + HRV changes
        Timer.scheduledTimer(withTimeInterval: updateInterval, repeats: true) { timer in
            if !self.isRunning {
                timer.invalidate()
                return
            }
            
            let hr = WorkoutManager.shared.heartRate
            let hrv = WorkoutManager.shared.hrv
            
            let now = Date()
            
            // Throttle + avoid sending zeros initially
            guard hr > 0 else { return }
            guard now.timeIntervalSince(self.lastSentTime) >= updateInterval else { return }
            
            self.lastSentTime = now
            
            let data: [String: Any] = [
                "hr": hr,
                "hrv": hrv,
                "timestamp": now.timeIntervalSince1970
            ]
            
            onUpdate(data)
        }
    }
    
    func stopStreaming() {
        isRunning = false
        WorkoutManager.shared.stopWorkout()
    }
}
