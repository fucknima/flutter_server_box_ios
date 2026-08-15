import SwiftUI
import UIKit

enum DesignTokens {
    static let accent = Color(red: 0.84, green: 0.29, blue: 0.17)
    static let background = Color(uiColor: .systemGroupedBackground)
    static let surface = Color(uiColor: .secondarySystemGroupedBackground)
    static let spaceS: CGFloat = 8
    static let spaceM: CGFloat = 16
    static let spaceL: CGFloat = 24
    static let radiusM: CGFloat = 16

    static func statusColor(for fraction: Double?) -> Color {
        guard let fraction else { return .secondary }
        switch fraction {
        case ..<0.7: return .green
        case ..<0.9: return .orange
        default: return .red
        }
    }
}
