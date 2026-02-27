import Foundation

extension Data {
    /// Decode from a base64-encoded string. Returns nil if invalid.
    init?(base64: String) {
        self.init(base64Encoded: base64)
    }

    /// Encode to a base64 string (no line breaks).
    var base64: String {
        base64EncodedString()
    }
}
