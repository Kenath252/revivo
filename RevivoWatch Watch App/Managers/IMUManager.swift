//
//  IMUManager.swift
//  Revivo
//
//  Created by Uduwara Perera on 19/11/2025.
//


import Foundation
import CoreMotion

class IMUManager: ObservableObject {
    static let shared = IMUManager()
    private let motionManager = CMMotionManager()
    
    private init() {}
    
    var isRunning = false
    
    func startSendingIMU(updateInterval: TimeInterval = 0.1, onUpdate: @escaping ([String: Any]) -> Void) {
        guard motionManager.isDeviceMotionAvailable, !isRunning else { return }
        isRunning = true
        
        motionManager.deviceMotionUpdateInterval = updateInterval
        motionManager.startDeviceMotionUpdates(to: .main) { motion, error in
            guard let motion = motion, error == nil, self.isRunning else { return }
            
            let imuData: [String: Any] = [
                "timestamp": Date().timeIntervalSince1970,
                "attitude_roll": motion.attitude.roll,
                "attitude_pitch": motion.attitude.pitch,
                "attitude_yaw": motion.attitude.yaw,
                "rotation_rate_x": motion.rotationRate.x,
                "rotation_rate_y": motion.rotationRate.y,
                "rotation_rate_z": motion.rotationRate.z,
                "user_accel_x": motion.userAcceleration.x,
                "user_accel_y": motion.userAcceleration.y,
                "user_accel_z": motion.userAcceleration.z
            ]
            
            onUpdate(imuData)
        }
    }
    
    func stopSendingIMU() {
        isRunning = false
        motionManager.stopDeviceMotionUpdates()
    }
}
