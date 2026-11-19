import AppKit
import SwiftUI

@MainActor final class ReaderControlsVisibility: ObservableObject {
  @Published private(set) var visible = false
  private var hovering = false
  private var dragging = false
  private var menuTracking = false
  private var presenting = false
  private var hideTask: Task<Void, Never>?
  private let delay: Duration

  init(delay: Duration = .milliseconds(650)) { self.delay = delay }
  func reveal() {
    guard !dragging else { return }
    visible = true
    stopHiding()
    scheduleHide()
  }
  func pointer(inside: Bool) {
    hovering = inside
    if inside { reveal() } else { scheduleHide() }
  }
  func dragBegan() {
    dragging = true
    hovering = false
    stopHiding()
    visible = false
  }
  func dragEnded(overBall: Bool) {
    dragging = false
    hovering = overBall
    reveal()
  }
  func menuBegan() {
    guard visible else { return }
    menuTracking = true
    stopHiding()
  }
  func menuEnded() {
    menuTracking = false
    scheduleHide()
  }
  func presentationChanged(_ value: Bool) {
    presenting = value
    if value { reveal() } else { scheduleHide() }
  }
  func reset() {
    stopHiding()
    hovering = false
    dragging = false
    menuTracking = false
    presenting = false
    visible = false
  }
  private func stopHiding() {
    hideTask?.cancel()
    hideTask = nil
  }
  private func scheduleHide() {
    guard visible, !hovering, !dragging, !menuTracking, !presenting, hideTask == nil else { return }
    let delay = delay
    hideTask = Task { [weak self] in
      do { try await Task.sleep(for: delay) } catch { return }
      guard let self else { return }
      self.visible = false
      self.hideTask = nil
    }
  }
}

struct ReaderControlsPosition {
  static let diameter: CGFloat = 40
  static let margin: CGFloat = 12
  static let hoverMargin: CGFloat = 12

  static func center(for position: UnitPoint, in size: CGSize) -> CGPoint {
    let insetX = min(margin + diameter / 2, size.width / 2)
    let insetY = min(margin + diameter / 2, size.height / 2)
    return CGPoint(
      x: insetX + max(0, size.width - 2 * insetX) * min(max(position.x, 0), 1),
      y: insetY + max(0, size.height - 2 * insetY) * min(max(position.y, 0), 1))
  }
  static func position(for center: CGPoint, in size: CGSize) -> UnitPoint {
    let inset = margin + diameter / 2
    return UnitPoint(
      x: size.width > 2 * inset ? min(max((center.x - inset) / (size.width - 2 * inset), 0), 1) : 0,
      y: size.height > 2 * inset ? min(max((center.y - inset) / (size.height - 2 * inset), 0), 1) : 0)
  }
  static func surfaceFrame(center: CGPoint, expandedWidth: CGFloat, progress: CGFloat, in size: CGSize) -> CGRect {
    let stretch = max(0, progress)
    let width = min(diameter + (expandedWidth - diameter) * stretch, size.width - 2 * margin)
    let expandedX = min(center.x - diameter / 2, max(margin, size.width - margin - expandedWidth))
    let originX = center.x - diameter / 2
    let x = originX + (expandedX - originX) * stretch
    let height = diameter + 8 * LiquidReaderShape.tension(at: progress)
    return CGRect(
      x: min(max(margin, x), max(margin, size.width - margin - width)),
      y: center.y - height / 2, width: width, height: height)
  }
}

private struct ReaderControlsHoverRegion: NSViewRepresentable {
  let controls: ReaderControlsVisibility

  func makeNSView(context: Context) -> ReaderControlsHoverView {
    ReaderControlsHoverView()
  }
  func updateNSView(_ view: ReaderControlsHoverView, context: Context) {
    view.onHover = controls.pointer
  }
}

private final class ReaderControlsHoverView: NSView {
  var onHover: ((Bool) -> Void)?
  private var hoverArea: NSTrackingArea?

  override func hitTest(_ point: NSPoint) -> NSView? { nil }

  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    if let hoverArea { removeTrackingArea(hoverArea) }
    let area = NSTrackingArea(
      rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
      owner: self, userInfo: nil)
    addTrackingArea(area)
    hoverArea = area
  }
  override func mouseEntered(with event: NSEvent) { onHover?(true) }
  override func mouseExited(with event: NSEvent) { onHover?(false) }
}

/// The stationary drop and the moving rounded tip pull a waist between them.
/// At either endpoint the same path becomes a circle or a straight capsule.
struct LiquidReaderShape: Shape {
  var progress: CGFloat
  var expandsLeft = false

  static func tension(at progress: CGFloat) -> CGFloat {
    let phase = min(max(progress, 0), 1)
    return sin(.pi * phase) * sqrt(1 - phase)
  }
  func path(in rect: CGRect) -> Path {
    let tension = Self.tension(at: progress)
    let rootRadius = ReaderControlsPosition.diameter / 2
    let tipRadius = rootRadius + 4 * tension
    let span = rect.width - rootRadius - tipRadius
    guard span > 1 else { return Path(ellipseIn: rect) }
    let left = rect.minX + rootRadius
    let right = rect.maxX - tipRadius
    let waist = left + span * 0.36
    let waistRadius = rootRadius - 13 * tension
    let midY = rect.midY
    var path = Path()
    path.move(to: CGPoint(x: left, y: midY - rootRadius))
    path.addCurve(to: CGPoint(x: waist, y: midY - waistRadius),
      control1: CGPoint(x: left + span * 0.16, y: midY - rootRadius),
      control2: CGPoint(x: waist - span * 0.14, y: midY - waistRadius))
    path.addCurve(to: CGPoint(x: right, y: midY - tipRadius),
      control1: CGPoint(x: waist + span * 0.24, y: midY - waistRadius),
      control2: CGPoint(x: right - span * 0.24, y: midY - tipRadius))
    path.addArc(center: CGPoint(x: right, y: midY), radius: tipRadius,
      startAngle: .degrees(-90), endAngle: .degrees(90), clockwise: false)
    path.addCurve(to: CGPoint(x: waist, y: midY + waistRadius),
      control1: CGPoint(x: right - span * 0.24, y: midY + tipRadius),
      control2: CGPoint(x: waist + span * 0.24, y: midY + waistRadius))
    path.addCurve(to: CGPoint(x: left, y: midY + rootRadius),
      control1: CGPoint(x: waist - span * 0.14, y: midY + waistRadius),
      control2: CGPoint(x: left + span * 0.16, y: midY + rootRadius))
    path.addArc(center: CGPoint(x: left, y: midY), radius: rootRadius,
      startAngle: .degrees(90), endAngle: .degrees(270), clockwise: false)
    path.closeSubpath()
    return expandsLeft
      ? path.applying(CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: rect.minX + rect.maxX, ty: 0)) : path
  }
}

private struct LiquidReaderMorph: AnimatableModifier {
  var progress: CGFloat
  let expandedWidth: CGFloat
  let readerSize: CGSize
  let controls: ReaderControlsVisibility
  @Binding var position: UnitPoint
  @Binding var dragOrigin: CGPoint?
  var animatableData: CGFloat {
    get { progress }
    set { progress = newValue }
  }

  func body(content: Content) -> some View {
    let center = ReaderControlsPosition.center(for: position, in: readerSize)
    let expanded = ReaderControlsPosition.surfaceFrame(center: center, expandedWidth: expandedWidth, progress: 1, in: readerSize)
    let frame = ReaderControlsPosition.surfaceFrame(center: center, expandedWidth: expandedWidth, progress: progress, in: readerSize)
    let anchor = (center.x - ReaderControlsPosition.diameter / 2 - expanded.minX)
      / max(1, expandedWidth - ReaderControlsPosition.diameter)
    let shape = LiquidReaderShape(progress: progress, expandsLeft: anchor > 0.5)
    let phase = min(max(progress, 0), 1)
    let reveal = min(max((phase - 0.16) / 0.7, 0), 1)
    ZStack(alignment: .leading) {
      content
        .offset(x: -anchor * (expandedWidth - frame.width))
        .opacity(reveal * reveal * (3 - 2 * reveal))
        .disabled(!controls.visible)
        .allowsHitTesting(controls.visible)
        .accessibilityHidden(!controls.visible)
      Button { controls.reveal() } label: {
        Image(systemName: "arrow.left.arrow.right")
          .font(.system(size: 16, weight: .medium)).foregroundStyle(.primary)
          .frame(width: ReaderControlsPosition.diameter, height: ReaderControlsPosition.diameter)
          .contentShape(Circle())
      }.buttonStyle(.plain)
        .accessibilityLabel("切换视图")
        .help("拖动调整位置，悬停切换视图")
        .offset(x: center.x - frame.minX - ReaderControlsPosition.diameter / 2)
        .opacity(max(0, 1 - phase / 0.2))
        .disabled(controls.visible)
        .allowsHitTesting(!controls.visible)
        .accessibilityHidden(controls.visible)
    }
    .frame(width: frame.width, height: frame.height, alignment: .leading)
    .background(.quaternary.opacity(0.45), in: shape)
    .background(.regularMaterial, in: shape)
    .clipShape(shape)
    .overlay { shape.stroke(.primary.opacity(0.12), lineWidth: 0.5) }
    .opacity(dragOrigin == nil ? 0.65 + 0.35 * phase : 1)
    .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
    .contentShape(shape)
    .highPriorityGesture(
      DragGesture(minimumDistance: 4, coordinateSpace: .named("reader-controls"))
        .onChanged { value in
          if dragOrigin == nil {
            dragOrigin = controls.visible ? value.startLocation : center
            controls.dragBegan()
          }
          guard let origin = dragOrigin else { return }
          position = ReaderControlsPosition.position(
            for: CGPoint(x: origin.x + value.translation.width, y: origin.y + value.translation.height),
            in: readerSize)
        }
        .onEnded { value in
          dragOrigin = nil
          let center = ReaderControlsPosition.center(for: position, in: readerSize)
          controls.dragEnded(overBall: hypot(value.location.x - center.x, value.location.y - center.y)
            <= ReaderControlsPosition.diameter / 2)
        })
    .background {
      ReaderControlsHoverRegion(controls: controls)
        .frame(width: frame.width + ReaderControlsPosition.hoverMargin * 2,
          height: frame.height + ReaderControlsPosition.hoverMargin * 2)
        .accessibilityHidden(true)
    }
    .position(x: frame.midX, y: frame.midY)
  }
}

struct FloatingReaderControls: View {
  @ObservedObject var model: AppModel
  let detail: SourceDetail
  @ObservedObject var controls: ReaderControlsVisibility
  @State private var position = UnitPoint.topLeading
  @State private var dragOrigin: CGPoint?
  @State private var expandedWidth = ReaderControlsPosition.diameter
  @State private var expansion: CGFloat = 0
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    GeometryReader { geometry in
      ArtifactSwitcher(model: model, detail: detail, showsSurface: false,
        onPresentationChanged: controls.presentationChanged)
        .fixedSize()
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { expandedWidth = $0 }
        .modifier(LiquidReaderMorph(progress: expansion, expandedWidth: expandedWidth, readerSize: geometry.size,
          controls: controls, position: $position, dragOrigin: $dragOrigin))
        .onChange(of: controls.visible) {
          withAnimation(reduceMotion || dragOrigin != nil ? nil : .spring(response: 0.58, dampingFraction: 0.64)) {
            expansion = controls.visible ? 1 : 0
          }
        }
        .onAppear { expansion = controls.visible ? 1 : 0 }
    }
    .coordinateSpace(name: "reader-controls")
  }
}

struct FloatingReaderArea<Content: View>: View {
  @ObservedObject var model: AppModel
  let detail: SourceDetail
  @ViewBuilder let content: () -> Content
  @StateObject private var controls = ReaderControlsVisibility()

  var body: some View {
    content()
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .overlay {
        FloatingReaderControls(model: model, detail: detail, controls: controls)
      }
      .onDisappear { controls.reset() }
      .onChange(of: detail.source.id) { controls.reset() }
      .onReceive(NotificationCenter.default.publisher(for: NSMenu.didBeginTrackingNotification)) {
        _ in controls.menuBegan()
      }
      .onReceive(NotificationCenter.default.publisher(for: NSMenu.didEndTrackingNotification)) {
        _ in controls.menuEnded()
      }
  }
}
