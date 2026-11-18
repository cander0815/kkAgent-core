// 设置 → 通知：通知横幅（BannerPresenter）停留多久、是不是要点了才消失
import SwiftUI

struct NotificationSettingsView: View {
    @AppStorage(BannerPresenter.durationKey) private var duration = BannerPresenter.defaultDuration
    @AppStorage(BannerPresenter.stickyKey) private var sticky = false

    var body: some View {
        Form {
            Section("通知横幅") {
                Toggle("点了才消失", isOn: $sticky)
                    .clickable()
                Stepper(value: $duration, in: BannerPresenter.durationRange, step: 1) {
                    Text("停留 \(Int(duration)) 秒后自动消失")
                }
                .disabled(sticky)
                .clickable()
                Text("成员等授权、单独会话这一轮结束或出错时，会在你正在用的那块屏幕右上角弹出横幅。鼠标停在横幅上时不会消失；打开「点了才消失」后，横幅会一直留着，点它跳过去或点左上角 × 关掉。")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Button("弹一条试试") {
                    BannerPresenter.shared.show(title: "这是一条测试通知",
                                                body: "看看样式、停留时间和弹出的屏幕对不对") {}
                }
                .clickable()
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
    }
}
