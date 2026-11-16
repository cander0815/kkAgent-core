// SwiftTerm 原本由 SwiftPM 插件在编译时生成这个文件（见上游 Sources/SwiftTermBuildInfoGenerator）。
// kkAgent 不用 SwiftPM，这里固定写成引入的版本。升级 SwiftTerm 时同步改这里（见 ../README.md）。

/// Source-control information for this SwiftTerm build.
public enum SwiftTermBuildInfo {
    public static let branch: String? = nil
    public static let tag: String? = "v1.20.0"
    public static let commit: String? = "5d14406844143538cd8f8851d2d8a67c1fe443e5"
    public static let hasUncommittedChanges: Bool? = false
    public static let version: String = "v1.20.0"
}
