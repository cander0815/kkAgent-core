// 隧道的运行管理：开关 ssh 进程、检查端口通没通、意外断开时最多自动重试 3 次。
// 用单例而不是放在窗口里：关掉窗口再打开，ssh 进程还在，状态不能丢。退出 app 时统一关掉所有 ssh。
import AppKit
import Foundation

enum TunnelState: Equatable {
    case stopped
    case connecting        // ssh 已启动，本机端口还没通
    case running           // 本机端口已经连得上
    case retrying(Int)     // 意外断开，正在做第 n 次重试
    case failed(String)    // 重试用完或起不来，带原因
}

@MainActor
final class TunnelManager: ObservableObject {
    static let shared = TunnelManager()

    static let maxRetries = 3          // 意外断开最多自动重连几次
    private static let retryDelay: UInt64 = 3_000_000_000   // 每次重试前等 3 秒（纳秒）
    private static let stableSeconds: TimeInterval = 60     // 连着跑满这么久再断，重试次数重新算

    @Published private(set) var states: [String: TunnelState] = [:]
    @Published private(set) var logs: [String: String] = [:]   // ssh 的报错输出，只留最后一段
    @Published private(set) var orphanPids: [Int32] = []       // 残留的 ssh 隧道进程（app 被强杀、崩溃后留下的）

    private var processes: [String: Process] = [:]
    private var startedAt: [String: Date] = [:]
    private var retryCount: [String: Int] = [:]
    private var retryTasks: [String: Task<Void, Never>] = [:]   // 正在等待重试的任务，点开启/关闭时要取消

    private init() {
        // 每 2 秒看一次端口：ssh 进程活着且端口连得上才算「已连通」
        Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.probePorts() }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.stopAll() }
        }
    }

    func state(_ spec: TunnelSpec) -> TunnelState { states[spec.id] ?? .stopped }

    /// 点「开启」：重试次数清零，重新开始
    func start(_ spec: TunnelSpec) {
        retryTasks[spec.id]?.cancel()
        logs[spec.id] = ""
        // 别的隧道只要开着（包括连接中、重试等待中），就占着它的端口
        if let conflict = TunnelSpec.all.first(where: { other in
            other.id != spec.id && isActive(other) && !Set(other.localPorts).isDisjoint(with: spec.localPorts)
        }) {
            let ports = Set(conflict.localPorts).intersection(spec.localPorts).sorted().map(String.init).joined(separator: "、")
            states[spec.id] = .failed("本机端口 \(ports) 正被「\(conflict.name)」占用，先把它关掉")
            return
        }
        retryCount[spec.id] = 0
        launch(spec)
    }

    /// 点「关闭」：主动关的不会触发重试
    func stop(_ spec: TunnelSpec) {
        retryTasks[spec.id]?.cancel()
        retryCount[spec.id] = 0
        states[spec.id] = .stopped
        if let p = processes.removeValue(forKey: spec.id) { p.terminate() }
    }

    func stopAll() {
        TunnelSpec.all.forEach(stop)
    }

    // ---------- 残留进程 ----------

    /// 扫描残留的 ssh：命令行里带 -N 和我们配置里某条完整的 -L 参数、但不是本次 app 自己起的。
    /// 靠完整的 -L 参数认人，别的程序起的 ssh（端口不同）不会被认成残留
    func scanOrphans() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/ps")
        p.arguments = ["-axo", "pid=,command="]
        let pipe = Pipe()
        p.standardOutput = pipe
        guard (try? p.run()) != nil else { return }
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        p.waitUntilExit()

        let ownPids = Set(processes.values.map(\.processIdentifier))
        let forwardArgs = TunnelSpec.all.flatMap(\.forwards).map { "-L \($0.sshArgument)" }
        var found: [Int32] = []
        for line in output.split(separator: "\n") {
            let parts = line.trimmingCharacters(in: .whitespaces).split(separator: " ", maxSplits: 1)
            guard parts.count == 2, let pid = Int32(parts[0]), !ownPids.contains(pid) else { continue }
            let command = String(parts[1])
            if command.hasPrefix("/usr/bin/ssh ") && command.contains(" -N ") && forwardArgs.contains(where: command.contains) {
                found.append(pid)
            }
        }
        if orphanPids != found { orphanPids = found }
    }

    /// 点「清理」：结束所有残留的 ssh，稍等一下再扫一次确认
    func killOrphans() {
        orphanPids.forEach { kill($0, SIGTERM) }
        Task {
            try? await Task.sleep(nanoseconds: 500_000_000)
            scanOrphans()
        }
    }

    // ---------- 内部 ----------

    /// 这条隧道现在是不是开着（连接中、已连通、重试等待中都算）
    private func isActive(_ spec: TunnelSpec) -> Bool {
        switch state(spec) {
        case .connecting, .running, .retrying: return true
        case .stopped, .failed: return false
        }
    }

    private func launch(_ spec: TunnelSpec) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        var args = [
            "-N",                                  // 只转发端口，不开远程 shell
            "-o", "ExitOnForwardFailure=yes",      // 端口被占用就直接退出，不要悄悄失败
            "-o", "ServerAliveInterval=30",        // 每 30 秒探一次，连不上 3 次就断开，好让我们发现并重连
            "-o", "ServerAliveCountMax=3",
            "-o", "BatchMode=yes",                 // 需要输入密码时直接失败，不要卡住等输入（界面里没法输入）
        ]
        for f in spec.forwards { args += ["-L", f.sshArgument] }
        args.append(spec.host)
        p.arguments = args

        let pipe = Pipe()
        p.standardError = pipe
        p.standardOutput = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            let text = String(decoding: data, as: UTF8.self)
            Task { @MainActor in self?.appendLog(spec.id, text) }
        }
        p.terminationHandler = { [weak self] proc in
            pipe.fileHandleForReading.readabilityHandler = nil
            // ssh 报完错马上退出时，管道里可能还有没读走的最后几行，要读完再算「退出」，否则看不到失败原因
            let rest = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            Task { @MainActor in
                if !rest.isEmpty { self?.appendLog(spec.id, rest) }
                self?.didExit(spec, proc)
            }
        }

        do {
            try p.run()
        } catch {
            states[spec.id] = .failed("启动 ssh 失败：\(error.localizedDescription)")
            return
        }
        processes[spec.id] = p
        startedAt[spec.id] = Date()
        states[spec.id] = .connecting
    }

    /// ssh 进程退出了。如果是我们主动关的（processes 里已经没有它），什么都不做
    private func didExit(_ spec: TunnelSpec, _ proc: Process) {
        guard processes[spec.id] === proc else { return }
        processes[spec.id] = nil

        // 连着跑了很久才断，说明之前是稳定的，重试次数重新算
        if let begin = startedAt[spec.id], Date().timeIntervalSince(begin) >= Self.stableSeconds {
            retryCount[spec.id] = 0
        }
        let attempt = (retryCount[spec.id] ?? 0) + 1
        guard attempt <= Self.maxRetries else {
            let reason = (logs[spec.id] ?? "").split(separator: "\n").last.map(String.init) ?? "ssh 退出，退出码 \(proc.terminationStatus)"
            states[spec.id] = .failed("已自动重试 \(Self.maxRetries) 次仍未连上：\(reason)")
            return
        }
        retryCount[spec.id] = attempt
        states[spec.id] = .retrying(attempt)
        retryTasks[spec.id] = Task {
            try? await Task.sleep(nanoseconds: Self.retryDelay)
            // 等的这几秒里用户点了关闭或重新开启，这个任务会被取消，就不再重试
            guard !Task.isCancelled else { return }
            launch(spec)
        }
    }

    private func appendLog(_ id: String, _ text: String) {
        logs[id] = String(((logs[id] ?? "") + text).suffix(2000))
    }

    /// 本机端口都连得上才算已连通
    private func probePorts() {
        for spec in TunnelSpec.all where processes[spec.id] != nil {
            let open = spec.localPorts.allSatisfy(Self.isPortOpen)
            let now: TunnelState = open ? .running : .connecting
            if states[spec.id] != now { states[spec.id] = now }
        }
    }

    /// 连一下 127.0.0.1:端口。本机回环地址，连得上立刻成功，连不上立刻被拒，不会卡住
    private static func isPortOpen(_ port: Int) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(port).bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let result = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        return result == 0
    }
}
