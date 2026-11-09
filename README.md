# XCAgent

[English](#english) · 中文

一个基于 Flutter 的多模型 AI 聊天客户端，界面使用 [flutter_miuix](https://pub.dev/packages/flutter_miuix)（HyperOS 风格）。
自己填 API Key，支持 OpenAI / Anthropic 两种格式和各家中转站，可以让多个模型同时回答，或者按顺序接力分析同一个问题。

- 平台：iOS / Android / macOS / Windows（手机单栏，平板和桌面自动切换为侧边栏 + 内容双栏）
- 包名：`cn.oxoz.agent`
- 界面语言：简体中文 / English（设置里切换，默认跟随系统）；首次打开有功能引导
- 数据默认只保存在本机：对话在本地 SQLite，API Key 在系统钥匙串（Keychain / Keystore / DPAPI），不经过任何第三方服务器；可选 iCloud 同步（存进你自己的 iCloud 云盘）

## 功能

### 接入模型

| 功能 | 说明 |
|---|---|
| 三种接口协议 | OpenAI Chat Completions、OpenAI Responses、Anthropic Messages |
| 厂商预设 | OpenAI、Anthropic、xAI (Grok)、智谱 (GLM)、DeepSeek、自定义 / 中转站（见 `assets/presets/providers.json`） |
| 云端拉取模型 | 填好 Key 后自动拉取 `/models`，按模型名识别能力（识图 / 生图 / 推理 / 联网），可手动修改 |
| 多渠道轮询 | 不同渠道下的同名模型自动合并为一个；路由策略可选轮询 / 加权随机 / 主备；请求失败且还没输出内容时自动换下一个渠道，连续失败 3 次的渠道冷却 60 秒 |
| 助手 | 名称 + 模型 + 系统提示词 + 温度 / 最大输出 / 推理强度 |

### 对话方式

新建对话时在聊天页里选择对话方式，也可以一键「沿用上次」的设置。

| 模式 | 说明 |
|---|---|
| 单模型 | 一个模型回答 |
| 多 Agent 并问 | 同一个问题同时发给多个模型 / 助手。先完成的自动采纳，可以改选；左右滑动卡片切换不同回答，双击采纳；后续对话的上下文只带被采纳的回答 |
| 接力分析 | 按设定顺序依次分析：第 1 步收到原始问题，之后每一步收到「原始问题 + 上一步的结果」，最后一步作为结论。中间某步失败则停止后续步骤；可以从任意一步重新生成 |
| 裁判评分 | 多个模型各自回答，全部完成后由指定的裁判模型逐一点评、打分，并给出「综合答案」作为本轮结论 |
| 辩论 | 两个或多个模型按顺序轮流发言、反驳对方（可设 1~3 轮），最后由总结者梳理各方观点给出结论 |

### 聊天

- 流式输出；停止、重新生成、编辑后重发、删除；推理过程可折叠；显示 token 用量
- **追问**：长按选中回答里的文字，菜单里有
  - 「追问」：选中内容作为引用显示在输入框上方，接着输入问题即可
  - 「新对话追问」：用回答这段内容的同一个 Agent 新建「追问：xxx」对话，并由它把前面的对话总结成背景，和引用一起放在输入框上方
- **对话分支**：从任意一条消息分出一个新对话，换个问法试试，原对话不受影响
- **全局搜索**：搜索所有对话的标题和内容，点结果直接跳到那条消息并高亮
- **提示词库**：常用的提问方式存成提示词，在输入框里打 `/` 调出
- **附件**：PDF 原样发给模型（Claude / OpenAI 原生读 PDF），文本和代码文件（txt、md、csv、json、各种源码等）把内容并入问题
- **识图**：相册 / 拍照（手机），文件选择 / 拖拽 / 粘贴（桌面），大图自动压缩
- **生图**：`dall-e` / `gpt-image` / `cogview` / `grok-*-image` 等走 `/images/generations`（gpt-image 带参考图时走 `/images/edits`）；可选画幅（方形 / 横向 / 纵向）；对话模型直接返回的图片也会显示，可保存到相册
- **语音输入**：输入框空着时按住说话（系统语音识别），松手发送，上滑到「取消」放弃、到「转文字」先放进输入框再改
- **工具调用**：内置读取网页、当前时间、计算器，并可接入远程 MCP 服务器（Streamable HTTP，手机上也能用）；模型调用工具的参数和结果在回答里可展开查看；三种协议都支持，渠道不支持时自动按普通对话回答
- **代码预览**：回答里的 HTML、SVG、Mermaid 代码块可以直接点「预览」渲染
- **联网搜索**：使用厂商原生能力
  - OpenAI / xAI：Responses 接口的 `web_search` 工具；用 Chat Completions 接入的中转站，开启联网时自动改走同一地址的 Responses 接口，中转站不支持时退回普通对话并提示
  - Anthropic：服务端 `web_search` 工具
  - 智谱：`tools.web_search`
  - DeepSeek：开启联网时自动改走官方的 Anthropic 兼容接口（服务端 `web_search`）
  - 回答下方以标签显示来源（最多两行，其余点「⋯」查看），点开在应用内浏览器打开
- **Markdown**：代码块（可复制）、表格、LaTeX（`$...$`）、链接

### 用量与上下文

- **用量统计**：按今天 / 近 7 天 / 近 30 天 / 全部，汇总请求次数和输入、输出 token，按模型、按渠道分别列出
- **上下文管理**：显示下一次请求大约多少 token；可以只携带最近 N 轮；可以把早期对话压缩成摘要（手动，或超过约 24k token 时自动），之后只发送摘要 + 最近两轮原文

### 分享

- 整段对话或单条回答导出为 Markdown 文件、复制为 Markdown，或生成长图保存到相册 / 分享

### 其它

- 外观：跟随系统 / 浅色 / 深色，Monet 动态取色，切换时整套配色平滑过渡
- 动效：基于 miuix Folme 弹簧参数，列表增删、展开收起、页面切换都有过渡；接力步骤展开 / 收起时顶部保持不动
- 数据：渠道、模型、助手配置可导出 / 导入（剪贴板，可选择是否包含 Key）；清空对话
- 新建后什么都没做就离开的空对话会自动删除
- **文件夹**：长按对话「移到文件夹」，首页顶部按文件夹筛选
- **应用锁**：Face ID / 指纹 / 设备密码解锁，可设离开多久后重新锁定；切到后台时遮住内容
- **iCloud 同步**（iPhone / iPad / Mac）：对话、文件夹、渠道、模型、助手、提示词；同一条记录两边都改过时以后改的为准；API Key 可选通过 iCloud 钥匙串同步
- **快捷入口**：主屏图标长按「新对话 / 搜索」；Siri / 快捷指令「问 XCAgent」；系统分享面板把文字或链接发给 XCAgent；主屏 / 锁屏小组件；`xcagent://ask?text=…` 链接；桌面端全局快捷键 ⌥ Space（Windows 为 Alt + Space）

## 开发

需要 Flutter 3.47 及以上。

```bash
flutter pub get
dart run build_runner build   # 修改 lib/data/db/tables.dart 后需要重新生成
flutter analyze
flutter test                  # 单元测试、组件测试、全页面冒烟测试
flutter run
```

### 本地模拟服务

不需要真实 Key 就能体验全部流程。模拟服务的 API Key 是 `sk-test-local`，在 App 里添加「自定义 / 中转站」渠道，地址填 `http://127.0.0.1:8787`。

```bash
python3 tool/mock_server.py 8787             # 正常服务：OpenAI / Anthropic 流式、生图、推理、模拟联网来源
python3 tool/mock_server.py 8787 responses   # 额外支持 /v1/responses（默认像多数中转站一样返回 404）
python3 tool/mock_server.py 8788 fail        # 永远返回 500，用于测试故障切换
flutter test --tags live --run-skipped       # 端到端测试（真实 HTTP + 真实 SQLite）
```

消息里包含 `long` 时返回一段长 Markdown，便于检查排版。

### 构建

```bash
flutter build apk --release
flutter build ios --release
flutter build macos --release
flutter build windows --release   # 需在 Windows 上执行
```

> 首次构建会从 GitHub 下载 SQLite 原生库并校验哈希。GitHub 偶尔返回错误页，导致「Hash of downloaded file … expected …」，重试即可。
>
> iOS 构建前请在 Xcode 里把 Signing 的 Team 改成你自己的。

## 目录结构

```
lib/
  core/
    api/            协议适配器（adapters/）、SSE 解析、渠道端点、对话客户端、错误翻译
    chat/           消息内容块、参与者、对话模式（单模型 / 并问 / 接力）
    models/         按模型名推断能力
    providers/      厂商预设
    routing/        多渠道路由与熔断
  data/
    db/             drift 表结构与迁移
    repositories/   渠道 / 模型 / 助手
    chat_service    发送、流式生成、故障切换、多 Agent 采纳、接力、追问总结
    image_store     聊天图片本地存储与压缩
    config_transfer 配置导入导出
  features/         各页面（chat / channels / models / agents / settings / home / conversations）
  ui/               通用组件、动效、对话框、图片查看、vendor/（改过的 miuix 输入框）
assets/presets/     厂商预设 JSON
tool/mock_server.py 本地模拟服务
test/               单元测试、组件测试、冒烟测试
```

### 关于 `lib/ui/vendor/app_text_field.dart`

复制自 flutter_miuix 1.3.0 的 `MiuixTextField`（Apache-2.0），只增加了 `autocorrect` / `enableSuggestions` 参数。
原组件没有暴露这两个参数，iOS 会把 URL、API Key、模型名等自动纠错（例如把 `gpt` 改成 `got`）。

## English

XCAgent is a multi-model AI chat client built with Flutter, for iOS, Android, macOS and Windows.
Bring your own API keys (OpenAI or Anthropic format, official APIs or relays) and chat with several models at once.

- **Five chat modes**: single model, multi-agent (ask several models, adopt one answer), relay, judge (a judge model scores the answers and writes a combined one) and debate
- **Channels**: one model can rotate across several channels with automatic failover
- **Native web search**, **tool calling** (read web pages, calculator, current time, remote MCP servers over Streamable HTTP), **image generation**, PDFs and code files as attachments
- **Hold to talk** voice input, **code preview** for HTML / SVG / Mermaid, **branches**, **global search**, **prompt library** (type `/`), export to Markdown or a long image
- **Folders**, **app lock** (Face ID / fingerprint), **iCloud sync** across iPhone, iPad and Mac, Siri / Shortcuts, share extension, widgets and a desktop global shortcut
- Your data stays on your device: chats in a local SQLite database, API keys in the system keychain
- The interface is available in Simplified Chinese and English (Settings → Language)

## 许可证

[MIT](LICENSE)。

`lib/ui/vendor/app_text_field.dart` 改编自 flutter_miuix，仍适用 Apache-2.0 许可证（文件开头注明了来源、SPDX 许可证标识和所做的修改）。
