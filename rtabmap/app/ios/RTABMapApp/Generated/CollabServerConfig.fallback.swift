// Checked-in fallback used when LAN IP detection is unavailable.
// The Xcode build script overwrites CollabServerConfig.swift with this Mac's IP.
enum CollabServerConfig {
    static let defaultURL = "http://192.168.1.159:8080"
}
