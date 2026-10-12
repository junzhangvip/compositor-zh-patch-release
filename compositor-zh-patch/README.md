# Compositor 简体中文汉化补丁

> **版本：B8 定稿**（2026-10-12）｜目标应用：Compositor **v1.4.10 (build 45)**
> 词条规模：`Localizable.strings` **2810** 条 + `AppKitOverrides.plist` **928** 条
> 覆盖范围：主界面 / 顶栏标签 / 新建画布 / 工具选项 / 检查器 / 图层面板 / 图层效果 /
> 全部滤镜参数面板 / 键盘快捷键面板 / 设置页 / 菜单栏 / 状态栏提示 /
> **各类确认与警告对话框（含插值标题）**

对 macOS 图像编辑器 **Compositor**（v1.4.10）的界面汉化。**无需 Xcode、无需重新编译源码**，
直接对已安装的 `.app` 生效，且不影响应用自身升级。

---

## 一、汉化原理（三层机制）

Compositor 的界面文字来自几条互不相同的路径，本补丁分别覆盖：

### A 层：资源文件 —— 覆盖 SwiftUI `LocalizedStringKey` 字面量
`Text("Layers")`、`"Blend mode"` 这类字面量会构造 `LocalizedStringKey`，渲染时查询
`Bundle.main` 的 `Localizable.strings`。原版无此表，于是回退显示英文原文。放入：

```
/Applications/Compositor.app/Contents/Resources/zh-Hans.lproj/Localizable.strings
```

其中 **key = 英文原文，value = 中文**。本层覆盖绝大多数面板、对话框、提示与菜单标题。

### B 层：运行时引擎 —— 覆盖 enum rawValue / 动态标题
滤镜名（`Gaussian Blur`、`Bloom / Glow`）、混合模式（`Normal`、`Color Burn`…）、
图层菜单（`Add Layer Mask`、`Check for Updates`、`Grid Settings` …）等大量标题来自
**enum 的 rawValue 或运行时拼接的 `String`**，最终经 AppKit 的 `setTitle:` / `setLabel:`
等入口流出，**不查本地化表**。本补丁用 `libCompositorZH.dylib` swizzle 这些入口，查
`AppKitOverrides.plist` 完成翻译。

- **混合模式特殊处理**：`BlendModePicker` 会用 `LayerBlendMode(rawValue: item.title)`
  回读 `title` 解析枚举，因此这些项的 `title` 保持英文原文，仅用 `attributedTitle`
  显示中文——绘制显示中文，回读仍是英文，功能零影响。
- **大小写兜底**：应用渲染时常用**小写**效果名（如 `blur`、`glow`），而查表区分大小写会漏翻。
  引擎做**大小写不敏感**匹配（先精确、未命中再按小写），资源表也一并补充了全部小写变体。
- **窗口/标签标题**：`Untitled` 等经 `NSWindow.setTitle:` 流出，引擎同样拦截翻译。
- **对话框文案（B8 新增）**：`NSAlert` 的 `messageText` / `informativeText` 走
  `NSTextField.setText`，按钮走 `NSButton.setTitle:`，均在 B 层拦截范围内。其中标题常含
  `\(文件名)` 插值（运行时才拼成完整句），无法预先入典，引擎为此增加了**前缀/后缀模式规则**：

  | 运行时原文 | 译文 |
  |---|---|
  | `Save changes to X?` | `要保存对 X 的更改吗？` |
  | `“X” was changed on disk.` | `“X”已在磁盘上被更改。` |
  | `A new version of X is available!` | `X 有新版本可用！` |

  > 已知外观副作用：更新提示弹窗源码里用 `stringValue == alert.messageText` 定位标题做
  > 像素级图标对齐；标题被翻译后该处匹配不到，会退回系统标准布局（仅图标位置略有差异，
  > 不影响功能）。

### C 层：CoreText 行排版拦截 —— 覆盖 SwiftUI `Text(变量)` 标签（B5 新增，核心）
新建画布面板里的 `Width / Height / Pixels / Scale / Transparent canvas`、头部标签 `Untitled`、
状态栏工具提示（`Drag to move · Handles to resize · …`）等，源码里是 `Text(title)`
（`title` 为 `String` 变量）或 `"\(rawValue) canvas"` 这类**插值拼接**——它们是逐字
（verbatim）渲染，**既不查 `.strings` 资源表，也不经任何 AppKit 文本出口**，因此 A/B
两层都够不到。

经逐层逆向验证（排除 `.strings` 查询、`NSTextField/NSTextView`、`NSAttributedString`
ObjC 初始化与绘制入口后确认）：SwiftUI 的 `Text(变量)` 在 macOS 上的可见文本唯一汇聚点
是 CoreText 的 **`CTLineCreateWithAttributedString`**。本补丁在 C 层拦截它：

- 用**静态 `__DATA,__interpose` 段**安装替换（在 dyld 绑定阶段生效，对 chained fixups
  的系统框架同样有效；`dyld_dynamic_interpose` 在 `__DATA_CONST` 环境不生效，
  fishhook 因共享缓存 chained fixups 无 indirect symbol table 也不可用）；
- 用 **`LC_SYMTAB` 符号表直查**拿到未被 interpose 污染的原始 `CFAttributedStringCreate`
  与 `CTLineCreateWithAttributedString` 地址（`dlsym` 会返回替换函数导致递归）；
- 仅当「整段字符串恰好等于某个词条」（或 `Untitled N` 序号变体）时，以原属性重建
  翻译后的 attributed string 再排版（**字典门控**），否则原样透传；
- 只改渲染层，**不动逻辑值**——混合模式枚举回读、状态判断仍是英文原值，零副作用；
- 线程安全：`_Thread_local` 重入护栏（文本排版可能发生在任意线程）。

> 已知局限：画布上用户输入的文本若恰好等于某个词条（如混合模式名 "Multiply"），
> 显示层也会被翻译（底层数据与导出不受影响）。

> 实测：`Width→宽度 / Height→高度 / Pixels→像素 / Scale→缩放 /
> Transparent canvas→透明画布 / Untitled→未命名`、状态栏 26 条工具提示全部命中；
> `White canvas / Black canvas` 走同一机制（已入字典），切换背景即生效。

### 为什么不影响升级
- 应用升级会整体替换 `.app`，汉化随之消失——**重跑一次 `install.sh` 即可**重新生效；
- 升级流程本身不被任何改动阻挡（只在 bundle 内新增资源与一条 dylib 加载命令）；
- 卸载（`uninstall.sh`）会从首次备份还原**原始未改动二进制**，可完全回退到英文原版。

---

## 二、安装方法

```sh
cd compositor-zh-patch
./install.sh
```

脚本自动完成：检查环境 → 备份原始应用 → 写入 `zh-Hans.lproj` / `zh_CN.lproj`
→ 安装 `libCompositorZH.dylib` → 注入 `LC_LOAD_DYLIB` → ad-hoc 重签名 → 校验。

> 支持传入自定义路径测试：`./install.sh /path/to/Compositor.app`

### 前置条件
1. **退出 Compositor**（⌘Q）
2. 系统语言为简体中文：`系统设置 › 语言与地区`，把「简体中文」置于首位
3. 首次运行若提示“已损坏”，见下方「签名说明」

### 签名说明
注入 dylib 会破坏原有签名，脚本用 **ad-hoc 签名**重新签署。应用会失去原开发者签名
（Team ID 不再显示），但功能完全不受影响，也不影响 Sparkle 自动更新。

---

## 三、卸载方法

```sh
./uninstall.sh
```

移除两个 `.lproj` 目录与 dylib，并从备份还原原始二进制，恢复英文界面。备份不会被删除。

---

## 四、升级应用后

1. 正常升级 Compositor（Sparkle 或手动覆盖安装）
2. 重跑 `./install.sh`

备份目录：`~/Library/Application Support/Compositor-zh-backup/Compositor.app`

---

## 五、调试（可选）

启动前设置环境变量可输出汉化日志到 `/tmp/compositor_zh_dylib.log`：

```sh
COMPOSITOR_ZH_DEBUG=1 /Applications/Compositor.app/Contents/MacOS/Compositor
```

日志示例：`[CompositorZH] ctLine "Width" -> "宽度"`（C 层 CoreText）、
`[CompositorZH] menuItem "Gaussian Blur" -> "高斯模糊"`（B 层）等。

---

## 六、文件说明

| 文件 | 说明 |
|---|---|
| `install.sh` | 安装脚本（资源 + dylib 注入 + 备份还原） |
| `uninstall.sh` | 卸载脚本（从备份还原原始二进制） |
| `inject_dylib.py` | Mach-O `LC_LOAD_DYLIB` 注入器（覆写零填充区，不位移节） |
| `libCompositorZH.dylib` | 运行时汉化引擎（arm64，B8：A/B/C 三层 + CoreText interpose + 大小写不敏感 + 对话框插值模式） |
| `CompositorZH.m` | dylib 源码（Objective-C，随补丁提供，便于复现/审计） |
| `zh-Hans.lproj/Localizable.strings` | 主汉化表（**2810** 条，SwiftUI 字面量，含小写/格式变体） |
| `zh-Hans.lproj/AppKitOverrides.plist` | AppKit/CoreText 运行时翻译字典（**928** 条，含快捷键/滤镜参数/检查器/状态栏提示/对话框） |
| `zh_CN.lproj/*` | 兼容旧式语言目录名，内容相同 |

术语统一采用 Adobe Photoshop 中文版通行译法（图层、蒙版、选区、色阶、曲线、
正片叠底、滤色、柔光……），便于有 Photoshop 使用经验的用户直接上手。

---

## 七、覆盖范围核对表（B8）

| 界面区域 | 来源文件 | 状态 |
|---|---|---|
| 主界面顶栏 / 底部状态栏 | `ContentView.swift` | ✅ 三层覆盖（含 26 条随工具切换的长提示） |
| 新建画布面板（宽度/高度/像素/画布色） | `NewCanvasSheet.swift` | ✅ C 层 verbatim |
| 键盘快捷键面板（菜单/工具/文本编辑全部条目） | `KeyboardShortcuts.swift` | ✅ 含方向、数字等插值展开变体 |
| 滤镜参数面板（全部滤镜，含扫描线等） | `FilterSheet.swift` | ✅ 含长段说明文字 |
| 图层效果 / 检查器 / 工具选项 | `EffectsSheet.swift`、`*Controls.swift` | ✅ |
| 导出 / 图像大小 / 画布大小 / 网格设置等对话框 | `ExportAsSheet.swift` 等 | ✅ |
| 顶栏菜单与菜单栏条目 | `CompositorApp.swift` | ✅ 含 `…` 省略号变体 |
| 确认/警告对话框（保存、蒙版删除、外部改动、更新） | `ProjectController*.swift`、`LiveLayerMask.swift`、`UpdateDriver.swift` | ✅ 含插值标题（模式规则） |

> 未能覆盖：源码中**运行时插值拼接**的整句（如 `Close \(tab.title)`、`Current: \(w) × \(h) pixels`），
> 因运行时字符串不可预知，无法进入精确匹配词典。若发现此类残留，可按同样方式逐条补充。
