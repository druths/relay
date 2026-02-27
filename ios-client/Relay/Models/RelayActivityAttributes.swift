import ActivityKit
import Foundation

struct RelayActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var isMuted: Bool
        var agentName: String
        var status: String
    }
}
