# SwiftTerm（第三方源码）

成员详情里内嵌的终端用的是 [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm)（MIT 许可，见 `LICENSE`）。

- 版本：`v1.20.0`（提交 `5d14406844143538cd8f8851d2d8a67c1fe443e5`，2026-08-18）
- 只放了 macOS 需要的源码：上游 `Sources/SwiftTerm` 下除 `iOS/`、`Documentation.docc/`、`Apple/Metal/Shaders.metal`、`Mac/README.md` 以外的全部 `.swift` 文件，没有改动内容
- `Sources/SwiftTermBuildInfo.swift` 是自己写的：上游由 SwiftPM 插件生成，这里不用 SwiftPM，固定写成上面的版本
- 没带 Metal 着色器：SwiftTerm 默认用 CoreGraphics 绘制（`useMetalRenderer = false`），kkAgent 不开 Metal

## 怎么编译

`mac/scripts/build.sh` 先用 `swiftc` 把这里的源码单独编成静态库 `build/swiftterm/libSwiftTerm.a`（独立模块，源码没变就不重编），App 再链接它。

不和 App 编进同一个模块：SwiftTerm 有公开的 `Color` 等类型，会盖掉 App 里大量使用的 SwiftUI `Color`。

## 怎么升级

1. 拉上游新版本，按上面的规则重新复制源码（先删掉旧的 `Sources/`，保留 `SwiftTermBuildInfo.swift`）
2. 改 `Sources/SwiftTermBuildInfo.swift` 和本文件里的版本号、提交号
3. `scripts/build.sh app` 会发现源码变了，自动重编静态库
