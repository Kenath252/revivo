//
//  WorkoutManager.swift
//  Revivo
//

import Foundation
import HealthKit

class WorkoutManager: NSObject, ObservableObject {
    static let shared = WorkoutManager()
    
    private let healthStore = HKHealthStore()
    
    private var workoutSession: HKWorkoutSession?
    private var workoutBuilder: HKLiveWorkoutBuilder?
    private var sessionStartDate: Date?  // Track start date manually
    
    @Published var heartRate: Double = 0
    @Published var hrv: Double = 0
    
    private override init() {
        super.init()
    }
    
    // MARK: - Start Workout
    func startWorkout() {
        if workoutSession != nil {
            print("⚠️ Workout already running")
            return
        }

        requestHealthKitAuthorization { [weak self] granted in
            guard let self = self else { return }
            if !granted {
                print("❌ Cannot start workout — HealthKit not authorized")
                return
            }

            DispatchQueue.main.async {
                let startDate = Date()
                self.sessionStartDate = startDate

                let configuration = HKWorkoutConfiguration()
                configuration.activityType = .mindAndBody
                configuration.locationType = .indoor

                do {
                    self.workoutSession = try HKWorkoutSession(
                        healthStore: self.healthStore,
                        configuration: configuration
                    )

                    self.workoutBuilder = self.workoutSession?.associatedWorkoutBuilder()

                    guard let builder = self.workoutBuilder else { return }

                    builder.dataSource = HKLiveWorkoutDataSource(
                        healthStore: self.healthStore,
                        workoutConfiguration: configuration
                    )

                    builder.delegate = self

                    self.workoutSession?.startActivity(with: startDate)

                    builder.beginCollection(withStart: startDate) { success, error in
                        if let error = error {
                            print("❌ Failed to start workout: \(error.localizedDescription)")
                        } else {
                            print("✅ Workout started (passive sensing)")
                        }
                    }

                } catch {
                    print("❌ Failed to create workout session: \(error.localizedDescription)")
                    self.workoutSession = nil
                    self.workoutBuilder = nil
                }
            }
        }
    }

    // MARK: - Pause Workout
    func pauseWorkout() {
        workoutSession?.pause()
        print("⏸ Workout paused")
    }
    
    // MARK: - Stop Workout
    func stopWorkout() {
        guard let builder = workoutBuilder else { return }
        let endDate = Date()
        
        workoutSession?.stopActivity(with: endDate)
        builder.endCollection(withEnd: endDate) { _, _ in
            builder.finishWorkout { workout, error in
                if let error = error {
                    print("❌ Failed to finish workout: \(error.localizedDescription)")
                } else {
                    print("✅ Workout finished and logged to Health app")
                }
            }
        }
        
        // Reset session & builder
        workoutSession = nil
        workoutBuilder = nil
        sessionStartDate = nil
        heartRate = 0
        hrv = 0
    }
}

// MARK: - HKLiveWorkoutBuilderDelegate
extension WorkoutManager: HKLiveWorkoutBuilderDelegate {
    
    func requestHealthKitAuthorization(completion: @escaping (Bool) -> Void) {
        guard HKHealthStore.isHealthDataAvailable() else {
            print("❌ Health data not available")
            completion(false)
            return
        }
        
        let typesToShare: Set = [
            HKObjectType.workoutType()
        ]
        
        let typesToRead: Set = [
            HKQuantityType.quantityType(forIdentifier: .heartRate)!,
            HKQuantityType.quantityType(forIdentifier: .heartRateVariabilitySDNN)!
        ]
        
        healthStore.requestAuthorization(toShare: typesToShare, read: typesToRead) { success, error in
            if let error = error {
                print("❌ HealthKit authorization error: \(error.localizedDescription)")
            }
            completion(success)
        }
    }
    
    func workoutBuilderDidCollectEvent(_ workoutBuilder: HKLiveWorkoutBuilder) {
        // Can handle pause/resume events if needed
    }
    
    func workoutBuilder(_ workoutBuilder: HKLiveWorkoutBuilder,
                        didCollectDataOf types: Set<HKSampleType>) {

        var currentHR: Double?
        var currentHRV: Double?

        // ❤️ Heart Rate
        if let hrType = HKQuantityType.quantityType(forIdentifier: .heartRate),
           types.contains(hrType),
           let stats = workoutBuilder.statistics(for: hrType),
           let bpm = stats.mostRecentQuantity()?.doubleValue(for: HKUnit(from: "count/min")) {

            currentHR = bpm
            
            DispatchQueue.main.async {
                self.heartRate = bpm
            }
        }

        // 💙 HRV
        if let hrvType = HKQuantityType.quantityType(forIdentifier: .heartRateVariabilitySDNN),
           types.contains(hrvType),
           let stats = workoutBuilder.statistics(for: hrvType),
           let hrvValue = stats.mostRecentQuantity()?.doubleValue(for: HKUnit.secondUnit(with: .milli)) {

            currentHRV = hrvValue
            
            DispatchQueue.main.async {
                self.hrv = hrvValue
            }
        }

        // 🚀 SEND DATA TO IPHONE
        if currentHR != nil || currentHRV != nil {
            WatchSessionManager.shared.sendPhysioData(
                hr: currentHR,
                hrv: currentHRV
            )
        }
    }
}
