import Foundation

public struct DetectedLink: Equatable {
    /// UTF-16 range in the row text, trailing punctuation excluded.
    public var start: Int
    public var length: Int
    public var url: URL

    public func contains(_ offset: Int) -> Bool {
        offset >= start && offset < start + length
    }
}

public enum LinkDetector {
    private static let expression = try! NSRegularExpression(
        pattern: #"\b(?:https?://|www\.)[^\s<>{}\[\]"']+"#,
        options: [.caseInsensitive])

    public static func links(in text: String) -> [DetectedLink] {
        guard text.contains("http") || text.contains("www.") || text.contains("HTTP") || text.contains("WWW.") else {
            return []
        }
        let nsText = text as NSString
        return expression.matches(in: text, range: NSRange(location: 0, length: nsText.length)).compactMap { match in
            var address = nsText.substring(with: match.range)
            while let last = address.last, ".,;:!?)".contains(last) { address.removeLast() }
            let length = (address as NSString).length
            if address.lowercased().hasPrefix("www.") { address = "https://" + address }
            guard let url = URL(string: address) else { return nil }
            return DetectedLink(start: match.range.location, length: length, url: url)
        }
    }
}
