//
//  WeatherService.swift
//  NexGenSpec
//
//  Fetches current weather conditions at inspection time using WeatherKit.
//  Gracefully degrades when WeatherKit or location permission is unavailable.
//

import Foundation
import CoreLocation
import WeatherKit
import os

// MARK: - Weather Data Model

/// Stores weather conditions captured at inspection time.
public struct WeatherData: Codable, Equatable {
    public var temperature: Double      // Fahrenheit
    public var conditions: String       // e.g. "Sunny", "Cloudy", "Rain"
    public var humidity: Double         // 0–100 percentage
    public var windSpeed: Double        // mph
    public var capturedAt: Date

    public init(temperature: Double = 0, conditions: String = "Unknown", humidity: Double = 0, windSpeed: Double = 0, capturedAt: Date = Date()) {
        self.temperature = temperature
        self.conditions = conditions
        self.humidity = humidity
        self.windSpeed = windSpeed
        self.capturedAt = capturedAt
    }

    /// Formatted temperature string.
    public var temperatureString: String {
        String(format: "%.0f", temperature) + "\u{00B0}F"
    }

    /// Formatted humidity string.
    public var humidityString: String {
        String(format: "%.0f%%", humidity)
    }

    /// Formatted wind speed string.
    public var windSpeedString: String {
        String(format: "%.0f mph", windSpeed)
    }
}

// MARK: - Weather Service

@MainActor
final class WeatherService: NSObject, ObservableObject, CLLocationManagerDelegate {

    @Published private(set) var weatherData: WeatherData?
    @Published private(set) var isFetching = false
    @Published private(set) var errorMessage: String?

    private let locationManager = CLLocationManager()
    private var completion: ((WeatherData?) -> Void)?

    /// Dedicated logger so the full weather fetch path is visible live in
    /// Console.app on a real device (filter subsystem = bundle id, category
    /// = "WeatherKit"). Dynamic values are logged `.public` because this is a
    /// diagnostic aid for an on-device failure we can't reproduce in the
    /// simulator — see the catch block in `fetchWeather(at:)`.
    private let log = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.nexgenspec",
        category: "WeatherKit"
    )

    private func authString(_ status: CLAuthorizationStatus) -> String {
        switch status {
        case .notDetermined:      return "notDetermined"
        case .restricted:         return "restricted"
        case .denied:             return "denied"
        case .authorizedAlways:   return "authorizedAlways"
        case .authorizedWhenInUse: return "authorizedWhenInUse"
        @unknown default:         return "unknown(\(status.rawValue))"
        }
    }

    override init() {
        super.init()
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyKilometer
    }

    /// Fetches current weather for the device location. Calls completion with result or nil.
    func fetchCurrentWeather(completion: ((WeatherData?) -> Void)? = nil) {
        self.completion = completion
        errorMessage = nil
        isFetching = true

        let status = locationManager.authorizationStatus
        log.info("fetchCurrentWeather: location auth = \(self.authString(status), privacy: .public)")
        Diagnostics.logInfo("WeatherKit: fetch start (auth=\(authString(status)))")

        switch status {
        case .notDetermined:
            log.info("Auth not determined — requesting When-In-Use authorization")
            locationManager.requestWhenInUseAuthorization()
        case .authorizedWhenInUse, .authorizedAlways:
            log.info("Authorized — requesting one-shot location")
            locationManager.requestLocation()
        case .denied, .restricted:
            log.error("Location permission denied/restricted — cannot fetch weather")
            Diagnostics.logError(context: "WeatherKit: location permission denied/restricted")
            isFetching = false
            errorMessage = "Location permission denied"
            self.weatherData = nil
            completion?(nil)
            self.completion = nil
        @unknown default:
            log.error("Unknown location auth status: \(status.rawValue, privacy: .public)")
            isFetching = false
            errorMessage = "Location status unknown"
            completion?(nil)
            self.completion = nil
        }
    }

    /// Public retry entry point. Clears cached error and starts fresh.
    func retry(completion: ((WeatherData?) -> Void)? = nil) {
        errorMessage = nil
        fetchCurrentWeather(completion: completion)
    }

    // MARK: - CLLocationManagerDelegate

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in
            log.info("Auth changed to \(self.authString(status), privacy: .public) (isFetching=\(self.isFetching, privacy: .public))")
            if status == .authorizedWhenInUse || status == .authorizedAlways {
                if isFetching {
                    manager.requestLocation()
                }
            } else if status == .denied {
                isFetching = false
                errorMessage = "Location permission denied"
                completion?(nil)
                completion = nil
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        Task { @MainActor in
            // Coordinates rounded to ~2 decimals (~1km) so the log confirms a
            // sane fix without recording precise location.
            log.info("Location received: ~\(location.coordinate.latitude, format: .fixed(precision: 2), privacy: .public), ~\(location.coordinate.longitude, format: .fixed(precision: 2), privacy: .public) (accuracy \(location.horizontalAccuracy, format: .fixed(precision: 0), privacy: .public)m)")
            await fetchWeather(at: location)
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        let errDesc = error.localizedDescription
        Task { @MainActor in
            log.error("Location request failed: \(errDesc, privacy: .public)")
            Diagnostics.logError(context: "WeatherKit: location request failed", error: error)
            isFetching = false
            errorMessage = "Location error: \(errDesc)"
            completion?(nil)
            completion = nil
        }
    }

    // MARK: - WeatherKit fetch

    private func fetchWeather(at location: CLLocation) async {
        log.info("Calling WeatherKit weather(for:) …")
        Diagnostics.logInfo("WeatherKit: weather(for:) call starting")
        do {
            let weatherService = WeatherService_Kit()
            let weather = try await weatherService.weather(for: location)
            let current = weather.currentWeather

            let data = WeatherData(
                temperature: current.temperature.converted(to: .fahrenheit).value,
                conditions: mapCondition(current.condition),
                humidity: current.humidity * 100,
                windSpeed: current.wind.speed.converted(to: .milesPerHour).value,
                capturedAt: Date()
            )

            log.info("WeatherKit success: \(data.temperatureString, privacy: .public) \(data.conditions, privacy: .public)")
            Diagnostics.logInfo("WeatherKit: success \(data.temperatureString) \(data.conditions)")
            self.weatherData = data
            isFetching = false
            completion?(data)
        } catch {
            // WeatherKit errors are notoriously opaque (`localizedDescription`
            // is often just "The operation couldn't be completed"). Log the
            // full error, its Swift type, and the underlying NSError
            // domain/code so the real on-device cause — missing entitlement,
            // JWT/auth failure, or network — is identifiable in Console.app
            // and the persistent diagnostics log. This is the failure that
            // was previously swallowed silently.
            let ns = error as NSError
            log.error("WeatherKit FAILED: \(String(describing: error), privacy: .public) | type=\(String(describing: type(of: error)), privacy: .public) | domain=\(ns.domain, privacy: .public) code=\(ns.code, privacy: .public) | \(error.localizedDescription, privacy: .public)")
            Diagnostics.logError(context: "WeatherKit: weather(for:) failed [domain=\(ns.domain) code=\(ns.code) type=\(type(of: error))]", error: error)
            isFetching = false
            errorMessage = "WeatherKit: \(error.localizedDescription)"
            completion?(nil)
        }
        completion = nil
    }

    private func mapCondition(_ condition: WeatherCondition) -> String {
        switch condition {
        case .clear, .mostlyClear:
            return "Sunny"
        case .partlyCloudy:
            return "Partly Cloudy"
        case .mostlyCloudy, .cloudy:
            return "Cloudy"
        case .rain, .heavyRain:
            return "Rain"
        case .drizzle:
            return "Drizzle"
        case .snow, .heavySnow, .flurries:
            return "Snow"
        case .sleet, .freezingRain, .freezingDrizzle:
            return "Sleet"
        case .thunderstorms, .strongStorms:
            return "Thunderstorms"
        case .windy, .breezy:
            return "Windy"
        case .foggy, .haze, .smoky:
            return "Foggy"
        case .blowingDust:
            return "Dusty"
        default:
            return "Cloudy"
        }
    }
}

/// Wrapper to avoid name conflict with our WeatherService class.
private struct WeatherService_Kit {
    private let service = WeatherKit.WeatherService.shared

    func weather(for location: CLLocation) async throws -> Weather {
        try await service.weather(for: location)
    }
}
