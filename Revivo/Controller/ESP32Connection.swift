//
//  ESP32Connection.swift
//  Revivo Watch App
//
//  Created by Uduwara Perera on 7/11/2025.
//


import Foundation
import Network

class ESP32Connection {
    private let espIP: String
    private let espPort: NWEndpoint.Port
    private var connection: NWConnection?
    private let connectionQueue = DispatchQueue(label: "Revivo.esp32Connection")
    private var reconnectWorkItem: DispatchWorkItem?
    private var isDisconnectRequested = false
    private let reconnectDelay: TimeInterval = 2.0
    
    var onObjectUpdate: ((Bool) -> Void)?
    
    init(ip: String, port: UInt16) {
        self.espIP = ip
        self.espPort = NWEndpoint.Port(rawValue: port)!
    }
    
    func connect() {
        connectionQueue.async {
            self.isDisconnectRequested = false
            self.startConnection()
        }
    }

    private func startConnection() {
        reconnectWorkItem?.cancel()
        reconnectWorkItem = nil

        connection?.stateUpdateHandler = nil
        connection?.cancel()

        logESP("connect requested host=\(espIP) port=\(espPort)")
        let newConnection = NWConnection(host: NWEndpoint.Host(espIP), port: espPort, using: .tcp)
        connection = newConnection
        newConnection.stateUpdateHandler = { [weak self, weak newConnection] state in
            guard let self,
                  let newConnection,
                  self.connection === newConnection
            else { return }

            switch state {
            case .ready:
                self.reconnectWorkItem?.cancel()
                self.reconnectWorkItem = nil
                self.logESP("state=ready connected")
                self.receiveData(on: newConnection)
            case .setup:
                self.logESP("state=setup")
            case .preparing:
                self.logESP("state=preparing")
            case .waiting(let error):
                self.logESP("state=waiting error=\(error.localizedDescription)")
                self.scheduleReconnect(reason: "waiting: \(error.localizedDescription)")
            case .failed(let error):
                self.logESP("state=failed error=\(error.localizedDescription)")
                self.scheduleReconnect(reason: "failed: \(error.localizedDescription)")
            case .cancelled:
                self.logESP("state=cancelled")
                if !self.isDisconnectRequested {
                    self.scheduleReconnect(reason: "cancelled")
                }
            @unknown default:
                self.logESP("state=unknown")
                self.scheduleReconnect(reason: "unknown state")
            }
        }
        newConnection.start(queue: connectionQueue)
    }
    
    private func receiveData(on activeConnection: NWConnection) {
        activeConnection.receive(minimumIncompleteLength: 1, maximumLength: 1024) { [weak self, weak activeConnection] data, _, isComplete, error in
            guard let self,
                  let activeConnection,
                  self.connection === activeConnection
            else { return }

            if let data = data, let str = String(data: data, encoding: .utf8) {
                self.logESP("RX bytes=\(data.count) text=\(String(str.trimmingCharacters(in: .whitespacesAndNewlines).prefix(160)))")
                self.handleMessage(str)
            }

            if isComplete || error != nil {
                self.logESP("receive ended isComplete=\(isComplete) error=\(error?.localizedDescription ?? "nil")")
                self.scheduleReconnect(reason: "receive ended")
            } else {
                self.receiveData(on: activeConnection)
            }
        }
    }

    private func scheduleReconnect(reason: String) {
        guard !isDisconnectRequested else { return }
        guard reconnectWorkItem == nil else { return }

        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.reconnectWorkItem = nil
            guard !self.isDisconnectRequested else { return }

            self.logESP("reconnect attempt reason=\(reason)")
            self.startConnection()
        }

        reconnectWorkItem = workItem
        logESP("reconnect scheduled in \(String(format: "%.1f", reconnectDelay))s reason=\(reason)")
        connectionQueue.asyncAfter(deadline: .now() + reconnectDelay, execute: workItem)
    }
    
    private func handleMessage(_ message: String) {
        for line in message.components(separatedBy: .newlines) {
            guard let detected = parseObjectDetection(from: line) else {
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.lowercased().contains("object"), !trimmed.isEmpty {
                    logESP("object message not parsed: \(trimmed)")
                }
                continue
            }

            logESP("ToF objectDetected=\(detected)")
            DispatchQueue.main.async { self.onObjectUpdate?(detected) }
        }
    }

    private func parseObjectDetection(from message: String) -> Bool? {
        let compact = message
            .lowercased()
            .filter { !$0.isWhitespace }

        if compact.contains("object:1") ||
            compact.contains("object=1") ||
            compact.contains("\"object\":1") ||
            compact.contains("object:true") ||
            compact.contains("\"object\":true") ||
            compact.contains("objectdetected:1") ||
            compact.contains("objectdetected=1") ||
            compact.contains("\"objectdetected\":1") ||
            compact.contains("objectdetected:true") ||
            compact.contains("\"objectdetected\":true") ||
            containsToFBoolean(compact, value: true) {
            return true
        }

        if compact.contains("object:0") ||
            compact.contains("object=0") ||
            compact.contains("\"object\":0") ||
            compact.contains("object:false") ||
            compact.contains("\"object\":false") ||
            compact.contains("objectdetected:0") ||
            compact.contains("objectdetected=0") ||
            compact.contains("\"objectdetected\":0") ||
            compact.contains("objectdetected:false") ||
            compact.contains("\"objectdetected\":false") ||
            containsToFBoolean(compact, value: false) {
            return false
        }

        return nil
    }

    private func containsToFBoolean(_ message: String, value: Bool) -> Bool {
        let boolPattern = value ? #"(tof\d+|tof):(?:1|true)"# : #"(tof\d+|tof):(?:0|false)"#
        guard let regex = try? NSRegularExpression(pattern: boolPattern) else { return false }
        return regex.firstMatch(
            in: message,
            range: NSRange(message.startIndex..., in: message)
        ) != nil
    }

    func disconnect() {
        connectionQueue.async {
            self.logESP("disconnect requested")
            self.isDisconnectRequested = true
            self.reconnectWorkItem?.cancel()
            self.reconnectWorkItem = nil
            self.connection?.stateUpdateHandler = nil
            self.connection?.cancel()
            self.connection = nil
        }
    }

    private func logESP(_ message: String) {
        print("📡 [\(Self.logTimestamp())] ESP32 \(message)")
    }

    private static func logTimestamp() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: Date())
    }
}
