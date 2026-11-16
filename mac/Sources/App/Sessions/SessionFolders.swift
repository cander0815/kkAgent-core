// 会话列表里用户自己的整理方式：给会话改名、自建文件夹。
// 数据都在 SessionBrowserModel 里（存本机 UserDefaults），这里只放界面部件。
import SwiftUI

/// 正在起名字的对象：会话改名 / 新建文件夹 / 文件夹改名
enum NameEdit {
    case session(SessionSummary)
    case newFolder(cwd: String, moving: String?) // 在项目 cwd 下新建文件夹；moving 不为空时，建好后把这个会话放进去
    case folder(SessionFolder)

    var title: String {
        switch self {
        case .session: "给会话改名"
        case .newFolder: "新建文件夹"
        case .folder: "文件夹改名"
        }
    }

    var hint: String {
        switch self {
        case .session: "名字只在 kkAgent 里显示，不改会话本身；留空就恢复原来的标题。"
        case .newFolder, .folder: "文件夹建在这个项目下面，只用来整理会话，不动会话本身。"
        }
    }

    /// 按确定后真正去改
    @MainActor
    func apply(_ name: String, browser: SessionBrowserModel) {
        switch self {
        case .session(let session):
            browser.rename(session.id, to: name)
        case .newFolder(let cwd, let moving):
            if let folderId = browser.createFolder(name, in: cwd), let moving {
                browser.move(moving, toFolder: folderId)
            }
        case .folder(let folder):
            browser.renameFolder(folder.id, to: name)
        }
    }
}

/// 会话的右键菜单：改名、移到文件夹
struct SessionMenu: View {
    @ObservedObject var browser: SessionBrowserModel
    let session: SessionSummary
    /// 打开起名弹窗：要改的对象 + 输入框里预先填好的文字
    let edit: (NameEdit, String) -> Void

    var body: some View {
        Button("改名…") { edit(.session(session), browser.displayTitle(session)) }
        if browser.customNames[session.id] != nil {
            Button("恢复原来的名字") { browser.rename(session.id, to: "") }
        }
        Divider()
        // 只列出这个会话所在项目下的文件夹
        let folders = browser.folders(in: session.cwd)
        Menu("移到文件夹") {
            ForEach(folders) { folder in
                Button(folder.name) { browser.move(session.id, toFolder: folder.id) }
                    .disabled(browser.folderOf[session.id] == folder.id)
            }
            if !folders.isEmpty { Divider() }
            Button("新建文件夹…") { edit(.newFolder(cwd: session.cwd, moving: session.id), "") }
        }
        if browser.folderOf[session.id] != nil {
            Button("移出文件夹") { browser.move(session.id, toFolder: nil) }
        }
    }
}

/// 自建文件夹的标题行（在项目下面）：箭头 + 图标 + 名字 + 会话数，点一下展开 / 收起，右键改名或删除。
/// 图标用托盘，和项目分组的文件夹图标区分开
struct FolderHeader: View {
    let folder: SessionFolder
    let count: Int
    let expanded: Bool
    let color: Color
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 7) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(expanded ? 90 : 0))
                    .frame(width: 10)
                Image(systemName: expanded ? "tray.full.fill" : "tray.full")
                    .font(.system(size: 12))
                    .foregroundStyle(color.opacity(0.85))
                Text(folder.name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                Spacer(minLength: 4)
                Text("\(count)")
                    .font(.caption2.weight(.semibold)).monospacedDigit()
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .background(Capsule().fill(Color.secondary.opacity(0.12)))
            }
            .padding(.leading, 23) // 缩进到项目名下面，看得出是这个项目里的文件夹
            .padding(.trailing, 6)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .clickable()
        .help("自建文件夹，右键可以改名或删除")
        .animation(.easeOut(duration: 0.15), value: expanded)
    }
}
