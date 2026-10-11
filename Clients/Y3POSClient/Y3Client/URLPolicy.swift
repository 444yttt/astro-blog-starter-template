import Foundation

enum URLPolicy {
    static let home = URL(string: "https://adidas-y3.poscmcloud.jp:15505/scripts/verona/menu/metz010_1.asp")!
    static let host = "adidas-y3.poscmcloud.jp"
    static let origin = "https://adidas-y3.poscmcloud.jp:15505"

    static func isTrusted(_ url: URL) -> Bool {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return false }
        return parts.scheme?.lowercased() == "https"
            && parts.host?.lowercased() == host
            && parts.port == 15505
            && parts.user == nil && parts.password == nil
    }

    static func allowsNavigation(_ url: URL) -> Bool {
        if url.absoluteString == "about:blank" { return true }
        if url.scheme?.lowercased() == "blob",
           let source = URL(string: String(url.absoluteString.dropFirst(5))) {
            return isTrusted(source)
        }
        return isTrusted(url)
    }

    static func externalWebURL(_ url: URL) -> Bool {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return false }
        return ["https", "http"].contains(parts.scheme?.lowercased() ?? "")
            && parts.host != nil && parts.user == nil && parts.password == nil
    }

    static func loginURL(from text: String) -> URL? {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.count <= 2048, let url = URL(string: value), isTrusted(url) else { return nil }
        return url
    }
}
