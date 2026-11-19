import AppKit
import SwiftUI

struct NativeMenuPicker<Selection: Equatable>: NSViewRepresentable {
  struct Option: Equatable {
    let id: Selection
    let title: String
  }

  let options: [Option]
  @Binding var selection: Selection
  let accessibilityLabel: String
  var accessibilityIdentifier: String? = nil
  @Environment(\.isEnabled) private var isEnabled

  func makeCoordinator() -> Coordinator { Coordinator(selection: $selection) }

  func makeNSView(context: Context) -> NSPopUpButton {
    let button = NSPopUpButton(frame: .zero, pullsDown: false)
    button.controlSize = .regular
    button.font = .systemFont(ofSize: NSFont.systemFontSize(for: .regular))
    button.bezelStyle = .rounded
    button.isBordered = true
    button.autoenablesItems = false
    (button.cell as? NSPopUpButtonCell)?.arrowPosition = .arrowAtCenter
    button.target = context.coordinator
    button.action = #selector(Coordinator.choose(_:))
    button.setContentHuggingPriority(.defaultLow, for: .horizontal)
    button.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    return button
  }

  func updateNSView(_ button: NSPopUpButton, context: Context) {
    context.coordinator.selection = $selection
    if context.coordinator.options != options {
      let menu = NSMenu()
      menu.autoenablesItems = false
      for option in options {
        menu.addItem(withTitle: option.title, action: nil, keyEquivalent: "")
      }
      button.menu = menu
      context.coordinator.options = options
      button.invalidateIntrinsicContentSize()
    }
    if let index = options.firstIndex(where: { $0.id == selection }) {
      if button.indexOfSelectedItem != index { button.selectItem(at: index) }
    } else {
      button.select(nil)
    }
    button.isEnabled = isEnabled && !options.isEmpty
    button.setAccessibilityLabel(accessibilityLabel)
    button.setAccessibilityIdentifier(accessibilityIdentifier)
  }

  func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSPopUpButton, context: Context) -> CGSize? {
    CGSize(width: proposal.width ?? nsView.intrinsicContentSize.width,
      height: nsView.intrinsicContentSize.height)
  }

  final class Coordinator: NSObject {
    var selection: Binding<Selection>
    var options: [Option] = []

    init(selection: Binding<Selection>) { self.selection = selection }

    @objc func choose(_ sender: NSPopUpButton) {
      let index = sender.indexOfSelectedItem
      guard options.indices.contains(index) else { return }
      selection.wrappedValue = options[index].id
    }
  }
}

struct NativeReasoningSlider: NSViewRepresentable {
  @Binding var index: Int
  let count: Int
  let accessibilityLabel: String
  let accessibilityValue: String
  var accessibilityIdentifier: String? = nil
  @Environment(\.isEnabled) private var isEnabled

  func makeCoordinator() -> Coordinator { Coordinator(index: $index, count: count) }

  func makeNSView(context: Context) -> NSSlider {
    let slider = NSSlider(value: 0, minValue: 0, maxValue: 1,
      target: context.coordinator, action: #selector(Coordinator.change(_:)))
    slider.sliderType = .linear
    slider.isVertical = false
    slider.controlSize = .regular
    slider.isContinuous = true
    slider.tickMarkPosition = .below
    slider.allowsTickMarkValuesOnly = true
    slider.setContentHuggingPriority(.defaultLow, for: .horizontal)
    slider.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    return slider
  }

  func updateNSView(_ slider: NSSlider, context: Context) {
    context.coordinator.index = $index
    context.coordinator.count = count
    let ticks = max(count, 0)
    let maximum = Double(max(count - 1, 1))
    if slider.numberOfTickMarks != ticks || slider.maxValue != maximum {
      slider.minValue = 0
      slider.maxValue = maximum
      slider.numberOfTickMarks = ticks
      slider.invalidateIntrinsicContentSize()
      slider.needsDisplay = true
    }
    slider.doubleValue = Double(min(max(index, 0), max(count - 1, 0)))
    slider.isEnabled = isEnabled && count > 1
    slider.setAccessibilityLabel(accessibilityLabel)
    slider.setAccessibilityValueDescription(accessibilityValue)
    slider.setAccessibilityIdentifier(accessibilityIdentifier)
  }

  func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSSlider, context: Context) -> CGSize? {
    CGSize(width: proposal.width ?? 140, height: nsView.intrinsicContentSize.height)
  }

  final class Coordinator: NSObject {
    var index: Binding<Int>
    var count: Int

    init(index: Binding<Int>, count: Int) {
      self.index = index
      self.count = count
    }

    @objc func change(_ sender: NSSlider) {
      index.wrappedValue = min(max(Int(sender.doubleValue.rounded()), 0), max(count - 1, 0))
    }
  }
}
