//
//  RevivoApp.swift
//  Revivo
//
//  Created by Uduwara Perera on 10/11/2025.
//

import SwiftUI

@main
struct RevivoApp: App {
    init() {
        _ = PhoneWCManager.shared
        print("📱 WCSession activated at app launch")
    }
    var body: some Scene {
        WindowGroup {
            PhoneStartView()

        }
    }
}
