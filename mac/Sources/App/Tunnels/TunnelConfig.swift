// 「端口」页的隧道配置：每条隧道 = 一台跳板机 + 若干条「本机端口 → 目标地址:端口」的转发。
// 实际执行的就是 `ssh -N -L 本机:端口:目标:端口 跳板机`（见 TunnelManager.swift）。
//
// 配置不放在代码里（里面是内网和线上数据库的地址，不能进 git），而是读本机文件：
//   ~/.kkagent/tunnels.json
// 格式看同目录的 tunnels.example.json。改完配置要重新打开 app 才生效。
import Foundation

/// 一条端口转发：本机 bind:localPort → targetHost:targetPort
struct TunnelForward: Identifiable, Decodable {
    let label: String            // 给人看的说明，比如「MySQL」
    let localPort: Int
    let targetHost: String
    let targetPort: Int
    let bind: String             // 本机监听地址；不写就是 127.0.0.1，写成 0.0.0.0 局域网里的其他机器也能连

    var id: Int { localPort }
    var exposedToLAN: Bool { bind != "127.0.0.1" }
    var localAddress: String { "127.0.0.1:\(localPort)" }

    /// ssh -L 的参数值
    var sshArgument: String { "\(bind):\(localPort):\(targetHost):\(targetPort)" }

    private enum CodingKeys: String, CodingKey { case label, localPort, targetHost, targetPort, bind }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        label = try c.decode(String.self, forKey: .label)
        localPort = try c.decode(Int.self, forKey: .localPort)
        targetHost = try c.decode(String.self, forKey: .targetHost)
        targetPort = try c.decode(Int.self, forKey: .targetPort)
        bind = try c.decodeIfPresent(String.self, forKey: .bind) ?? "127.0.0.1"
    }
}

struct TunnelSpec: Identifiable, Decodable {
    let id: String               // 唯一标识，只在 app 内部用，不要改已有的
    let name: String
    let note: String             // 一句话说明这条隧道是干什么的
    let host: String             // ssh 的主机：~/.ssh/config 里的别名，或者 user@ip
    let forwards: [TunnelForward]

    /// 这条隧道占用的本机端口
    var localPorts: [Int] { forwards.map(\.localPort) }

    /// 配置文件的位置
    static let configPath = "\(NSHomeDirectory())/.kkagent/tunnels.json"

    /// 启动时读一次配置文件：读到的隧道，和读不到时的原因（页面会显示出来）
    static let loaded: (specs: [TunnelSpec], error: String?) = {
        guard let data = FileManager.default.contents(atPath: configPath) else {
            return ([], "还没有配置文件。把 tunnels.example.json 复制到 \(configPath)，改成自己的隧道，再重新打开 app")
        }
        struct File: Decodable { let tunnels: [TunnelSpec] }
        do {
            return (try JSONDecoder().decode(File.self, from: data).tunnels, nil)
        } catch {
            return ([], "配置文件格式不对（\(configPath)）：\(error.localizedDescription)")
        }
    }()

    /// 所有隧道。注意：同一个本机端口不能被两条同时开着的隧道占用，页面里会提示。
    static var all: [TunnelSpec] { loaded.specs }
}
