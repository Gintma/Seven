# Seven 代码结构

## 启动与装配

[Package.swift](../Package.swift) 定义三个目标：原生 macOS 可执行文件 Seven、供滚动配准使用的纯 C 库 ScrollRegistrationCore，以及通过 `@testable import Seven` 验证生产入口的 SevenTests。

[App.swift](../Sources/Seven/App.swift) 是装配根。正式主包在读取首次使用状态前，将旧偏好域复制到空的新域。随后创建 AppDelegate，装配菜单、快捷键与窗口控制器。翻译浮窗在首次显示时建立；设置与历史窗口在首次访问时加载 SwiftUI 视图，关闭后可复用。首次引导与图片冷启动的优先级见[设置与服务草稿](modules/设置与服务草稿.md)。

## 共享数据与系统边界

- [AppUpdater](../Sources/Seven/AppUpdater.swift) 管理更新资格、两项偏好及可用版本状态，使用协议隔离 Sparkle。设置窗与状态菜单读取同一状态。
- [AppDataPaths](../Sources/Seven/AppDataPaths.swift) 管理 Application Support 下的 Seven 数据目录。ECDICT 词库和常规诊断沿用共享目录。开发变体的凭据、翻译历史和收藏夹使用 `Seven-<name>` 目录。用户偏好存于当前应用域。
- [FileCredentialStore](../Sources/Seven/FileCredentialStore.swift) 按服务实例 ID 在本地 credentials.json 分槽，目录权限 0700、文件及锁文件 0600。通过文件锁与原子替换协调跨进程更新。测试注入凭据存储或临时目录。
- [HistoryStore](../Sources/Seven/HistoryStore.swift) 分别按需加载历史和收藏夹，由 [HistoryArchive](../Sources/Seven/HistoryArchive.swift) 独立管理原子写入、损坏归档与恢复。关闭历史窗口后保留视图选择和搜索条件，释放已落盘的超预算快照，保留写入失败的快照供下次写入重试。
- [InterfaceLocalization](../Sources/Seven/InterfaceLocalization.swift) 负责界面语言选择和资源解析。工程流程、本地化和诊断数据边界见[根规则](../AGENTS.md)。

## 线程与任务所有权

[AppDelegate](../Sources/Seven/App.swift) 在主 actor 管理 AppKit 窗口、截取入口和会话所有权；[TranslationModel](../Sources/Seven/TranslationModel.swift) 在主 actor 管理翻译状态、代次及服务任务。两组扩展按职责拆文件，写状态仍通过所属类型的操作入口。

网络请求、系统捕获和识别可能在取消后返回。把结果交给 UI 前核对所属会话或代次。系统窗口与视图操作留在主 actor；系统服务、凭据和网络边界优先复用现有协议，以便测试替换依赖。

## 任务地图

| 要跟踪的路径 | 所属模块 |
|---|---|
| 输入或划词 → 请求、卡片、历史；外部编辑框 → 安全写回 | [翻译与原地替换](modules/翻译与原地替换.md) |
| 首次引导 → 权限；设置导航 → 草稿与离开确认 | [设置与服务草稿](modules/设置与服务草稿.md) |
| 冻结画面 → 选区、标注、钉图与输出 | [截图与钉图](modules/截图与钉图.md) |
| 滚动视口 → 配准、取消与编辑 | [长截图](modules/长截图.md) |
| 菜单、Finder、剪贴板 → 编辑或 OCR 结果 | [OCR 与图片输入](modules/OCR与图片输入.md) |

跨模块的颜色、材质、反馈和无障碍约定见[设计规范](Seven设计规范.md)。
