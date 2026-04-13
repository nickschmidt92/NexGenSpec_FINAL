//
//  NetworkMonitor.swift
//  NexGenSpec
//
//  Monitors network connectivity using NWPathMonitor.
//  Singleton ObservableObject that publishes connection state.
//

import Foundation
import Network
import Combine

@MainActor
final class NetworkMonitor: ObservableObject {

    static let shared = NetworkMonitor()

    @Published private(set) var isConnected: Bool = true

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "com.nexgenspec.networkmonitor")

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor in
                self?.isConnected = path.status == .satisfied
            }
        }
        monitor.start(queue: queue)
    }

    deinit {
        monitor.cancel()
    }
}
