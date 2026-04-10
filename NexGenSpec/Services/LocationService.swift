//
//  LocationService.swift
//  NexGenSpec
//
//  Lightweight location helper for reverse-geocoding the current address.
//  Used on the new-inspection form to auto-fill property address.
//

import Foundation
import CoreLocation

@MainActor
final class LocationService: NSObject, ObservableObject, CLLocationManagerDelegate {

    @Published private(set) var address: String?
    @Published private(set) var isLocating = false
    @Published private(set) var errorMessage: String?

    private let manager = CLLocationManager()
    private var completion: ((String?) -> Void)?

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
    }

    /// Requests a one-shot location fix and reverse-geocodes to a street address.
    func fetchCurrentAddress(completion: @escaping (String?) -> Void) {
        self.completion = completion
        errorMessage = nil
        isLocating = true

        switch manager.authorizationStatus {
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
        case .authorizedWhenInUse, .authorizedAlways:
            manager.requestLocation()
        case .denied, .restricted:
            isLocating = false
            errorMessage = "Location access denied. Enable in Settings > Privacy > Location."
            completion(nil)
        @unknown default:
            isLocating = false
            completion(nil)
        }
    }

    // MARK: - CLLocationManagerDelegate

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in
            if manager.authorizationStatus == .authorizedWhenInUse || manager.authorizationStatus == .authorizedAlways {
                if isLocating {
                    manager.requestLocation()
                }
            } else if manager.authorizationStatus == .denied {
                isLocating = false
                errorMessage = "Location access denied."
                completion?(nil)
                completion = nil
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        Task { @MainActor in
            await reverseGeocode(location)
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in
            isLocating = false
            errorMessage = "Could not determine location."
            Diagnostics.logError(context: "Location failed", error: error)
            completion?(nil)
            completion = nil
        }
    }

    // MARK: - Geocoding

    private func reverseGeocode(_ location: CLLocation) async {
        let geocoder = CLGeocoder()
        do {
            let placemarks = try await geocoder.reverseGeocodeLocation(location)
            if let place = placemarks.first {
                let parts = [
                    place.subThoroughfare,      // street number
                    place.thoroughfare,          // street name
                    place.locality,              // city
                    place.administrativeArea,    // state
                    place.postalCode             // zip
                ].compactMap { $0 }
                let addr = parts.joined(separator: " ")
                address = addr
                isLocating = false
                completion?(addr.isEmpty ? nil : addr)
            } else {
                isLocating = false
                completion?(nil)
            }
        } catch {
            isLocating = false
            errorMessage = "Could not determine address."
            Diagnostics.logError(context: "Reverse geocode failed", error: error)
            completion?(nil)
        }
        completion = nil
    }
}
