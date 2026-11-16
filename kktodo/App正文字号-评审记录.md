# App 正文字号：评审记录

2026-11-13，对应 coder 申请 kk#2206。结论：代码评审通过。

- AppTextSize 统一定义默认 14、Stepper 范围 12～20、AppStorage 键 appTextSize。主窗口在 RootView 外设置 font environment，没有显式字体的后代跟随变化。
- 显式 caption / callout 等继续覆盖继承字体；内嵌终端走独立字体配置，独立终端窗口没有接入此修饰符。
- 设置新增“显示”页，Stepper 与恢复默认共用同一键，可点击控件使用手指光标。输入框移除显式 body 字体后继承设置。
- 仅三个 App 文件，核心未改；源码 git diff --check 通过。属于低影响显示设置，不另建镜像测试或修改用户偏好。coder 报告 KK 已看过正式 App 效果并要求提交推送；pm 未亲自点击界面，不把此项称为独立真机验收。
- 合并许可和五分钟检查另见《合并协调台账.md》gic59-2206，本记录不授权新增部署动作。
