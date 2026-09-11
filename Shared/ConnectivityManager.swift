//
//  ConnectivityManager.swift
//  Revivo
//
//  Created by Uduwara Perera on 10/11/2025.
//


import Foundation
import WatchConnectivity
import Combine

final class ConnectivityManager: NSObject, ObservableObject, WCSessionDelegate {
    static let shared = ConnectivityManager()
    @Published var receivedData: [String: Any] = [:]

    private override init() { super.init(); activate() }

    func activate() {
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    func send(_ message: [String: Any]) {
        let session = WCSession.default
        if session.isReachable {
            session.sendMessage(message, replyHandler: nil, errorHandler: nil)
        }
    }

    func session(_ session: WCSession, didReceiveMessage message: [String : Any]) {
        DispatchQueue.main.async {
            self.receivedData = message
        }
    }
}
