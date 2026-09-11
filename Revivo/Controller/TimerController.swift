//
//  TimerController.swift
//  Revivo Watch App
//
//  Created by Uduwara Perera on 7/11/2025.
//

// TimerController.swift
import Foundation
import Combine

final class TimerController: ObservableObject {
    static let shared = TimerController()   // 👈 Shared instance
    
    @Published var timerState = TimerState()
    private var timer: AnyCancellable?

    private init() {} // prevent accidental new instances

    func startTimer(reset: Bool = false) {
        if reset {
            timerState.timeElapsed = 0
        }
        guard !timerState.isRunning else { return }

        timerState.isRunning = true
        timer = Timer.publish(every: 1, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                self?.timerState.timeElapsed += 1
            }
    }

    func pauseTimer() {
        timer?.cancel()
        timer = nil
        timerState.isRunning = false
    }
    
    func startPauseTimer() {
        if timerState.isRunning {
            pauseTimer()
        } else {
            startTimer()
        }
    }
    
    func stopTimer() {
        timer?.cancel()
        timer = nil
        timerState.isRunning = false
        timerState.timeElapsed = 0
    }
}
