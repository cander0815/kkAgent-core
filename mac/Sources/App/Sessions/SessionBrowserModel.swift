// 会话浏览的状态：Claude、Codex 各一份（RootView 持有，切换功能再切回来时选中的会话还在）。
// 和群聊一样只走核心接口，不直接读会话文件。
import Foundation

/// 用户自建的会话文件夹，建在某个项目（工作目录）下面
struct SessionFolder: Codable, Identifiable, Hashable {
    let id: String
    let cwd: String // 属于哪个项目
    var name: String
}

@MainActor
final class SessionBrowserModel: ObservableObject {
    let agent: AgentKind
    @Published private(set) var vms: [String] = []           // 正在运行的虚拟机
    @Published private(set) var vm = ""                       // 正在看哪台机器：空 = 物理机
    @Published private(set) var sessions: [SessionSummary] = []
    @Published private(set) var loadingList = false
    @Published private(set) var selected: SessionSummary?
    @Published private(set) var events: [TranscriptEvent] = []
    /// 正在读的那一轮的编号。每次换会话编号加一，旧会话没读完的那轮回来后对不上编号，直接丢掉
    @Published private var loadingGeneration: Int?
    private var generation = 0
    /// 选中的会话正在一段段读
    var loadingTranscript: Bool { loadingGeneration == generation }
    @Published private(set) var transcriptError: String?
    @Published private(set) var models: [String] = []      // 选中的会话用过的模型
    @Published private(set) var usage: TokenUsage?          // 选中的会话的 token 用量；没有记录时为 nil
    /// 展开着的项目（工作目录）。默认全部收起，放在这里是为了切换功能再回来时保持原样
    @Published var expandedProjects: Set<String> = []
    /// 用户拖动排好的项目顺序（工作目录）。只是界面上的显示偏好，存在本机 UserDefaults，不经过核心
    @Published private(set) var projectOrder: [String]
    // 下面三项是用户自己的整理方式，和项目顺序一样只存在本机 UserDefaults，不改会话文件
    @Published private(set) var customNames: [String: String] // 会话 ID → 自己起的名字
    @Published private(set) var folders: [SessionFolder]      // 自建文件夹（各项目的都在这里），按创建顺序
    @Published private(set) var folderOf: [String: String]    // 会话 ID → 所在文件夹 ID（一个会话只放一个文件夹）
    /// 收起着的文件夹。新建的文件夹默认展开，所以记「收起」的
    @Published var collapsedFolders: Set<String> = []
    /// 隐藏 kkAgent 子群建的 worktree 项目（见 isWorktree），默认隐藏。显示偏好，存在本机 UserDefaults，Claude / Codex 两个列表共用
    @Published var hideWorktrees: Bool {
        didSet { UserDefaults.standard.set(hideWorktrees, forKey: "sessionsHideWorktrees") }
    }

    private let api = APIClient()
    private var pickedMachine = false // 用户自己点过物理机 / 虚拟机切换
    private var offset = 0 // 已经读到会话文件的哪个字节
    private var source = "" // 读的是哪个会话文件（offset 只在同一个文件里有意义，桌面端 Codex 会分段写到新文件）
    private var claudeUsage: [String: TokenUsage] = [:] // Claude 会话：回复 ID → 用量
    private var orderKey: String { "projectOrder.\(agent.rawValue)" }
    private var namesKey: String { "sessionNames.\(agent.rawValue)" }
    private var foldersKey: String { "sessionFolders.\(agent.rawValue)" }
    private var folderOfKey: String { "sessionFolderOf.\(agent.rawValue)" }

    init(agent: AgentKind) {
        self.agent = agent
        let defaults = UserDefaults.standard
        projectOrder = defaults.stringArray(forKey: "projectOrder.\(agent.rawValue)") ?? []
        customNames = defaults.dictionary(forKey: "sessionNames.\(agent.rawValue)") as? [String: String] ?? [:]
        folderOf = defaults.dictionary(forKey: "sessionFolderOf.\(agent.rawValue)") as? [String: String] ?? [:]
        let data = defaults.data(forKey: "sessionFolders.\(agent.rawValue)") ?? Data()
        folders = (try? JSONDecoder().decode([SessionFolder].self, from: data)) ?? []
        // 默认隐藏（没设置过时 bool(forKey:) 会返回 false，所以先看有没有存过）
        hideWorktrees = defaults.object(forKey: "sessionsHideWorktrees") as? Bool ?? true
    }

    /// 这个工作目录是不是 kkAgent 为集群子群建的 git worktree：
    /// 现在建在 <项目>/.worktrees/<子群ID>，以前建在 <项目>-kkwt/<子群ID>（见 Core/Cluster.swift）。
    /// 会话也可能是在 worktree 里面的子目录开的（比如 …/gbl49/apps/service），所以按路径里有没有这一段来认
    static func isWorktree(_ cwd: String) -> Bool {
        cwd.contains("/.worktrees/") || cwd.range(of: #"-kkwt/[^/]+"#, options: .regularExpression) != nil
    }

    // ---------- 改名和文件夹 ----------

    /// 列表和详情里显示的标题：自己起过名字就用自己的
    func displayTitle(_ session: SessionSummary) -> String {
        customNames[session.id] ?? session.title
    }

    /// 给会话改名；名字留空等于恢复原来的标题
    func rename(_ sessionId: String, to name: String) {
        let name = name.trimmingCharacters(in: .whitespaces)
        customNames[sessionId] = name.isEmpty ? nil : name
        UserDefaults.standard.set(customNames, forKey: namesKey)
    }

    /// 某个项目下的文件夹
    func folders(in cwd: String) -> [SessionFolder] {
        folders.filter { $0.cwd == cwd }
    }

    /// 在项目 cwd 下新建文件夹，返回它的 ID（方便「新建并把会话放进去」）
    @discardableResult
    func createFolder(_ name: String, in cwd: String) -> String? {
        let name = name.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return nil }
        let folder = SessionFolder(id: UUID().uuidString, cwd: cwd, name: name)
        folders.append(folder)
        saveFolders()
        return folder.id
    }

    func renameFolder(_ id: String, to name: String) {
        let name = name.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, let index = folders.firstIndex(where: { $0.id == id }) else { return }
        folders[index].name = name
        saveFolders()
    }

    /// 删除文件夹：只是去掉这个分组，里面的会话不受影响
    func deleteFolder(_ id: String) {
        folders.removeAll { $0.id == id }
        folderOf = folderOf.filter { $0.value != id }
        saveFolders()
    }

    /// 把会话放进文件夹；folderId 为 nil 表示移出文件夹
    func move(_ sessionId: String, toFolder folderId: String?) {
        folderOf[sessionId] = folderId
        saveFolders()
    }

    private func saveFolders() {
        UserDefaults.standard.set(try? JSONEncoder().encode(folders), forKey: foldersKey)
        UserDefaults.standard.set(folderOf, forKey: folderOfKey)
    }

    // ---------- 项目排序 ----------

    /// 传入按最近使用排好的项目，返回最终显示顺序：
    /// 还没排过的（新出现的项目）放最上面，彼此之间按最近使用；排过的按用户排的顺序跟在后面
    func sortProjects(_ recent: [String]) -> [String] {
        let saved = Set(projectOrder)
        return recent.filter { !saved.contains($0) } + projectOrder.filter { recent.contains($0) }
    }

    /// 把项目拖到另一个项目的位置：往下拖放在它后面，往上拖放在它前面。visible 是当前显示的完整顺序
    func moveProject(_ cwd: String, to target: String, visible: [String]) {
        var list = visible
        guard let from = list.firstIndex(of: cwd), let to = list.firstIndex(of: target), from != to else { return }
        list.remove(at: from)
        list.insert(cwd, at: to)
        saveOrder(list)
    }

    /// 移到最上面 / 最下面
    func moveProjectToEdge(_ cwd: String, top: Bool, visible: [String]) {
        var list = visible.filter { $0 != cwd }
        if top { list.insert(cwd, at: 0) } else { list.append(cwd) }
        saveOrder(list)
    }

    /// 恢复按最近使用排序
    func resetProjectOrder() {
        projectOrder = []
        UserDefaults.standard.removeObject(forKey: orderKey)
    }

    private func saveOrder(_ visible: [String]) {
        // 当前机器上看不到的项目（比如另一台机器的）保留原来的记录，接在后面
        projectOrder = visible + projectOrder.filter { !visible.contains($0) }
        UserDefaults.standard.set(projectOrder, forKey: orderKey)
    }

    /// 切换机器：清掉上一台机器的列表和选中的会话，重新拉列表
    func selectMachine(_ name: String) {
        pickedMachine = true
        guard name != vm else { return }
        vm = name
        sessions = [] // 新列表回来之前别还显示上一台机器的会话
        select(nil)
        Task { await loadList() }
    }

    /// 拉会话列表（Claude 顺便刷新虚拟机列表）
    func loadList() async {
        loadingList = true
        defer { loadingList = false }
        // 「会话」页也会改名（同一份 UserDefaults），切回来时重新读一次
        customNames = UserDefaults.standard.dictionary(forKey: namesKey) as? [String: String] ?? [:]
        // 请求失败（比如 ubx 偶尔超时）时保持原样；确实拿到了列表、里面没有正在看的虚拟机，才退回物理机
        if agent == .claude, let list: [String] = try? await api.get("/api/vms") {
            vms = list
            if !vm.isEmpty && !vms.contains(vm) { vm = ""; sessions = []; select(nil) }
            // 默认看虚拟机（有开着的话）；自己点过切换之后就不再替你改
            if !pickedMachine, vm.isEmpty, let first = vms.first { vm = first }
        }
        let machine = vm
        let list: [SessionSummary] = (try? await api.get("/api/sessions?agent=\(agent.rawValue)&vm=\(query(machine))")) ?? []
        guard machine == vm else { return } // 请求期间又切了机器，丢掉这次结果
        sessions = list
    }

    func select(_ session: SessionSummary?) {
        guard session?.id != selected?.id else { return }
        generation += 1 // 之前那个会话还没读完的请求，回来后会因为编号对不上被丢掉
        selected = session
        events = []
        offset = 0
        source = ""
        transcriptError = nil
        models = []
        usage = nil
        claudeUsage = [:]
        if session != nil { Task { await loadTranscript() } }
    }

    /// 从上次读到的位置接着读，直到读完。会话还在进行时，界面每 2 秒调一次，新内容会接在后面
    func loadTranscript() async {
        // 同一个会话已经在读就不重复读；换了会话（编号变了）则立刻开始读新的，不用等旧的那轮结束
        guard let session = selected, loadingGeneration != generation else { return }
        let gen = generation
        loadingGeneration = gen
        defer { if loadingGeneration == gen { loadingGeneration = nil } }
        while true {
            let from = offset
            let fromSource = source
            let path = "/api/sessions/\(session.id)/transcript?agent=\(agent.rawValue)&vm=\(query(session.vm))&offset=\(from)&source=\(query(fromSource))"
            do {
                let chunk: TranscriptChunk = try await api.get(path)
                guard gen == generation, offset == from else { return } // 期间切换了会话
                transcriptError = nil
                events += chunk.events
                offset = chunk.offset
                source = chunk.source ?? ""
                models += (chunk.models ?? []).filter { !models.contains($0) }
                // Claude 给的是每条回复的用量，按回复 ID 合并后重新加总（同一条回复只算一次，
                // 重记的那份用量有时是 0，所以取大的那份）；Codex 给的是累计总量，直接替换
                if let byMessage = chunk.usageByMessage, !byMessage.isEmpty {
                    claudeUsage.merge(byMessage) { old, new in new.total >= old.total ? new : old }
                    usage = claudeUsage.values.reduce(TokenUsage(), +)
                }
                if let total = chunk.usageTotal { usage = total }
                // 没有新内容了。切到了新的分段文件时 offset 可能变小，那不算读完，接着读
                if chunk.offset <= from && source == fromSource { return }
            } catch {
                if gen == generation { transcriptError = error.localizedDescription }
                return
            }
        }
    }

    /// 会话最近 30 分钟内还有更新，才值得每 2 秒去看有没有新内容；
    /// 早就结束的会话不再轮询（虚拟机里的会话每次轮询都要进一趟虚拟机）
    func isRecentlyActive(_ session: SessionSummary) -> Bool {
        let parser = ISO8601DateFormatter()
        parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let updated = parser.date(from: session.updatedAt) else { return true }
        return Date().timeIntervalSince(updated) < 30 * 60
    }

    private func query(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? value
    }
}
