// 设置 → 终端：点路径后面的终端图标时，用哪个终端软件打开
import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct TerminalSettingsView: View {
    @AppStorage(TerminalLauncher.settingKey) private var chosen = TerminalApp.defaultBundleId
    /// 这台电脑上装了的终端。每次打开设置页重新查一遍，新装 / 卸载的终端能及时反映出来
    @StateObject private var installed = LocalState<[TerminalApp]>([])
    // App 里内嵌终端的外观（见 TerminalAppearance）
    @AppStorage(TerminalAppearance.fontKey) private var fontFamily = TerminalAppearance.defaultFamily
    @AppStorage(TerminalAppearance.sizeKey) private var fontSize = TerminalAppearance.defaultSize
    @AppStorage(TerminalAppearance.cursorKey) private var cursor = TerminalAppearance.Cursor.bar
    @StateObject private var families = LocalState<[String]>([])

    /// 下拉框里的选项：装了的已知终端 + 「其他应用…」选过的那个
    private var options: [TerminalApp] {
        var list = installed.value
        if !list.contains(where: { $0.bundleId == chosen }), let custom = TerminalApp.find(chosen) {
            list.append(custom)
        }
        return list
    }

    var body: some View {
        Form {
            Section("终端软件") {
                Picker("打开方式", selection: $chosen) {
                    ForEach(options) { app in Text(app.name).tag(app.bundleId) }
                }
                .clickable()
                Button("其他应用…") { chooseOtherApp() }.clickable()
                Text("会话路径后面的终端图标，会用这里选的终端打开那个目录；虚拟机里的会话会先进虚拟机再切到目录。")
                    .font(.caption).foregroundStyle(.secondary)
                if TerminalApp.find(chosen)?.style == .generic {
                    Text("这个终端只能打开物理机上的目录；虚拟机里的会话会把进虚拟机的命令复制好，需要你在终端里粘贴执行。")
                        .font(.caption).foregroundStyle(.orange)
                }
            }
            Section("App 里的终端") {
                Picker("字体", selection: $fontFamily) {
                    Text("系统等宽字体").tag("")
                    ForEach(fontOptions, id: \.self) { Text($0).tag($0) }
                }
                .clickable()
                Stepper(value: $fontSize, in: TerminalAppearance.sizeRange, step: 1) {
                    Text("字号  \(Int(fontSize))")
                }
                .clickable()
                Picker("光标", selection: $cursor) {
                    ForEach(TerminalAppearance.Cursor.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .clickable()
                Text("成员详情、单独窗口和「会话」页里的终端用这里的设置，改了马上生效。Claude 状态栏里的图标要 Nerd Font 才显示得出来，不然是带问号的方框。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .onAppear {
            installed.value = TerminalApp.installed()
            families.value = TerminalAppearance.monospacedFamilies()
        }
    }

    /// 字体下拉框：装了的等宽字体；之前选的字体被卸载了也留在列表里，不然下拉框显示空白
    private var fontOptions: [String] {
        let list = families.value
        return fontFamily.isEmpty || list.contains(fontFamily) ? list : list + [fontFamily]
    }

    /// 名单里没有的终端：自己挑一个 app
    private func chooseOtherApp() {
        let panel = NSOpenPanel()
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.application]
        panel.prompt = "选择"
        guard panel.runModal() == .OK, let url = panel.url,
              let bundleId = Bundle(url: url)?.bundleIdentifier else { return }
        chosen = bundleId
    }
}
