#!/bin/sh
# 编译 kkAgent（直接用 swiftc，不依赖 SwiftPM 和 Xcode 工程；第三方库 SwiftTerm 的源码在 Vendor/）
#   scripts/build.sh core   只编译核心  → build/kkagent-core
#   scripts/build.sh app    只编译界面  → build/kkAgent.app
#   scripts/build.sh        两个都编译
set -e
cd "$(dirname "$0")/.."
mkdir -p build

build_core() {
  echo "编译核心…"
  swiftc -O -swift-version 5 Sources/Shared/*.swift Sources/Core/*.swift -o build/kkagent-core
  echo "✓ build/kkagent-core"
}

# 成员详情里的内嵌终端用的第三方库 SwiftTerm（源码在 Vendor/SwiftTerm，说明见那里的 README）。
# 单独编成静态库：它有公开的 Color 等类型，和 App 编进同一个模块会盖掉 SwiftUI 的 Color。
# 编一次要二三十秒，所以缓存能用就不重编。能用的条件：静态库和模块文件都在、没有比静态库新的源文件、
# 「编译参数 + 源文件清单」和上次一样（源文件删了、加了，或者参数改了，都要重编）
build_swiftterm() {
  dir=build/swiftterm
  lib=$dir/libSwiftTerm.a
  flags="-O -wmo -swift-version 5 -parse-as-library -module-name SwiftTerm"
  sources=$(find Vendor/SwiftTerm/Sources -name '*.swift' | sort)
  stamp="$flags $(echo $sources)"
  if [ -f "$lib" ] && [ -f "$dir/SwiftTerm.swiftmodule" ] && [ "$(cat "$dir/stamp" 2>/dev/null)" = "$stamp" ] \
     && [ -z "$(find Vendor/SwiftTerm/Sources -name '*.swift' -newer "$lib" | head -1)" ]; then
    return
  fi
  echo "编译 SwiftTerm（第一次，或者源码、编译参数有变化）…"
  mkdir -p "$dir"
  swiftc $flags -emit-module -emit-module-path "$dir/SwiftTerm.swiftmodule" -emit-library -static -o "$lib" $sources
  printf '%s' "$stamp" > "$dir/stamp"
  echo "✓ $lib"
}

build_app() {
  build_swiftterm
  echo "编译界面…"
  # 界面按功能模块分子目录（Shell/、GroupChat/ …），用 find 把所有 .swift 都收进来。
  # -I / -L / -l 链接 SwiftTerm；-dead_strip 让链接器去掉没用到的代码，减小体积
  swiftc -O -swift-version 5 -parse-as-library Sources/Shared/*.swift $(find Sources/App -name '*.swift') \
    -I build/swiftterm -L build/swiftterm -lSwiftTerm -Xlinker -dead_strip -o build/kkAgentApp
  # 去掉本地调试符号：实测 5.0MB → 2.6MB（-wmo 没有更小，不用）。代价是崩溃日志里少一部分函数名
  strip -x build/kkAgentApp

  # 组装成 .app：Contents/MacOS 放程序，Contents/Info.plist 描述 app，Contents/Resources 放图标
  app=build/kkAgent.app
  rm -rf "$app"
  mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
  mv build/kkAgentApp "$app/Contents/MacOS/kkAgentApp"
  cp Resources/Info.plist "$app/Contents/Info.plist"
  cp Resources/AppIcon.icns "$app/Contents/Resources/AppIcon.icns"
  cp Vendor/SwiftTerm/LICENSE "$app/Contents/Resources/SwiftTerm-LICENSE.txt" # 第三方库的 MIT 许可要随 App 一起分发
  codesign --force --sign - "$app" >/dev/null 2>&1 # 本机用的临时签名
  echo "✓ $app"
}

case "${1:-all}" in
  core) build_core ;;
  app)  build_app ;;
  all)  build_core; build_app ;;
  *)    echo "用法：scripts/build.sh [core|app]"; exit 1 ;;
esac
