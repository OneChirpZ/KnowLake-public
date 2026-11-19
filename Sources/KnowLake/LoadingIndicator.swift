import SwiftUI

struct LoadingIndicator: View {
  @Environment(\.colorScheme) private var colorScheme
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.isEnabled) private var isEnabled
  @State private var isVisible = false

  var body: some View {
    TimelineView(.animation(paused: reduceMotion || !isVisible || !isEnabled)) { context in
      let rotation = reduceMotion ? 0
        : context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 0.9) / 0.9 * 360
      ZStack {
        Circle().strokeBorder(
          colorScheme == .dark ? Color.white.opacity(0.16) : Color.black.opacity(0.11),
          lineWidth: 1.5)
        Circle().inset(by: 0.75).trim(from: 0.04, to: 0.76)
          .stroke(
            colorScheme == .dark ? Color.white.opacity(0.86) : Color.black.opacity(0.62),
            style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
          .rotationEffect(.degrees(rotation - 90))
      }
    }
    .frame(width: 12, height: 12)
    .onAppear { isVisible = true }
    .onDisappear { isVisible = false }
  }
}
