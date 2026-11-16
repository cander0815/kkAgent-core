// App 里内嵌终端（成员详情、单独窗口、「会话」页）的外观：字体、字号、光标形状。
// 在「设置 → 终端」里改，存在 UserDefaults；改了以后已经开着的终端马上跟着变。
import AppKit
import SwiftTerm

enum TerminalAppearance {
    static let fontKey = "terminalFontFamily"
    static let sizeKey = "terminalFontSize"
    static let cursorKey = "terminalCursor"

    static let defaultSize = 12.0
    static let sizeRange = 9.0...24.0

    /// 默认字体：装了 Nerd Font 就优先用它（Claude 状态栏里的图标只有这类字体里有，系统等宽字体会显示成带问号的方框），
    /// 没装就用系统等宽字体（空字符串表示系统等宽字体）
    static let defaultFamily: String = {
        monospacedFamilies().first { $0.localizedCaseInsensitiveContains("Nerd Font") } ?? ""
    }()

    /// 这台电脑上装了的等宽字体（按名字排序）
    static func monospacedFamilies() -> [String] {
        NSFontManager.shared.availableFontFamilies.filter { family in
            NSFontManager.shared.font(withFamily: family, traits: [], weight: 5, size: 12)?.isFixedPitch ?? false
        }.sorted()
    }

    /// 按设置拿字体。字体被卸载了就退回系统等宽字体
    static func font(family: String, size: Double) -> NSFont {
        let size = min(max(size, sizeRange.lowerBound), sizeRange.upperBound)
        if !family.isEmpty, let font = NSFontManager.shared.font(withFamily: family, traits: [], weight: 5, size: size) {
            return font
        }
        return NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
    }

    /// 光标形状：设置里存的是字符串，下面三种
    enum Cursor: String, CaseIterable, Identifiable {
        case bar, block, underline
        var id: String { rawValue }
        var label: String {
            switch self {
            case .bar: "竖线"
            case .block: "方块"
            case .underline: "下划线"
            }
        }
        var style: CursorStyle {
            switch self {
            case .bar: .blinkBar
            case .block: .blinkBlock
            case .underline: .blinkUnderline
            }
        }
    }
}

/// 光标形状固定用设置里选的：tmux 和终端里的程序会发控制码改光标（tmux 接入时会把它改回方块），这里一律换成设置的形状
final class KKTerminalView: LocalProcessTerminalView {
    var cursor = TerminalAppearance.Cursor.bar {
        didSet { cursorStyleChanged(source: getTerminal(), newStyle: cursor.style) }
    }

    override func cursorStyleChanged(source: Terminal, newStyle: CursorStyle) {
        super.cursorStyleChanged(source: source, newStyle: cursor.style)
    }
}
