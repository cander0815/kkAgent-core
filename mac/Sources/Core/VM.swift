// 虚拟机（ExitBox 的 ubx 机器）里的 Claude 会话。
// 核心跑在物理机上，读不到虚拟机里的文件，也不能直接启动里面的程序，
// 所以凡是涉及虚拟机的操作，都经物理机上的 `ubx run <机器名> <命令>` 进去执行。
// 约定：机器名为空字符串表示物理机。
import Foundation

enum VM {
    /// 正在运行的虚拟机名字；没装 ubx 时返回空
    static func running() -> [String] {
        guard let data = runUbx(["list", "--json"]),
              let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        return list.filter { $0["state"] as? String == "running" }.compactMap { $0["name"] as? String }
    }

    /// 在虚拟机里跑一个命令并拿到标准输出；跑不了或退出码非 0 返回 nil
    static func output(_ vm: String, _ command: [String]) -> Data? {
        runUbx(["run", vm] + command)
    }

    /// 一台虚拟机现在的负载：进去跑一次 shell，读核数、/proc/loadavg 和 /proc/meminfo。读不到返回 nil
    static func load(_ vm: String) -> VMLoad? {
        // 输出三行：核数；平均负载（1/5/15 分钟…）；「总内存KB 可用内存KB」
        let script = "nproc; cat /proc/loadavg; awk '/^MemTotal:/{t=$2} /^MemAvailable:/{a=$2} END{print t, a}' /proc/meminfo"
        guard let data = output(vm, ["sh", "-c", script]),
              let lines = String(data: data, encoding: .utf8)?.split(separator: "\n"), lines.count >= 3,
              let cores = Int(lines[0].trimmingCharacters(in: .whitespaces)),
              let load1 = lines[1].split(separator: " ").first.flatMap({ Double($0) }) else { return nil }
        let mem = lines[2].split(separator: " ").compactMap { Int($0) }
        guard mem.count == 2 else { return nil }
        return VMLoad(name: vm, cores: cores, load1: load1, memTotalMB: mem[0] / 1024, memUsedMB: (mem[0] - mem[1]) / 1024)
    }

    /// 启动 claude 要用的程序、参数和工作目录。
    /// 物理机：直接跑 claude。虚拟机：经 ubx run 进去跑，工作目录用 --cd 传给虚拟机。
    static func claudeLaunch(vm: String, cwd: String, args: [String]) throws -> (executable: String, args: [String], cwd: String) {
        if vm.isEmpty { return (Config.claudeBin, args, cwd) }
        guard let ubx = ShellEnv.which("ubx") else { throw CoreError(message: "找不到 ubx 命令，没法进虚拟机 \(vm)") }
        // bash -i：虚拟机里的 claude 是 nvm 装的，要读 .bashrc 才在 PATH 里。"$@" 把后面的参数原样交给 claude
        let inVM = ["bash", "-ic", "exec claude \"$@\"", "bash"] + args
        return (ubx, ["run", vm, "--cd", cwd.isEmpty ? "~" : cwd] + inVM, "")
    }

    private static func runUbx(_ args: [String]) -> Data? {
        guard let ubx = ShellEnv.which("ubx") else { return nil }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: ubx)
        p.arguments = args
        p.environment = ShellEnv.environment
        let output = Pipe()
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = output
        p.standardError = FileHandle.nullDevice
        // 输出边到边收：不能用 readDataToEndOfFile 死等结尾，子进程的后代占着管道时它会一直不返回
        var data = Data()
        let dataLock = NSLock()
        let eof = DispatchSemaphore(value: 0)
        output.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                handle.readabilityHandler = nil // 读到结尾：不摘掉的话系统会一直用空数据回调
                eof.signal()
            } else {
                dataLock.lock()
                data.append(chunk)
                dataLock.unlock()
            }
        }
        let exited = DispatchSemaphore(value: 0)
        p.terminationHandler = { _ in exited.signal() }
        guard (try? p.run()) != nil else {
            output.fileHandleForReading.readabilityHandler = nil
            return nil
        }

        // 虚拟机卡住时 ubx 可能一直不返回：最多等 15 秒；到点先请它退出，2 秒还不退就强制结束。超时一律算失败
        var timedOut = false
        if exited.wait(timeout: .now() + 15) == .timedOut {
            timedOut = true
            p.terminate()
            if exited.wait(timeout: .now() + 2) == .timedOut {
                kill(p.processIdentifier, SIGKILL) // 只杀这次自己启动的这个进程
                _ = exited.wait(timeout: .now() + 2)
            }
        }
        // 进程退出后，剩下的输出最多再等 2 秒读完（后代进程占着管道时不会有结尾，到点就不等了）
        let complete = eof.wait(timeout: .now() + 2) == .success
        output.fileHandleForReading.readabilityHandler = nil
        dataLock.lock()
        defer { dataLock.unlock() }
        if timedOut { log("ubx \(args.prefix(2).joined(separator: " ")) 超过 15 秒没返回，已停止，结果按失败处理") }
        return !timedOut && complete && !p.isRunning && p.terminationStatus == 0 ? data : nil
    }
}
