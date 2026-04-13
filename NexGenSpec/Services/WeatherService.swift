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

        switch locationManager.authorizationStatus {
        case .notDetermined:
            locationManager.requestWhenInUseAuthorization()
        case .authorizedWhenInUse, .authorizedAlways:
            locationManager.requestLocation()
        case .denied, .restricted:
            isFetching = false
            errorMessage = "Weather unavailable"
            self.weatherData = nil
            completion?(nil)
            self.completion = nil
        @unknown default:
            isFetching = false
            completion?(nil)
            self.completion = nil
        }
    }

    // MARK: - CLLocationManagerDelegate

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in
            if manager.authorizationStatus == .authorizedWhenInUse || manager.authorizationStatus == .authorizedAlways {
                if isFetching {
                    manager.requestLocation()
                }
            } else if manager.authorizationStatus == .denied {
                isFetching = false
                errorMessage = "Weather unavailable"
                completion?(nil)
                completion = nil
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        Task { @MainActor in
            await fetchWeather(at: location)
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in
            isFetching = false
            errorMessage = "Weather unavailable"
            completion?(nil)
            completion = nil
        }
    }

    // MARK: - WeatherKit fetch

    private func fetchWeather(at location: CLLocation) async {
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

            self.weatherData = data
            isFetching = false
            completion?(data)
        } catch {
            isFetching = false
            errorMessage = "Weather unavailable"
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
