// 单独会话的「看过没有」和「用户现在是不是正看着它」（方案见 kktodo/会话提醒-方案.md）。
//
// - 核心只记最近一轮怎么结束的、什么时候结束的（SoloSession.lastOutcome / lastEndedAt）；
// - 看过的是哪一轮，记在本机 UserDefaults（soloViewed.<id> = 看过的那一轮的结束时间）。不一样就是有没看过的结果；
// - 只有正常结束和出错的算「有结果」，被打断的是用户自己按的，不算。
import AppKit
import SwiftUI

enum SoloReadState {
    private static func key(_ id: Int64) -> String { "soloViewed.\(id)" }

    /// 这一轮有没有结果可看（正常结束 / 出错）。被打断的不算
    static func hasResult(_ s: SoloSession) -> Bool {
        !s.lastEndedAt.isEmpty && (s.lastOutcome == "completed" || s.lastOutcome == "failed")
    }

    /// 有结果、还没看过
    static func isUnread(_ s: SoloSession) -> Bool {
        hasResult(s) && UserDefaults.standard.string(forKey: key(s.id)) != s.lastEndedAt
    }

    /// 记下看过了。只记传进来的这份数据里的那一轮：之后才结束的新一轮仍然算没看过
    static func markViewed(_ s: SoloSession) {
        guard hasResult(s) else { return }
        UserDefaults.standard.set(s.lastEndedAt, forKey: key(s.id))
    }
}

/// 用户现在是不是正看着某个单独会话的终端。
/// 条件：App 在前台；终端所在的窗口可见、没最小化、没被别的窗口整个挡住；它的终端真的显示着：
/// 「会话」页里选中的就是它，或者它绑进了群、群聊页里显示的正是这个成员的终端
/// （探针 SoloViewProbe 只跟着这两处运行中的终端一起出现，切走页面、换选中、关窗口都会把它拆掉）
///
/// 所有探针都记下来（弱引用，视图释放后自动消失），判断时只认真的挂在窗口上的那个。
/// 不能只记「最后建的那一个」：SwiftUI 有时会多建一个探针又马上丢掉，它拆掉时会把真正显示着的那个的登记一起清空，
/// 之后一直判成没在看，红点就不消失（2026-11-13 诊断日志里实际出现过：选中的会话终端显示着，登记却是空的）
@MainActor
final class SoloViewTracker {
    static let shared = SoloViewTracker()

    fileprivate let probes = NSHashTable<SoloProbeView>.weakObjects()

    func isViewing(_ id: Int64) -> Bool {
        guard NSApp.isActive else { return false }
        return probes.allObjects.contains { probe in
            guard probe.soloId == id, let window = probe.window else { return false } // 没挂在窗口上的不算
            return window.isVisible && !window.isMiniaturized && window.occlusionState.contains(.visible)
        }
    }
}

/// 探针本身：一个空视图，记着它跟着哪个单独会话的终端
final class SoloProbeView: NSView {
    var soloId: Int64 = 0
}

/// 放在单独会话终端后面的一个空视图：告诉 SoloViewTracker 这个会话的终端正显示着
struct SoloViewProbe: NSViewRepresentable {
    let id: Int64

    func makeNSView(context: Context) -> SoloProbeView {
        let view = SoloProbeView()
        view.soloId = id
        SoloViewTracker.shared.probes.add(view)
        return view
    }

    func updateNSView(_ nsView: SoloProbeView, context: Context) {
        nsView.soloId = id
    }

    static func dismantleNSView(_ nsView: SoloProbeView, coordinator: ()) {
        SoloViewTracker.shared.probes.remove(nsView)
    }
}
