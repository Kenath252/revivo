//
//  RevivoWatchApp.swift
//  RevivoWatch Watch App
//
//  Created by Uduwara Perera on 10/11/2025.
//

import SwiftUI

@main
struct RevivoWatch_Watch_AppApp: App {
    @StateObject private var wcManager = WatchSessionManager.shared
        
    var body: some Scene {
        WindowGroup {
            StartView()
                .onAppear {
                    wcManager.activateSession()
                }
        }
    }
}
