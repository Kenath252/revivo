//
//  RobotMode.swift
//  Revivo
//
//  Created by Uduwara Perera on 10/11/2025.
//

import Foundation

enum RobotMode: String, Identifiable, CaseIterable, Hashable {
    //case background = "Background Mode"
    case interactive = "Interaction"
    case baseline = "Baseline"
    case personalisation = "Personalisation"
    
    static var allCases: [RobotMode] {
        [.interactive, .baseline, .personalisation]
    }

    var id: String { self.rawValue }
}
