//
//  WeatherService.swift
//  NexGenSpec
//
//  Fetches current weather conditions at inspection time from the Open-Meteo API.
//  Gracefully degrades when the network or location permission is unavailable.
//
//  Weather data by Open-Meteo.com
//

import Foundation
import CoreLocation
import os

// MARK: - Weather Data Model

/// Stores weather conditions captured at inspection time.
public struct WeatherData: Codable, Equatable, Sendable {
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

    /// Bounded watchdog that guarantees the UI reaches a terminal state even
    /// when no location/permission/weather callback ever arrives — most
    /// notably the `.notDetermined` path, where the system permission prompt
    /// may never be answered and `requestWhenInUseAuthorization()` produces no
    /// further delegate callback. Cancelled the moment any terminal state is
    /// reached so it never clobbers a real result.
    private var watchdog: Task<Void, Never>?
    private let watchdogTimeout: UInt64 = 20_000_000_000  // 20s in nanoseconds

    /// Dedicated logger so the full weather fetch path is visible live in
    /// Console.app on a real device (filter subsystem = bundle id, category
    /// = "Weather"). Dynamic values are logged `.public` because this is a
    /// diagnostic aid for on-device failures we can't reproduce in the
    /// simulator — see the catch block in `fetchWeather(at:)`.
    private let log = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.nexgenspec",
        category: "Weather"
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
        // In-flight guard: if a fetch is already running, fail the new caller
        // rather than overwriting (and orphaning) the prior completion. This
        // class is @MainActor, so this check is serialized with all other
        // state mutations — no data race.
        guard !isFetching else {
            completion?(nil)
            return
        }

        self.completion = completion
        errorMessage = nil
        isFetching = true
        startWatchdog()

        let status = locationManager.authorizationStatus
        log.info("fetchCurrentWeather: location auth = \(self.authString(status), privacy: .public)")
        Diagnostics.logInfo("Weather: fetch start (auth=\(authString(status)))")

        switch status {
        case .notDetermined:
            log.info("Auth not determined — requesting When-In-Use authorization")
            locationManager.requestWhenInUseAuthorization()
        case .authorizedWhenInUse, .authorizedAlways:
            log.info("Authorized — requesting one-shot location")
            locationManager.requestLocation()
        case .denied, .restricted:
            log.error("Location permission denied/restricted — cannot fetch weather")
            Diagnostics.logError(context: "Weather: location permission denied/restricted")
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

    /// (Re)starts the bounded watchdog. Cancels any prior watchdog first so a
    /// stale timer from an earlier fetch can never reset a newer in-flight one.
    private func startWatchdog() {
        watchdog?.cancel()
        watchdog = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: self?.watchdogTimeout ?? 20_000_000_000)
            guard let self, !Task.isCancelled, self.isFetching else { return }
            // No location/permission/weather result ever arrived (e.g. the user
            // never answered the permission prompt). Drive the UI to a terminal
            // state so it stops showing "Fetching weather…".
            self.log.error("Weather watchdog fired — no result within 20s, clearing fetch state")
            Diagnostics.logError(context: "Weather: watchdog timeout (no result within 20s)")
            self.isFetching = false
            self.errorMessage = "Weather: timed out"
            self.weatherData = nil
            self.completion?(nil)
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
            log.info("Location received: ~\(location.coordinate.latitude, format: .fixed(precision: 2), privacy: .private), ~\(location.coordinate.longitude, format: .fixed(precision: 2), privacy: .private) (accuracy \(location.horizontalAccuracy, format: .fixed(precision: 0), privacy: .public)m)")
            await fetchWeather(at: location)
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        let errDesc = error.localizedDescription
        Task { @MainActor in
            log.error("Location request failed: \(errDesc, privacy: .public)")
            Diagnostics.logError(context: "Weather: location request failed", error: error)
            isFetching = false
            errorMessage = "Location error: \(errDesc)"
            completion?(nil)
            completion = nil
        }
    }

    // MARK: - Open-Meteo fetch

    // Weather data by Open-Meteo.com — free, key-less forecast API used as a
    // drop-in replacement for WeatherKit, whose JWT auth has been failing
    // server-side on Apple's end for over a month with no fix available to us.
    private func fetchWeather(at location: CLLocation) async {
        // Coarsen to ~2 decimals (~1 km) before transmission for data
        // minimization — this is what the privacy surfaces disclose
        // ("approximate coordinates ~1 km") and is well within Open-Meteo's grid
        // resolution for current conditions (B-0046). Full precision is never
        // sent off-device.
        let lat = (location.coordinate.latitude * 100).rounded() / 100
        let lon = (location.coordinate.longitude * 100).rounded() / 100

        var components = URLComponents(string: "https://api.open-meteo.com/v1/forecast")
        components?.queryItems = [
            URLQueryItem(name: "latitude", value: String(lat)),
            URLQueryItem(name: "longitude", value: String(lon)),
            URLQueryItem(name: "current", value: "temperature_2m,relative_humidity_2m,wind_speed_10m,weather_code"),
            URLQueryItem(name: "temperature_unit", value: "fahrenheit"),
            URLQueryItem(name: "wind_speed_unit", value: "mph")
        ]

        guard let url = components?.url else {
            log.error("Open-Meteo: failed to build request URL")
            Diagnostics.logError(context: "Weather: failed to build Open-Meteo URL")
            isFetching = false
            errorMessage = "Weather: invalid request"
            completion?(nil)
            completion = nil
            return
        }

        log.info("Calling Open-Meteo forecast …")
        Diagnostics.logInfo("Open-Meteo: request starting")
        do {
            // 15s per-request timeout so a flaky/captive network fails fast and
            // the "Fetching weather…" state clears, rather than hanging on the
            // 60s URLSession default.
            var request = URLRequest(url: url)
            request.timeoutInterval = 15
            let (responseData, response) = try await URLSession.shared.data(for: request)

            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                let code = (response as? HTTPURLResponse)?.statusCode ?? -1
                log.error("Open-Meteo: unexpected HTTP status \(code, privacy: .public)")
                Diagnostics.logError(context: "Weather: Open-Meteo HTTP status \(code)")
                isFetching = false
                errorMessage = "Weather: server returned \(code)"
                completion?(nil)
                completion = nil
                return
            }

            let decoded = try JSONDecoder().decode(OpenMeteoResponse.self, from: responseData)
            let current = decoded.current

            let data = WeatherData(
                temperature: current.temperature_2m,
                conditions: mapWeatherCode(current.weather_code),
                humidity: current.relative_humidity_2m,
                windSpeed: current.wind_speed_10m,
                capturedAt: Date()
            )

            log.info("Open-Meteo success: \(data.temperatureString, privacy: .public) \(data.conditions, privacy: .public)")
            Diagnostics.logInfo("Open-Meteo: success \(data.temperatureString) \(data.conditions)")
            self.weatherData = data
            isFetching = false
            watchdog?.cancel()
            completion?(data)
        } catch {
            // Surface the full error so the on-device cause — network failure,
            // decode mismatch, or a malformed response — is identifiable in
            // Console.app and the persistent diagnostics log.
            let ns = error as NSError
            // PII (B-0117): do NOT log `String(describing: error)` or pass the
            // raw error to Crashlytics here. For a URLSession failure the error's
            // userInfo carries NSErrorFailingURLStringKey = the request URL, which
            // embeds the property's latitude/longitude — i.e. the client's
            // approximate location, leaked off-device to Crashlytics and into the
            // .public os_log. domain + code + type + localizedDescription fully
            // diagnose the failure without the coordinates (localizedDescription
            // for URLError is a plain sentence, no URL).
            log.error("Open-Meteo FAILED: type=\(String(describing: type(of: error)), privacy: .public) | domain=\(ns.domain, privacy: .public) code=\(ns.code, privacy: .public) | \(error.localizedDescription, privacy: .public)")
            Diagnostics.logError(context: "Weather: Open-Meteo fetch failed [domain=\(ns.domain) code=\(ns.code) type=\(type(of: error))]", error: nil)
            isFetching = false
            errorMessage = "Weather: \(error.localizedDescription)"
            completion?(nil)
        }
        completion = nil
    }

    /// Maps an Open-Meteo WMO weather code to a human-readable condition string.
    /// Reference: https://open-meteo.com/en/docs (WMO Weather interpretation codes)
    private func mapWeatherCode(_ code: Int) -> String {
        switch code {
        case 0:
            return "Clear"
        case 1:
            return "Mainly Clear"
        case 2:
            return "Partly Cloudy"
        case 3:
            return "Overcast"
        case 45, 48:
            return "Fog"
        case 51...67:
            return "Rain"
        case 71...77:
            return "Snow"
        case 80...82:
            return "Showers"
        case 95...99:
            return "Thunderstorm"
        default:
            return "Unknown"
        }
    }
}

// MARK: - Open-Meteo Response

/// Minimal decodable shape of the Open-Meteo `/v1/forecast` `current` block.
/// Temperature and wind arrive pre-converted to Fahrenheit / mph via the
/// request's `temperature_unit` and `wind_speed_unit` parameters, and
/// `relative_humidity_2m` is already a 0–100 percentage.
private struct OpenMeteoResponse: Decodable {
    let current: Current

    struct Current: Decodable {
        let temperature_2m: Double
        let relative_humidity_2m: Double
        let wind_speed_10m: Double
        let weather_code: Int
    }
}
