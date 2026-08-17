import Foundation

enum StatusURLValidator {
    static func validate(_ text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let url = URL(string: trimmed),
              url.path.hasSuffix("/status") else {
            return nil
        }
        switch url.scheme?.lowercased() {
        case "https":
            guard let host = url.host, !host.isEmpty else { return nil }
            return url
        case "http":
            guard let host = url.host, isLANIP(host) else { return nil }
            return url
        default:
            return nil
        }
    }

    private static func isLANIP(_ host: String) -> Bool {
        if host.lowercased() == "localhost" { return true }
        let parts = host.split(separator: ".")
        guard parts.count == 4 else { return false }
        let numbers = parts.compactMap { Int($0) }
        guard numbers.count == 4 else { return false }
        if numbers[0] == 10 { return true }
        if numbers[0] == 172, (16...31).contains(numbers[1]) { return true }
        if numbers[0] == 192, numbers[1] == 168 { return true }
        return false
    }
}
