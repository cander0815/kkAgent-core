// kkAgent 核心入口：由 launchd 常驻运行，没有界面。
// 日志在 ~/.kkagent/core.log
import Foundation

log("kkAgent 核心启动中（pid \(getpid())）")
// 往已经退出的子进程管道里写时，系统默认发 SIGPIPE 直接杀掉核心；忽略它，让写操作返回错误由代码处理
signal(SIGPIPE, SIG_IGN)
_ = ShellEnv.environment // 先把登录 shell 的环境读好，后面启动 claude / codex 都要用

let repo: Repository
var interruptedMembers: [Int64] = [] // 上次被核心重启打断的后台成员，启动后通知它们的群主
var unconfirmedMembers: [Int64] = [] // 上次核心退出时消息已写进会话、还没确认的成员，启动后通知
do {
    repo = try Repository(path: Config.dbPath)
    (interruptedMembers, unconfirmedMembers) = try repo.failUnfinishedDeliveries()
    try repo.recoverInterruptsOnStartup() // 第 6 步：上次没结算的打断记录，按「一定没按 / 结果未知」收尾，不会再按一次
} catch {
    log("数据库打开失败：\(error)")
    exit(1)
}

AgentStatusStore.shared.restore(repo: repo) // tmux 里还活着的 Claude 继续认它的 hook 事件
let delivery = DeliveryQueue(repo: repo)
delivery.requeuePending() // 上次还在排队、没开始的消息接着投（会合并成一轮）
delivery.recoverSolosOnStartup() // 上次还在启动的单独会话：界面已就绪就接管，否则记成启动失败（不会一直显示「正在启动」）
/// 状态归属换成要处理的群成员：成员就是它自己；单独会话是绑着它的那个成员，没绑进群就没有
func boundMember(_ owner: StatusOwner) -> Int64? {
    switch owner {
    case .member(let id): return id
    case .solo(let id): return (try? repo.memberBound(toSolo: id))?.id
    }
}
// coder 一停下就把攒下的消息送进去
AgentStatusStore.shared.onIdle = { if let id = boundMember($0) { delivery.wake(memberId: id) } }
// 卡在授权框上告诉群主（没绑进群的单独会话不用通知，用户就在它的终端里）
AgentStatusStore.shared.onPermission = { owner, info, remind in
    if let id = boundMember(owner) { delivery.reportPermission(memberId: id, info: info, remind: remind) }
}
// 单独会话（不管绑没绑进群）的一轮结束了：记下怎么结束的，App 据此显示未读和发通知。群成员不记（群里有自己的消息）
AgentStatusStore.shared.onTurnEnded = { owner, outcome in
    if case .solo(let id) = owner { delivery.recordSoloTurn(id, outcome: outcome) }
}
delivery.startPolling() // 对方忙时消息先存着，每 3 秒看一次空闲了没有
delivery.reportInterrupted(memberIds: interruptedMembers)
for id in unconfirmedMembers {
    if let member = try? repo.getMember(id) { delivery.reportUnconfirmed(member: member, reason: "核心重启时已经写进会话，没能确认收到") }
}
let api = API(repo: repo, delivery: delivery)
let server: HTTPServer
do {
    server = try HTTPServer(port: Config.port, handler: api.handle)
} catch {
    log("创建 HTTP 服务失败：\(error)")
    exit(1)
}

server.start(
    onReady: { log("kkAgent 核心已启动：http://127.0.0.1:\(Config.port)，数据库 \(Config.dbPath)") },
    onFailure: { error in
        log("端口 \(Config.port) 监听失败（是不是被别的程序占用了？）：\(error)")
        exit(1) // 退出后 launchd 会稍后重试
    }
)

// 收到退出信号时，先关掉中转会话再退出（signalSources 要一直持有，否则监听会被释放）
var signalSources: [DispatchSourceSignal] = []
for sig in [SIGTERM, SIGINT] {
    signal(sig, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
    source.setEventHandler {
        log("收到退出信号，关闭中转会话和正在跑的投递进程")
        Relay.stopAll()
        delivery.terminateAll()
        exit(0)
    }
    source.resume()
    signalSources.append(source)
}

dispatchMain()
