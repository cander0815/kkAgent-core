// 视觉规范：颜色和 Agent 头像。所有功能模块共用，保证整个 app 看起来是一个东西。
//
// 颜色只有一个用途：分清「谁」。Claude 紫罗兰、Codex 青绿、「我」用系统强调色；
// 状态（空闲 / 忙 / 出错）只用系统的绿、橙、红，不再引入别的颜色。
import SwiftUI

enum Theme {
    static let claude = Color(red: 0x6E / 255, green: 0x56 / 255, blue: 0xCF / 255) // #6E56CF
    static let codex = Color(red: 0x0F / 255, green: 0x76 / 255, blue: 0x6E / 255)  // #0F766E
    static let you = Color.accentColor

    static func color(_ agent: AgentKind) -> Color {
        agent == .claude ? claude : codex
    }

    /// 名字用圆体，带一点「人」的感觉；正文仍是系统字体
    static func nameFont(_ size: CGFloat = 13) -> Font {
        .system(size: size, weight: .semibold, design: .rounded)
    }

    /// 只有真正是代码的内容（工具调用、会话 ID）才用等宽字体
    static let code = Font.system(.caption, design: .monospaced)
}

/// Agent 头像：名字首字母 + 所属 Agent 的颜色，可选右下角状态点
struct AgentAvatar: View {
    let name: String
    let color: Color
    var size: CGFloat = 28
    var status: Color? = nil

    var body: some View {
        Text(String(name.prefix(1)).uppercased())
            .font(.system(size: size * 0.46, weight: .bold, design: .rounded))
            .foregroundStyle(color)
            .frame(width: size, height: size)
            .background(Circle().fill(color.opacity(0.14)))
            .overlay(Circle().stroke(color.opacity(0.35), lineWidth: 1))
            .overlay(alignment: .bottomTrailing) {
                if let status {
                    Circle().fill(status)
                        .frame(width: size * 0.32, height: size * 0.32)
                        .overlay(Circle().stroke(Color(nsColor: .windowBackgroundColor), lineWidth: 1.5))
                }
            }
    }
}

extension AgentAvatar {
    /// 群成员的头像
    init(member: MemberDetail, size: CGFloat = 28, showStatus: Bool = true) {
        self.init(name: member.member.alias, color: Theme.color(member.member.agent), size: size,
                  status: showStatus ? member.statusColor : nil)
    }
}
