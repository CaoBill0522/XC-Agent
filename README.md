# XC-Agent

一个基于 Flutter 的多模型 AI 聊天客户端，界面使用 [flutter_miuix](https://pub.dev/packages/flutter_miuix)（HyperOS 风格）。
自己填 API Key，支持 OpenAI / Anthropic 两种格式和各家中转站，可以让多个模型同时回答，或者按顺序接力分析同一个问题。

- 平台：iOS / Android / macOS / Windows（手机单栏，平板和桌面自动切换为侧边栏 + 内容双栏）
- 包名：`cn.oxoz.agent`
- 数据只保存在本机：对话在本地 SQLite，API Key 在系统钥匙串（Keychain / Keystore / DPAPI），不经过任何第三方服务器

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

### 聊天

- 流式输出；停止、重新生成、编辑后重发、删除；推理过程可折叠；显示 token 用量
- **追问**：长按选中回答里的文字，菜单里有
  - 「追问」：选中内容作为引用显示在输入框上方，接着输入问题即可
  - 「新对话追问」：用回答这段内容的同一个 Agent 新建「追问：xxx」对话，并由它把前面的对话总结成背景，和引用一起放在输入框上方
- **识图**：相册 / 拍照（手机），文件选择 / 拖拽 / 粘贴（桌面），大图自动压缩
- **生图**：`dall-e` / `gpt-image` / `cogview` / `grok-*-image` 等走 `/images/generations`（gpt-image 带参考图时走 `/images/edits`）；对话模型直接返回的图片也会显示，可保存到相册
- **联网搜索**：使用厂商原生能力
  - OpenAI / xAI：Responses 接口的 `web_search` 工具；用 Chat Completions 接入的中转站，开启联网时自动改走同一地址的 Responses 接口，中转站不支持时退回普通对话并提示
  - Anthropic：服务端 `web_search` 工具
  - 智谱：`tools.web_search`
  - DeepSeek：开启联网时自动改走官方的 Anthropic 兼容接口（服务端 `web_search`）
  - 回答下方以标签显示来源（最多两行，其余点「⋯」查看），点开在应用内浏览器打开
- **Markdown**：代码块（可复制）、表格、LaTeX（`$...$`）、链接

### 其它

- 外观：跟随系统 / 浅色 / 深色，Monet 动态取色，切换时整套配色平滑过渡
- 动效：基于 miuix Folme 弹簧参数，列表增删、展开收起、页面切换都有过渡；接力步骤展开 / 收起时顶部保持不动
- 数据：渠道、模型、助手配置可导出 / 导入（剪贴板，可选择是否包含 Key）；清空对话
- 新建后什么都没做就离开的空对话会自动删除

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

## 许可证

[MIT](LICENSE)。

`lib/ui/vendor/app_text_field.dart` 改编自 flutter_miuix，仍适用 Apache-2.0 许可证（文件开头注明了来源、SPDX 许可证标识和所做的修改）。
