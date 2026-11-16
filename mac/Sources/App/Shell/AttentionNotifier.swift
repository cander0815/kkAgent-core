// 系统通知：
// - 有成员 / 单独会话卡在授权框上（只有用户能去它的终端里点批准或拒绝，不提醒的话很容易注意不到）；
// - 单独会话这一轮结束了、出错了，或者启动失败了（见 kktodo/会话提醒-方案.md）。
// 点通知：打开主窗口。群成员选中那个群和成员，右栏就是它的终端；单独会话（绑没绑进群都一样）切到「会话」页选中它。
// 通知由 App 发：只关掉窗口没关系（App 还挂在菜单栏里）；从菜单栏彻底退出 App 后就收不到了。
//
// 去重键按「事件类型 | 归属 | id | 时间」：
// permission|member|<成员id>|<开始等的时间>、permission|solo|<单独会话id>|<开始等的时间>、
// result|solo|<id>|<这一轮的结束时间>、startup|solo|<id>。
// 单独会话的授权等待不管绑没绑进群都按单独会话记，绑进群、移出群前后是同一次等待，不会重复通知
import AppKit
import UserNotifications

@MainActor
final class AttentionNotifier: NSObject, UNUserNotificationCenterDelegate {
    /// 用户点了群成员的通知：参数是群 id 和成员 id
    var onOpen: ((String, Int64) -> Void)?
    /// 用户点了单独会话的通知：参数是单独会话 id
    var onOpenSolo: ((Int64) -> Void)?

    /// 已经成功通知过的。授权等待结束后从这里删掉（下次再卡住会重新通知）；结果和启动失败的一直留着
    private var notified = Set<String>()
    /// 正在提交给系统、还没回结果的：防止下一次刷新又提交一遍
    private var submitting = Set<String>()
    /// 提交失败过几次：系统偶尔失败时重试，最多 3 次，免得一直失败一直试
    private var failures: [String: Int] = [:]
    private var authorized = false

    /// 单独会话：第一次成功拿到列表时，已经有的结束结果只记在这里、不通知（不然每次打开 App 都会把旧结果通知一遍）
    private var soloBaselined = false
    private var historicalResults = Set<String>()
    /// 单独会话的显示名（授权通知里用）
    private var soloNames: [Int64: String] = [:]

    /// App 启动时调用一次：申请通知权限（第一次会弹窗问用户），并接管通知的点击
    func start() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            Task { @MainActor in self.authorized = granted }
        }
    }

    /// 每次刷新时调用：给新出现的授权等待发通知
    func update(_ items: [AttentionItem]) {
        let current = Set(items.map(permissionKey))
        // 已经处理掉的等待忘掉，下次再卡住会重新通知
        let ended = { (key: String) in key.hasPrefix("permission|") && !current.contains(key) }
        notified = notified.filter { !ended($0) }
        failures = failures.filter { !ended($0.key) }
        for item in items {
            // 用户正看着这个单独会话的终端：授权框就在眼前，这次刷新先不发。没处理就离开了的，下次刷新照样通知
            if item.soloId != 0 && SoloViewTracker.shared.isViewing(item.soloId) { continue }
            let who: String
            if item.soloId != 0 && item.groupId.isEmpty {
                who = soloNames[item.soloId] ?? item.alias
            } else {
                who = "\(item.alias)（\(item.groupName)）"
            }
            // 单独会话一律只带 soloId，点通知跳「会话」页（通知发出后它可能已经移出群了，不能跳到旧成员）
            let userInfo: [String: Any] = item.soloId != 0 ? ["soloId": item.soloId] : ["groupId": item.groupId, "memberId": item.memberId]
            submit(id: permissionKey(item),
                   title: "\(item.bySubagent ? "\(who) 的子 agent" : who) 在等授权",
                   body: "\(item.tool)：\(item.detail)\n只有你能在它的终端里批准或拒绝。",
                   userInfo: userInfo)
        }
    }

    /// 每次成功拿到单独会话列表时调用（拿失败了不要调，不然会建出一个空基线）：
    /// 新的一轮结束、出错，启动失败，发通知。用户正看着的会话不发，直接记成看过
    func updateSolos(_ sessions: [SoloSession]) {
        for s in sessions { soloNames[s.id] = SoloModel.name(for: s) }
        if !soloBaselined {
            historicalResults = Set(sessions.filter(SoloReadState.hasResult).map(resultKey))
            soloBaselined = true
        }
        for s in sessions {
            let name = SoloModel.name(for: s)
            let place = "\(shortPath(s.cwd)) · \(s.agent.displayName)"
            if s.state == "failed" {
                submit(id: "startup|solo|\(s.id)", title: "\(name) 启动失败",
                       body: s.error.isEmpty ? place : "\(place)\n\(s.error)", userInfo: ["soloId": s.id])
            }
            guard SoloReadState.isUnread(s), !historicalResults.contains(resultKey(s)) else { continue }
            if SoloViewTracker.shared.isViewing(s.id) {
                SoloReadState.markViewed(s) // 用户正看着它的终端，结果就在眼前
                continue
            }
            submit(id: resultKey(s), title: s.lastOutcome == "failed" ? "\(name) 这一轮出错了" : "\(name) 这一轮已结束",
                   body: "\(place)\n点击打开它的终端查看", userInfo: ["soloId": s.id])
        }
    }

    /// 提交一条通知。系统确认收下了才算通知过；失败的记下次数，下次刷新再试（最多 3 次）
    private func submit(id: String, title: String, body: String, userInfo: [String: Any]) {
        guard authorized, !notified.contains(id), !submitting.contains(id), failures[id, default: 0] < 3 else { return }
        submitting.insert(id)
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.userInfo = userInfo
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: content, trigger: nil)) { error in
            Task { @MainActor in
                self.submitting.remove(id)
                if let error {
                    self.failures[id, default: 0] += 1
                    NSLog("kkAgent：通知提交失败（第 \(self.failures[id] ?? 0) 次）：\(error.localizedDescription)")
                } else {
                    self.notified.insert(id)
                }
            }
        }
    }

    private func permissionKey(_ item: AttentionItem) -> String {
        item.soloId != 0 ? "permission|solo|\(item.soloId)|\(item.since)" : "permission|member|\(item.memberId)|\(item.since)"
    }

    private func resultKey(_ s: SoloSession) -> String { "result|solo|\(s.id)|\(s.lastEndedAt)" }

    // App 在前台时也显示横幅（默认前台不显示）
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let info = response.notification.request.content.userInfo
        let groupId = info["groupId"] as? String
        let memberId = (info["memberId"] as? NSNumber)?.int64Value
        let soloId = (info["soloId"] as? NSNumber)?.int64Value
        Task { @MainActor in
            if let soloId {
                self.onOpenSolo?(soloId)
            } else if let groupId, let memberId {
                self.onOpen?(groupId, memberId)
            }
            completionHandler()
        }
    }
}
