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
    static var legacyURLs: [String] { configuration["LegacyURLs"] as? [String] ?? [] }
}
