import SwiftUI

/// The floating card look used by the timeline's bottom-right prompt.
struct PromptCardStyle: ViewModifier {
  @Environment(\.dayflowTheme) private var theme
  let width: CGFloat

  func body(content: Content) -> some View {
    content
      .padding(20)
      .frame(width: width)
      .background(
        RoundedRectangle(cornerRadius: 8, style: .continuous)
          .fill(.ultraThinMaterial)
      )
      .background(
        RoundedRectangle(cornerRadius: 8, style: .continuous)
          .fill(theme.isDark ? Color(hex: "272F43") : Color(hex: "FFFBF9").opacity(0.9))
      )
      .overlay(
        RoundedRectangle(cornerRadius: 8, style: .continuous)
          .strokeBorder(theme.isDark ? Color(hex: "5B5B5B") : Color(hex: "E3DAD1"), lineWidth: 1)
      )
      .shadow(
        color: theme.isDark ? Color(hex: "463B54") : Color(hex: "E5DDD5"),
        radius: theme.isDark ? 16 : 12, x: 0, y: 4
      )
  }
}

extension View {
  func promptCardStyle(width: CGFloat) -> some View {
    modifier(PromptCardStyle(width: width))
  }
}
