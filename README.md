# Compositor 简体中文汉化补丁

macOS 图像编辑器 **Compositor**（v1.4.10）的界面汉化补丁。**无需 Xcode、无需重新编译
源码**，直接对已安装的 `.app` 生效，且不影响应用自身升级。

## 快速开始

```sh
cd compositor-zh-patch
./install.sh          # 安装（需先退出 Compositor）
./uninstall.sh        # 卸载，恢复英文原版
```

也可以直接下载发布包 `compositor-zh-patch-v1.4.10-B8.zip`，解压后执行上面的脚本。

## 汉化范围

主界面 / 顶栏标签 / 新建画布 / 工具选项 / 检查器 / 图层面板 / 图层效果 /
全部滤镜参数面板 / 键盘快捷键面板 / 设置页 / 菜单栏 / 状态栏提示 /
各类确认与警告对话框（含插值标题）。

- `Localizable.strings` **2810** 条
- `AppKitOverrides.plist` **928** 条

## 实现机制（三层）

| 层 | 手段 | 覆盖对象 |
|---|---|---|
| A | `zh-Hans.lproj/Localizable.strings` | SwiftUI `Text("字面量")` 本地化查表 |
| B | dylib swizzle AppKit 文本出口（`NSMenuItem`/`NSButton`/`NSTextField`/`NSWindow`…） | 枚举 rawValue、动态标题、菜单/按钮/对话框 |
| C | 静态 `__DATA,__interpose` 拦截 CoreText `CTLineCreateWithAttributedString` | SwiftUI `Text(变量)` verbatim 渲染（原函数地址用 `LC_SYMTAB` 直查） |

另有**前缀/后缀模式规则**处理运行时插值整句（如 `Save changes to X?`）。

完整原理、覆盖核对表与已知局限见 [`compositor-zh-patch/README.md`](compositor-zh-patch/README.md)。

## 升级应用后

升级会整体替换 `.app`，重跑一次 `./install.sh` 即可恢复汉化。
备份位于 `~/Library/Application Support/Compositor-zh-backup`。

## 许可证

本项目采用 **MIT License**，见 [LICENSE](LICENSE)。

补丁内的界面词条与资源派生自 **Compositor**（Copyright © 2026 Wonder Assembly LLC，
MIT License），版权归原作者所有，条款原文见 [UPSTREAM-LICENSE](UPSTREAM-LICENSE)。
