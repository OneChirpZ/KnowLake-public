import SwiftUI

struct SidebarNavigationBar: View {
  @ObservedObject var queue: QueueState
  @Binding var selection: String

  var body: some View {
    PillSwitch(
      choices: [
        .init(id: "all", title: "资料库", icon: "square.stack.3d.up"),
        .init(id: "unread", title: "未读", icon: "circle"),
        .init(id: "starred", title: "收藏", icon: "star"),
        .init(
          id: "tasks", title: "任务", icon: "list.bullet.rectangle", badge: queue.running,
          help: queue.running > 0 ? "\(queue.running) 个任务正在执行或排队" : "任务"),
      ], selection: $selection, iconsOnly: true)
  }
}
