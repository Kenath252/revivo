//
//  HRMonitoringController.swift
//  Revivo
//
//  Created by Uduwara Perera on 20/11/2025.
//


import HealthKit

class HRMonitoringController {
    static let shared = HRMonitoringController()
    
    private let healthStore = HKHealthStore()
    private var hrQuery: HKAnchoredObjectQuery?
    private var hrvQuery: HKAnchoredObjectQuery?
    
    private init() {}

    func startMonitoring() {
        requestAuthorizationIfNeeded { granted in
            guard granted else {
                print("❌ HR permission not granted")
                return
            }
            self.startHRQuery()
            self.startHRVQuery()

        }
    }

    private func requestAuthorizationIfNeeded(_ completion: @escaping (Bool) -> Void) {
        let types: Set = [
            HKQuantityType.quantityType(forIdentifier: .heartRate)!,
            HKQuantityType.quantityType(forIdentifier: .heartRateVariabilitySDNN)!
        ]
        
        healthStore.requestAuthorization(toShare: [], read: types) { success, _ in
            completion(success)
        }
    }

    private func startHRQuery() {
        let hrType = HKQuantityType.quantityType(forIdentifier: .heartRate)!
        let predicate = HKQuery.predicateForSamples(withStart: Date(), end: nil)
        hrQuery = HKAnchoredObjectQuery(type: hrType,
                                        predicate: predicate,
                                        anchor: nil,
                                        limit: HKObjectQueryNoLimit) { _, samples, _, _, _ in
            self.handleHR(samples)
        }
        hrQuery?.updateHandler = { _, samples, _, _, _ in
            self.handleHR(samples)
        }

        healthStore.execute(hrQuery!)
    }

    private func handleHR(_ samples: [HKSample]?) {
        guard let samples = samples as? [HKQuantitySample] else { return }
        guard let last = samples.last else { return }
        
        let bpm = last.quantity.doubleValue(for: HKUnit(from: "count/min"))
        print("❤️ HR:", bpm)
        
        Detector.shared.updateHR(bpm)
    }

    private func startHRVQuery() {
        let hrvType = HKQuantityType.quantityType(forIdentifier: .heartRateVariabilitySDNN)!
        let predicate = HKQuery.predicateForSamples(withStart: Date(), end: nil)
        
        hrvQuery = HKAnchoredObjectQuery(type: hrvType,
                                         predicate: predicate,
                                         anchor: nil,
                                         limit: HKObjectQueryNoLimit) { _, samples, _, _, _ in
            self.handleHRV(samples)
        }
        
        hrvQuery?.updateHandler = { _, samples, _, _, _ in
            self.handleHRV(samples)
        }

        healthStore.execute(hrvQuery!)
    }

    private func handleHRV(_ samples: [HKSample]?) {
        guard let samples = samples as? [HKQuantitySample], let last = samples.last else { return }
        
        let hrv = last.quantity.doubleValue(for: HKUnit.secondUnit(with: .milli))
        print("💙 HRV:", hrv)
        
        Detector.shared.updateHRV(hrv)
    }
}
