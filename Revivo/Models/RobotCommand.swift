//
//  RobotCommand.swift
//  Revivo
//
//  Created by Uduwara Perera on 10/11/2025.
//

import Foundation

class RobotCommand {

    enum State: String {
        case idle = "IDLE"
        case prePunch = "PRE_PUNCH"
        case guardPose = "GUARD"
        case punch = "PUNCH"
        case dodgeLeft = "DODGE_LEFT"
        case dodgeRight = "DODGE_RIGHT"
        case preUppercut = "PRE_UPPERCUT"
        case uppercut = "UPPERCUT"
        case preHookLeft = "PRE_HOOK_LEFT"
        case preHookRight = "PRE_HOOK_RIGHT"
        case hook = "HOOK"

    }
    
    var state: State
    var T: Int
    var base: Double
    var shoulder: Double
    var elbow: Double
    var hand: Double
    var spd: Int
    var acc: Int
    
    init(state: State) {
        self.state = state
        switch state {
        case .idle:
            self.T = 102; self.base = -2; self.shoulder = -0.2; self.elbow = 1.7; self.hand = 3.1415926; self.spd = 0; self.acc = 0
        case .prePunch:
            self.T = 102; self.base = -2; self.shoulder = -0.5; self.elbow = 2.0; self.hand = 3.1415926; self.spd = 0; self.acc = 0
        case .guardPose:
            self.T = 102; self.base = -2; self.shoulder = -1.0; self.elbow = 2.8; self.hand = 3.1415926; self.spd = 0; self.acc = 0
        case .punch:
            self.T = 102; self.base = -2; self.shoulder = 0.5; self.elbow = 1.0; self.hand = 3.1415926; self.spd = 0; self.acc = 0
        case .dodgeLeft:
            self.T = 102; self.base = -2-0.3; self.shoulder = -0.2; self.elbow = 2.0; self.hand = 3.1415926; self.spd = 0; self.acc = 0
        case .dodgeRight:
            self.T = 102; self.base = -2+0.3; self.shoulder = -0.2; self.elbow = 2.0; self.hand = 3.1415926; self.spd = 0; self.acc = 0
        case .preUppercut:
            self.T = 102; self.base = -2; self.shoulder = 1.0; self.elbow = -2.0; self.hand = 3.1415926; self.spd = 0; self.acc = 0
        case .uppercut:
            self.T = 102; self.base = -2; self.shoulder = 0.6; self.elbow = 1.5; self.hand = 3.1415926; self.spd = 0; self.acc = 0
        case .preHookLeft:
            self.T = 102; self.base = -2-0.7; self.shoulder = -0.5; self.elbow = 2.0; self.hand = 3.1415926; self.spd = 0; self.acc = 0
        case .preHookRight:
            self.T = 102; self.base = -2+0.7; self.shoulder = -0.5; self.elbow = 2.0; self.hand = 3.1415926; self.spd = 0; self.acc = 0
        case .hook:
            self.T = 102; self.base = -2; self.shoulder = 0.5; self.elbow = 1.0; self.hand = 3.1415926; self.spd = 0; self.acc = 0
        }
    }
}
