// 对系统自带 SQLite C 接口的一层薄封装，只提供执行和查询两个动作
import Foundation
import SQLite3

enum SQLValue {
    case int(Int64)
    case text(String)
    case null
}

/// 查询结果的一行，按列名取值
struct Row {
    let values: [String: SQLValue]

    func int(_ column: String) -> Int64 {
        if case .int(let v) = values[column] { return v }
        return 0
    }

    func text(_ column: String) -> String {
        switch values[column] {
        case .text(let v): return v
        case .int(let v): return String(v)
        default: return ""
        }
    }
}

struct SQLiteError: Error, CustomStringConvertible {
    let description: String
}

final class SQLite {
    private var handle: OpaquePointer?
    private let lock = NSLock() // 同一时间只允许一个线程用这个连接

    init(path: String) throws {
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(path, &handle, flags, nil) == SQLITE_OK else {
            throw SQLiteError(description: "打开数据库失败：\(path)")
        }
        sqlite3_busy_timeout(handle, 3000)
    }

    /// 执行不带参数的多条语句（建表、事务控制）
    func exec(_ sql: String) throws {
        lock.lock()
        defer { lock.unlock() }
        var error: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(handle, sql, nil, nil, &error) != SQLITE_OK {
            let message = error.map { String(cString: $0) } ?? "未知错误"
            sqlite3_free(error)
            throw SQLiteError(description: message)
        }
    }

    /// 执行一条写语句，返回新插入行的 id
    @discardableResult
    func run(_ sql: String, _ params: [SQLValue] = []) throws -> Int64 {
        lock.lock()
        defer { lock.unlock() }
        let statement = try prepare(sql, params)
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_DONE else { throw lastError() }
        return sqlite3_last_insert_rowid(handle)
    }

    /// 执行一条更新语句，返回改到了几行（用来做「条件满足才更新」，比如投递进度只进不退）
    func update(_ sql: String, _ params: [SQLValue] = []) throws -> Int {
        lock.lock()
        defer { lock.unlock() }
        let statement = try prepare(sql, params)
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_DONE else { throw lastError() }
        return Int(sqlite3_changes(handle))
    }

    func query(_ sql: String, _ params: [SQLValue] = []) throws -> [Row] {
        lock.lock()
        defer { lock.unlock() }
        let statement = try prepare(sql, params)
        defer { sqlite3_finalize(statement) }
        var rows: [Row] = []
        while true {
            // 只有读到结尾（DONE）才算成功。被锁住（BUSY）、读出错（IOERR）等不能悄悄当成「没有数据」，
            // 否则「查不出来」会被当成「没有」（比如查投递阻挡时，误以为没有阻挡就放行了）
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { break }
            guard result == SQLITE_ROW else { throw lastError() }
            var values: [String: SQLValue] = [:]
            for i in 0..<sqlite3_column_count(statement) {
                let name = String(cString: sqlite3_column_name(statement, i))
                switch sqlite3_column_type(statement, i) {
                case SQLITE_INTEGER: values[name] = .int(sqlite3_column_int64(statement, i))
                case SQLITE_NULL: values[name] = .null
                default: values[name] = .text(String(cString: sqlite3_column_text(statement, i)))
                }
            }
            rows.append(Row(values: values))
        }
        return rows
    }

    private func prepare(_ sql: String, _ params: [SQLValue]) throws -> OpaquePointer? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else { throw lastError() }
        // SQLITE_TRANSIENT：让 SQLite 自己拷一份字符串
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (i, param) in params.enumerated() {
            let index = Int32(i + 1)
            switch param {
            case .int(let v): sqlite3_bind_int64(statement, index, v)
            case .text(let v): sqlite3_bind_text(statement, index, v, -1, transient)
            case .null: sqlite3_bind_null(statement, index)
            }
        }
        return statement
    }

    private func lastError() -> SQLiteError {
        SQLiteError(description: String(cString: sqlite3_errmsg(handle)))
    }
}
