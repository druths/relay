import UIKit

@MainActor
enum HapticService {
    #if !targetEnvironment(simulator)
    private static let lightGenerator = UIImpactFeedbackGenerator(style: .light)
    private static let mediumGenerator = UIImpactFeedbackGenerator(style: .medium)
    private static let notificationGenerator = UINotificationFeedbackGenerator()
    #endif

    static func impact(_ style: UIImpactFeedbackGenerator.FeedbackStyle) {
        #if !targetEnvironment(simulator)
        switch style {
        case .light:
            lightGenerator.impactOccurred()
        case .medium:
            mediumGenerator.impactOccurred()
        default:
            let generator = UIImpactFeedbackGenerator(style: style)
            generator.impactOccurred()
        }
        #endif
    }

    static func notification(_ type: UINotificationFeedbackGenerator.FeedbackType) {
        #if !targetEnvironment(simulator)
        notificationGenerator.notificationOccurred(type)
        #endif
    }
}
