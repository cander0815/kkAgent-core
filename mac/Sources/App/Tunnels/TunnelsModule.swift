// 左边栏「端口」：一键开关 ssh 端口转发（原来 tun 目录下的几个 sh 脚本）。
// 配置读本机的 ~/.kkagent/tunnels.json（见 TunnelConfig.swift），运行管理在 TunnelManager.swift，这里只负责显示和点按钮。
// 这个页面不依赖核心，核心没启动也能用。
import SwiftUI

struct TunnelsModule: View {
    @ObservedObject private var manager = TunnelManager.shared

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("端口转发").font(.headline)
                Spacer()
                Text("退出 app 时会一并关闭").font(.caption).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)
            .frame(height: 56)
            Divider()
            if !manager.orphanPids.isEmpty {
                OrphanBanner(count: manager.orphanPids.count)
                Divider()
            }
            ScrollView {
                VStack(spacing: 12) {
                    // 配置文件读不到或格式不对时，告诉用户原因和怎么办
                    if let error = TunnelSpec.loaded.error {
                        Text(error).font(.callout).foregroundStyle(.orange).textSelection(.enabled)
                    }
                    ForEach(TunnelSpec.all) { spec in
                        TunnelCard(spec: spec, state: manager.state(spec), log: manager.logs[spec.id] ?? "")
                    }
                }
                .padding(16)
            }
        }
        // 页面开着时每 3 秒扫一次残留的 ssh；离开页面任务会自动取消
        .task {
            while !Task.isCancelled {
                manager.scanOrphans()
                try? await Task.sleep(nanoseconds: 3_000_000_000)
            }
        }
    }
}

/// 发现残留 ssh 时顶部的提示条：这些进程是 app 被强杀或崩溃后留下的，会一直占着本机端口
private struct OrphanBanner: View {
    let count: Int

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text("发现 \(count) 个残留的 ssh 隧道进程（上次 app 异常退出留下的），正占着本机端口")
                .font(.callout)
            Spacer()
            Button("清理") { TunnelManager.shared.killOrphans() }
                .clickable()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color.orange.opacity(0.12))
    }
}

/// 一条隧道的卡片：名称 + 状态 + 开关，下面列出每条端口转发
private struct TunnelCard: View {
    let spec: TunnelSpec
    let state: TunnelState
    let log: String

    private var isActive: Bool {
        switch state {
        case .connecting, .running, .retrying: return true
        case .stopped, .failed: return false
        }
    }

    private var statusColor: Color {
        switch state {
        case .running: return .green
        case .connecting, .retrying: return .orange
        case .failed: return .red
        case .stopped: return .secondary
        }
    }

    private var statusText: String {
        switch state {
        case .stopped: return "未开启"
        case .connecting: return "连接中…"
        case .running: return "已连通"
        case .retrying(let n): return "已断开，第 \(n)/\(TunnelManager.maxRetries) 次重试中…"
        case .failed(let reason): return reason
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Circle().fill(statusColor).frame(width: 9, height: 9)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(spec.name).font(Theme.nameFont(14))
                        Text("经 \(spec.host)").font(.caption).foregroundStyle(.secondary)
                    }
                    Text(spec.note).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button(isActive ? "关闭" : "开启") {
                    if isActive { TunnelManager.shared.stop(spec) } else { TunnelManager.shared.start(spec) }
                }
                .controlSize(.regular)
                .clickable()
            }

            Text(statusText)
                .font(.caption)
                .foregroundStyle(statusColor)
                .textSelection(.enabled)

            Divider()
            ForEach(spec.forwards) { forward in
                ForwardRow(forward: forward)
            }

            // 失败时把 ssh 的原始报错也给出来，方便判断是端口被占、密钥不对还是网络不通
            if case .failed = state, !log.isEmpty {
                Text(log.trimmingCharacters(in: .whitespacesAndNewlines))
                    .font(Theme.code)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.08)))
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.secondary.opacity(0.2)))
    }
}

/// 一行端口转发：说明、本机地址（可复制）、目标地址
private struct ForwardRow: View {
    let forward: TunnelForward

    var body: some View {
        HStack(spacing: 8) {
            Text(forward.label).font(.callout).frame(width: 110, alignment: .leading)
            Text(forward.localAddress).font(Theme.code)
            CopyButton(text: forward.localAddress, help: "复制本机地址")
            Image(systemName: "arrow.right").font(.caption).foregroundStyle(.secondary)
            // 用 verbatim：Text 的字符串插值会给数字加千分位（3312 变成 3,312）
            Text(verbatim: "\(forward.targetHost):\(forward.targetPort)")
                .font(Theme.code)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            if forward.exposedToLAN {
                Text("局域网可访问")
                    .font(.caption2)
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(Capsule().fill(Color.orange.opacity(0.15)))
                    .foregroundStyle(.orange)
            }
            Spacer(minLength: 0)
        }
    }
}
