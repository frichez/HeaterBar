import Foundation

/// The outdoor temperature, from Open-Meteo (free, no account or key): the
/// heaters only know their room.
struct OutdoorWeather: Equatable {
    static let place = "Manage"
    private static let latitude = 50.503
    private static let longitude = 4.236

    var temperature: Double
    var symbol: String

    static func fetch() async -> OutdoorWeather? {
        var components = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        components.queryItems = [
            URLQueryItem(name: "latitude", value: String(latitude)),
            URLQueryItem(name: "longitude", value: String(longitude)),
            URLQueryItem(name: "current", value: "temperature_2m,weather_code,is_day"),
        ]
        guard let url = components.url,
              let (data, _) = try? await URLSession.shared.data(from: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let current = object["current"] as? [String: Any],
              let temperature = (current["temperature_2m"] as? NSNumber)?.doubleValue else { return nil }
        let code = (current["weather_code"] as? NSNumber)?.intValue ?? 0
        let isDay = (current["is_day"] as? NSNumber)?.intValue != 0
        return OutdoorWeather(temperature: temperature, symbol: symbol(forCode: code, isDay: isDay))
    }

    /// WMO weather codes, grouped into the SF Symbols that fit them.
    private static func symbol(forCode code: Int, isDay: Bool) -> String {
        switch code {
        case 0, 1: return isDay ? "sun.max" : "moon.stars"
        case 2: return isDay ? "cloud.sun" : "cloud.moon"
        case 3: return "cloud"
        case 45, 48: return "cloud.fog"
        case 51...57: return "cloud.drizzle"
        case 61...67, 80...82: return "cloud.rain"
        case 71...77, 85, 86: return "cloud.snow"
        case 95...99: return "cloud.bolt.rain"
        default: return "thermometer.medium"
        }
    }
}
