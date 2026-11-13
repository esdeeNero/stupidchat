import Foundation

/// Safe defaults are committed. Per-installation credentials stay in an ignored local plist.
enum Deployment {
    private static let configuration: [String: Any] = {
        guard let url=Bundle.main.url(forResource:"Connection.local",withExtension:"plist"),
              let data=try? Data(contentsOf:url),
              let value=try? PropertyListSerialization.propertyList(from:data,format:nil) as? [String:Any] else { return [:] }
        return value
    }()
    static var serverURL: String { configuration["ServerURL"] as? String ?? "http://localhost:8787" }
    static var accessKey: String { configuration["AccessKey"] as? String ?? "" }
    static var discoveryURL: URL? {
        guard let value=configuration["DiscoveryURL"] as? String,let url=URL(string:value),url.scheme == "https" else {return nil}
        return url
    }
    static var discoveryFallbackURL: URL? {
        guard let value=configuration["DiscoveryFallbackURL"] as? String,let url=URL(string:value),url.scheme == "https" else {return nil}
        return url
    }
    static var discoveryPublicKey: Data? {
        guard let value=configuration["DiscoveryPublicKey"] as? String else {return nil}
        return Data(base64Encoded:value)
    }
    static var legacyURLs: [String] { configuration["LegacyURLs"] as? [String] ?? [] }
}
