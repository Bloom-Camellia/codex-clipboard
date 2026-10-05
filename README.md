# codex-clipboard

Windows clipboard image-to-path helper for Codex CLI.

在 PowerShell 中运行 Codex CLI 时，用快捷键把剪贴板图片保存为 PNG，再粘贴图片的绝对路径。普通截图默认保持图片。

- **普通粘贴**：Win + Shift + S → Ctrl + V，沿用当前软件原有的图片粘贴行为。
- **粘贴路径**：Win + Shift + S → Ctrl + Q → 保存完成 → Ctrl + V。
- 每张截图单独按 Ctrl + Q 才转换；保存后保留最新 30 张。
- 随 codex 自动启动，多个 CLI 共用一个后台进程，最后一个 CLI 退出后停止。

## 环境

- Windows 桌面会话。
- Windows PowerShell 5.1 或 PowerShell 7；后台使用系统自带的 Windows PowerShell。
- 已安装 Codex CLI，且在终端中可以运行 codex。
- 无需第三方 PowerShell 模块。ClipboardEngine.cs 在后台启动时编译，因此必须随其他文件保留。

## 安装

1. 从 [Releases](https://github.com/Bloom-Camellia/codex-clipboard/releases/latest) 下载 ZIP。
2. 解压到一个固定、可写的目录。
3. 在 PowerShell 中进入解压后的项目目录，运行：

       .\Install.ps1

4. 打开新的 PowerShell 终端或 Windows Terminal 的 PowerShell 标签页，输入：

       codex

安装器接入 Windows PowerShell 和 PowerShell 7 的用户通用 profile。修改现有 profile 前会创建备份，保留原有配置。

当前终端可以手动加载：

    . .\Hook.ps1

安装后不要移动项目目录；profile 会引用其绝对路径。移动后，请在新目录重新运行 Install.ps1。

如果下载文件被 Windows 标记为来自网络，可在确认下载来源后，解除本目录脚本和模块的阻止：

    Get-ChildItem -Path .\*.ps1,.\*.psm1 -File | Unblock-File

若本机执行策略阻止脚本，可仅在当前终端中允许脚本安装并使用；关闭窗口后该设置失效：

    Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass

通过 -NoProfile 启动的终端需要手动加载 Hook.ps1。直接运行 codex.exe 会跳过 codex 包装函数。

## 使用

普通截图不会自动保存到工具目录，也不会清理历史图片。只有按转换快捷键并成功保存后，剪贴板才会变成绝对路径文本。

    Win + Shift + S → Ctrl + Q → Ctrl + V

保存需要短暂处理时间，完成后再粘贴。剪贴板已经是文字、文件列表或转换后的路径时，快捷键不会创建图片或改写内容。

截图默认保存在项目目录下的 screenshots 文件夹。文件夹由工具自动创建。

Ctrl + Q 在 CLI 运行期间是 Windows 全局快捷键，最后一个 CLI 退出后释放。如果其他程序占用同一快捷键，后台启动会失败；可修改快捷键后重新启动 CLI。

## 配置

修改项目目录中的 config.json：

    {
      "retainCount": 30,
      "pollMilliseconds": 60,
      "screenshotDirectory": "screenshots",
      "hotkey": "Ctrl+Q"
    }

| 配置 | 用途 |
| --- | --- |
| retainCount | 保留的截图数量，默认 30 |
| pollMilliseconds | 后台消息处理间隔，单位毫秒 |
| screenshotDirectory | 图片目录，相对路径以项目目录为基准 |
| hotkey | 转换快捷键，默认 Ctrl+Q |

hotkey 支持 Ctrl 与字母或数字的组合，也可以叠加 Alt、Shift、Win，例如 Ctrl+Alt+Q。退出全部 CLI 后重新启动，配置生效。

## 图片保留与失败处理

成功保存第 31 张图片时，删除最早的一张。只清理截图目录顶层符合 codex-shot 固定命名规则的 PNG，不删除其他个人文件或子目录。

旧图被占用时，下次成功保存图片后重试；此时图片数可能暂时超过上限。保存失败会保留剪贴板图片。剪贴板已被新的复制操作更新时，不会用旧图片路径覆盖新内容。

## 状态与卸载

在项目目录运行：

    .\Status.ps1

卸载自动启动：

    .\Uninstall.ps1

默认卸载会移除 profile 接入片段，停止后台并释放快捷键；截图和 profile 备份保留。指定其他 ProfilePaths 时，仅修改指定配置，不停止实际用户后台会话。

后台日志位于 .state\watcher.log。

## 开发与打包

源码仓库包含测试，ZIP 运行包包含运行文件和使用文档。以下构建和测试命令需在源码仓库目录执行。

    .\Build-Release.ps1 -Version v0.1.0

输出位于 dist，包含 ZIP 和 SHA256 校验文件。构建使用固定文件白名单，排除截图、后台状态、日志和测试产物。

运行测试：

    .\tests\Test-All.ps1

测试需要交互式 Windows 桌面，会临时使用系统剪贴板和 Ctrl+Alt+Q。运行结束后尝试恢复原剪贴板；运行期间请暂停复制操作。Test-Installed.ps1 单独验证实际用户 profile 下的 Ctrl+Q。

验证记录见 [VERIFICATION.md](https://github.com/Bloom-Camellia/codex-clipboard/blob/main/VERIFICATION.md)，版本说明见 [CHANGELOG.md](CHANGELOG.md)。

## 许可证

[MIT](LICENSE)
