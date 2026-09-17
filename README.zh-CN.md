# AgentKit

[English](README.md) · **简体中文（中国）** · [正體中文（臺灣）](README.zh-TW.md)

用 Swift 构建 AI 智能体，集成工具编排、明确的权限控制和持久化的对话状态。

## 适用场景

让助手通过应用中的工具执行操作，而不只是生成文本。AgentKit 负责模型与工具之间的循环、审批和对话状态；
应用负责界面、凭据、存储和业务能力。

## 安装

需要 **macOS 15+ 或 iOS 18+**，以及 **Swift 6.2+** 工具链。

添加包依赖：

```swift
.package(url: "https://github.com/AkinoKaede/AgentKit.git", from: "0.13.2")
```

然后将核心产品添加到目标：

```swift
.product(name: "AgentKit", package: "AgentKit")
```

`AgentKit` 目标不依赖第三方库。可选产品 `AgentKitScrubber` 提供基于 ScrubberKit 的网页客户端，
不会让核心目标依赖 WebKit。

## 使用方式

以下示例使用 Responses 端点，仅启用当前对话的私有暂存区工具。
在异步上下文中调用它，从应用的凭据存储中提供 API 密钥，并传入 `manualApproval` 闭包：
由闭包展示审批界面，返回 `.allow` 或 `.deny(reason)`。

```swift
import AgentKit
import Foundation

func runAgent(
    conversationID: UUID,
    prompt: String,
    apiKey: String,
    manualApproval: @escaping AgentApprovalBroker.ManualApproval
) async {
    let provider = ModelProvider(
        name: "OpenAI",
        apiFormat: .responses,
        inferenceURL: "https://api.openai.com/v1/responses",
        baseURL: "https://api.openai.com/v1"
    )
    let model = AIModel(id: "gpt-4.1-mini", abilities: [.toolCall])
    let workspace = AgentScratchWorkspace(
        conversationID: conversationID,
        applicationName: "MyApp"
    )
    let runtime = AgentRuntime(
        model: AgentProviderClient(provider: provider, model: model, secret: apiKey),
        registry: AgentToolCatalog.registry(
            builtIn: AgentBuiltInToolConfiguration(
                groups: [.scratch],
                workspace: workspace
            )
        ),
        approval: AgentApprovalBroker(reviewer: nil, manualApproval: manualApproval)
    )
    let request = AgentRunRequest(
        conversationID: conversationID,
        prompt: prompt,
        authoredPrompt: prompt,
        permissionMode: .askForApproval
    )

    for await event in await runtime.start(request) {
        switch event {
        case .messageFinished(let message):
            print(message.text)
        case .toolFinished(let invocation, let result):
            print("\(invocation.call.name): \(result.isError ? "failed" : "finished")")
        case .failed(let reason):
            print("Run failed: \(reason)")
        default:
            break
        }
    }
}
```

暂存区操作仅发生在应用自有存储中，因此已预先批准；添加策略为 `.ask` 的工具后，才会调用审批回调。
未提供 Guardian 审查器不影响 `.askForApproval`，但在 `.approveForMe` 模式下，这类调用会被拒绝执行。

接入应用时还需要注意：

- **每次运行创建一个 runtime。** `start(_:)` 返回仅供一个消费者读取的 `AsyncStream<AgentEvent>`。
  运行期间保留 runtime，以便界面调用 `steer(_:)` 或 `cancel()`。
- **继续对话。** 复用 `conversationID` 并传入 `priorMessages`；runtime 不会自动加载历史记录。
  如果对话经过上下文压缩，使用恢复后的 `modelTranscript`。需要持久化时，提供实现
  `AgentRunPersisting` 的存储库；默认实现仅保存在内存中。
- **渲染流式输出。** 使用 `.messageDelta` 和 `.reasoningDelta` 更新界面；收到
  `.modelRetryScheduled` 时，丢弃对应消息的临时输出，以 `.messageFinished` 为最终结果。
  示例仅打印已完成的消息。
- **单独接入用户交互。** `.userInteraction` 只负责注册工具；需要通过 runtime 的
  `userInteraction:` 参数传入 `AgentUserInteractionHandling` 来接入界面。
  若要让审批和审查事件进入同一事件流，给 runtime 传入共享的 `AgentEventChannel`，
  并将其 `emit` 回调传给 broker 的 `event:` 参数。
- **区分用户意图与上下文。** `authoredPrompt` 是用户原始输入，`prompt` 可以包含应用补充的上下文。
  `authorizationEvidence` 只能包含直接来自用户的授权证据。编写自定义系统提示词时，应包含
  `AgentSystemPrompt.default`。

## 架构

`AgentRuntime` 是协调器，而不是把模型适配和工具实现集中在一起的庞大组件。
它管理一次运行的任务、对话快照、引导消息队列和事件通道，将各阶段委托给可以独立测试的组件。

### 一次运行如何进行

1. **确定可用能力。** 按运行模式（`.planning`、`.acting` 或 `.reviewing`）筛选 `AgentToolRegistry`。
   模型与执行器使用同一组已解析的工具。
2. **准备模型输入。** `AgentContextPipeline` 构造面向模型的对话记录，重放已冻结的上下文与输出投影，
   修复工具消息顺序，但不裁剪展示给用户的历史记录。
3. **流式生成一轮回复。** `AgentTurnDriver` 调用 `AgentModelStreaming`，组装助手消息和工具调用，
   并通过 `AgentEventChannel` 发布进度。
4. **规划工具批次。** `AgentToolExecutor` 验证参数并执行本地预检；`AgentToolScheduler` 根据结果，
   选择串行或限制并发数的并行执行。
5. **授权并执行。** 每个准备就绪的调用依次经过 `willExecute`、审批关卡、工具执行和 `didExecute`。
   钩子可以阻止调用，但不能绕过授权。
6. **记录并继续。** 按模型原始调用顺序追加工具结果，通过 `AgentRunPersisting` 保存快照，
   在下一次模型请求的边界投递排队的引导消息，然后再次请求模型。没有工具调用和待投递引导消息时结束；
   钩子、错误或取消也可以终止运行。

### 源码结构

核心目录在同一个 SPM 目标中划分职责；`AgentKitScrubber` 是独立的可选产品。

| 目录 | 职责 | 主要类型 |
| --- | --- | --- |
| [`Core`](Sources/AgentKit/Core) | 共享消息、事件、运行请求、技能和记忆数据类型 | `AgentTranscriptMessage`、`AgentEvent`、`AgentRunRequest`、`AgentSkill`、`AgentMemoryState` |
| [`Runtime`](Sources/AgentKit/Runtime) | 运行生命周期、流式生成、调度、上下文投影、压缩和持久化接口 | `AgentRuntime`、`AgentTurnDriver`、`AgentToolScheduler`、`AgentToolExecutor`、`AgentContextPipeline` |
| [`Providers`](Sources/AgentKit/Providers) | HTTP/SSE 适配、身份验证、模型发现和能力解析 | `AgentProviderClient`、`ModelProvider`、`AIModel`、`ModelCatalogClient` |
| [`Tools`](Sources/AgentKit/Tools) | 工具接口、注册、参数结构、内置工具和展示数据 | `AgentToolDefinition`、`AnyAgentTool`、`AgentToolCatalog`、`AgentToolServices`、`AgentToolDetail` |
| [`Security`](Sources/AgentKit/Security) | 本地审批策略、Guardian 审查、秘密句柄和敏感信息脱敏 | `AgentApprovalBroker`、`GuardianClient`、`GuardianSessionStore`、`SecretBroker` |
| [`MCP`](Sources/AgentKit/MCP) | 远程服务器配置和协议客户端；由 `Tools/MCP` 适配到工具注册表 | `MCPServer`、`MCPClient`、`AgentMCPTools` |
| [`Services`](Sources/AgentKit/Services) | 由宿主调用、位于主循环之外且不使用工具的功能 | `ConversationTitleService`、`AgentMemoryLearningService` |
| [`AgentKitScrubber`](Sources/AgentKitScrubber) | 实现网页抓取和搜索的可选产品 | `ScrubberWebClient` |

### 运行时保障

- **策略在本地确定。** 预检决定每次调用的审批策略和并发方式。模型声明和远程 MCP 注解不能批准调用；
  远程工具的破坏性提示只能让调度更保守，将其改为串行。
- **保守的并发策略。** 只有所有可执行调用都允许并行，且运行配置也允许时，批次才会并行执行。
  一个串行调用就会让整个批次串行执行。工具结果始终按调用顺序写入对话记录。
- **可恢复的对话记录。** 被拒绝或取消的批次仍会为每个工具调用提供结果。崩溃恢复将未回答的调用标记为
  *执行结果未知*，而不是“从未执行”，避免模型重复可能已经完成的操作。
- **重试不会重放工具。** 临时性的模型服务错误最多重试当前请求五次，退避时间分别为 1、2、4、8、16 秒。
  工具只会在流式响应结束后执行。可通过 `AgentLoopConfiguration.modelRetryPolicy` 配置，
  自定义模型通过 `shouldRetry(after:)` 指定哪些错误允许重试。
- **引导不等于强制取消。** `steer(_:)` 将消息加入队列，在下一次模型请求的边界投递。
  等待中的工具可以主动监听插话信号；普通执行中的工具不会被强制停止。
- **区分历史记录与模型上下文。** 冻结的输出投影和宿主主动触发的压缩可减少模型输入，
  无需替换展示历史。主循环不限制轮数或工具调用次数；宿主决定何时调用 `AgentCompactionService`
  并持久化压缩记录。

## 内置工具

通过 `AgentBuiltInToolConfiguration.groups` 选择工具组，默认值为 `.all`。
每个工具仅在依赖可用时注册；选择工具组不会自动创建所需服务。

| 工具组 | 工具 | 依赖 |
| --- | --- | --- |
| `.scratch` | `scratch_list`、`scratch_read`、`scratch_search`、`scratch_write`、`scratch_replace`、`scratch_copy`、`scratch_move`、`scratch_diff`、`scratch_delete` | `workspace: AgentScratchWorkspace` |
| `.web` | `fetch`、`web_search`、`scratch_fetch` | 抓取需要 `web: AgentWebFetching`；搜索需要 `search: AgentWebSearching`；`scratch_fetch` 还需要 `.scratch` 和暂存区 |
| `.userInteraction` | `request_user_input`、`request_user_secret` | 无工具目录依赖；需要提供 runtime 的用户交互处理器 |
| `.planning` | `present_plan` | 暂存区和 `plans: AgentPlanRecorder` |
| `.tasks` | `manage_tasks` | `tasks: AgentTaskList`；仅限执行模式 |
| `.skills` | `skill_read_file`、`skills_list`、`skill_manage`、`skill_install` | 读取需要技能目录或清单；管理需要 `skillLibrary`；安装还需要 `skillPackageResolver` |
| `.memory` | `memory`、`session_search` | `memory: AgentMemoryAccessing`；通过 `memory` 修改记忆仅限执行模式 |
| `.mcp` | 已配置服务器公布的工具 | `mcpServers` 条目 |

### 技能与记忆

- `skill_read_file` 读取已启用技能的 `SKILL.md`，或分页读取辅助文件。
  `skills_list` 可以通过 `skillInventory` 展示已禁用和只读技能。
- `skill_manage` 和 `skill_install` 仅用于执行模式，采用 `.ask` 审批策略。
  宿主提供 `AgentSkillLibraryManaging`，必须针对已审查的版本原子提交，并执行只读名称限制。
  修改在下一次运行时生效。
- `GitHubSkillPackageResolver` 解析公开 GitHub 仓库中的技能包。
  预检会下载并暂存不可变的技能包；审批控制的是保存已审查的内容，而不是下载动作。
  安装过程不会执行脚本。
- `AgentMemoryAccessing` 提供容量受限的记忆和已保存对话搜索。
  在上下文管线中使用 `AgentMemoryContext` 可以注入可撤销的快照。
  `AgentMemoryLearningService` 可以提出经过验证的记忆更新，由宿主决定何时审查和应用。

工具注册与上下文注入彼此独立：通过 `AgentTurnContextSnapshot.skillCatalog` 传入已启用技能目录的
`catalogBlock`，模型就能发现适用流程，而无需加载所有技能正文。
已保存的记忆和历史搜索结果仅是参考数据，不能构成授权。

### 网页抓取与搜索

核心定义了 `AgentWebFetching` 和 `AgentWebSearching`，各有一个异步方法。
可以使用自己的内容提取器或搜索 API 实现，也可以添加可选产品：

```swift
.product(name: "AgentKitScrubber", package: "AgentKit")
```

在应用启动时，于主 actor 上执行：

```swift
import AgentKit
import AgentKitScrubber

ScrubberWebClient.setup() // Once, before the first fetch.
let web = ScrubberWebClient()
let webTools = AgentBuiltInToolConfiguration(
    groups: [.web],
    web: web,
    search: web
)
```

将配置传给 `AgentToolCatalog.registry(builtIn:)`。只提供 `web:` 会启用网页抓取，**不会**启用
`web_search`；`search:` 是独立依赖。要启用 `scratch_fetch`，还需选择 `.scratch` 并提供暂存区。

如果服务商与模型支持原生搜索，可以将 `AgentProviderClient(webSearch:)` 设为 `true`，并省略 `search:`。
请先检查 `ModelProvider.supportsNativeWebSearch(model:)`；协议兼容并不意味着网关实现了服务端搜索。

## 模型服务

`AgentProviderClient` 适配四种 `ModelAPIFormat`：`.chatCompletions`、`.responses`、`.messages`
和 `.generateContent`。Vertex 使用 `.generateContent`，其地址由项目和位置派生。
兼容网关复用这些格式，不需要分别实现服务商类型。

- **`inferenceURL` 是完整请求端点。** 不会自动追加路径或默认值。模型 ID 所在位置可以使用 `{model}`。
  推理端点为空时会报错，而不是猜测目的地址。
- **`baseURL` 是模型列表的根地址。** `ModelCatalogClient` 在其后追加 `/models`；没有列表接口时留空。
  两个地址都由调用方提供，不依赖路径推断。
- **凭据与配置分离。** `credentialRef` 是宿主用于查找凭据的标识，不是秘密本身。
  读取凭据后通过 `secret:` 传入。无需身份验证的端点使用 `secret: ""`，不会发送空的身份验证请求头。
  Vertex 服务账号身份验证仍然需要凭据。
- **明确声明能力。** 模型列表缺少信息时，通过 `AIModel.abilities` 和 `ModelCapabilityResolver`
  描述工具调用、推理、结构化输出和原生搜索能力。

实时与缓冲响应共享按请求创建的解析器和 SSE 帧处理。要完整替换服务商适配层，实现 `AgentModelStreaming`；
`AgentModelCompleting` 则服务于不使用工具、但需要完整响应的功能。
结构化输出通过 `AgentModelOutputFormat` 传递，当模型声明 `.structuredOutput` 时映射到所选协议。

## 审批与信任边界

审批策略属于具体调用，由本地确定：

| 策略 | 行为 |
| --- | --- |
| `.deny` | 在所有权限模式下拒绝 |
| `.approve` | 无需额外审批即可运行 |
| `.ask` | 交由下表中的运行权限模式处理 |

| 权限模式 | `.ask` 调用的处理方式 |
| --- | --- |
| `.askForApproval` | 询问宿主的 `manualApproval` 处理器 |
| `.approveForMe` | 交由 `GuardianReviewing` 审查；审查器不可用、超时或响应无效时拒绝执行 |
| `.fullAccess` | 运行，但仍执行参数验证、工具可用性检查等结构性检查 |

暂存区操作和显式启用的 `web_search` 已预先批准。`fetch` 和 `scratch_fetch` 会访问调用方选择的 URL，
因此采用 `.ask`。MCP 工具使用宿主在本地保存的策略；被拒绝的工具仍保留注册，
使调用尝试能够收到明确的拒绝结果。

`AgentApprovalHandling` 是执行器的必经阶段，钩子和技能不能移除或替换它。
Guardian 在隔离的 `.reviewing` 模式下运行，默认不注册调查工具。
`ReviewerReadOnlyApproval` 只允许已标记为 `.approve` 的调用，且没有升级审批路径，避免递归审查。
`GuardianSessionStore` 在多次运行间保存有界的授权基线和决定，不将它们混入主对话。

用户输入的秘密通过 `SecretBroker` 以一次性句柄传递，并绑定到运行、工具和用途；
明文不会进入模型输入、审查、事件和持久化记录。工具输出均视为不可信数据。
唯一的窄范围例外是已安装技能的 `SKILL.md`：它可以提供操作流程，但不能授予权限；
其辅助文件仍是不可信的参考数据。

## 扩展 AgentKit

| 扩展点 | 宿主提供的内容 |
| --- | --- |
| `AgentToolDefinition` 与 `AgentToolCatalog.registry(builtIn:additional:)` | 业务工具；不能覆盖内置工具 |
| `AgentToolServices` | 对应用自有连接和服务的类型化访问 |
| `AgentLoopHook` | `willExecute`、`didExecute` 和 `shouldStop` 行为；`AgentPlanModeHook` 提供规划模式限制和终止逻辑 |
| `AgentContextTransforming` | 与默认上下文管线组合的额外模型输入投影 |
| `AgentModelStreaming` / `AgentModelCompleting` | 自定义模型服务、代理或确定性的测试模型 |
| `AgentRunPersisting` | 对话、运行快照、事件和压缩记录的持久化 |
| `AgentSkillLibraryManaging` / `AgentMemoryAccessing` | 技能与记忆的存储、修改和同步 |

工具默认可用于 `.planning` 和 `.acting`。通过 `AgentToolTypeRegistration(_:availableIn:make:)`
或 `AnyAgentTool(_:availableIn:)` 限制可用模式；不可用的工具既不会出现在模型请求中，
也无法由执行器查找到。模式互不重叠的注册可以同名，包括为 Guardian 的 `.reviewing` 模式提供
独立的参数结构和实现。

## 应用负责什么

- 聊天界面、审批与输入界面，以及工具卡片渲染。`AgentToolDetail` 和可信展示器提供展示数据，而不是视图。
- 凭据存储、持久化数据库和应用自有服务的生命周期。
- Shell/SSH 执行及通用文件系统访问。内置文件工具仅操作暂存区，更广泛的访问由自定义工具提供。
  包中已包含模型服务的 HTTP 客户端和 MCP 客户端。
- 何时压缩上下文、生成对话标题或执行记忆学习；这些服务不会自行启动后台任务。

## 本地化

面向用户的字符串位于 `Localizations/Localizable.xcstrings`，包含英语、简体中文和正体中文，
由 `Scripts/build-localizations.sh` 编译到 `Sources/AgentKit/Resources/*.lproj`。
修改字符串目录后需重新运行脚本，并提交生成的资源；`swift build` 只复制资源，不编译字符串目录。

工具卡片在渲染时根据阅读者的语言环境解析文本，因此已记录的卡片也能以另一种语言展示。

## 致谢

AgentKit 借鉴并使用了以下项目的思想与成果。这里分别列出设计参考、改编代码和包依赖。

### 设计参考

- **[Pi](https://github.com/badlogic/pi-mono)**：模型流式接口边界（`streamFn`）、调用范围内的工具进度回调
  （`onUpdate`）、保守的批次调度、按轮次边界压缩上下文，以及暂存文件编辑行为。
  这些思想分别以 Swift 实现在 `AgentTurnDriver`、`AgentToolExecutor`、`AgentToolScheduler`、
  `AgentCompactionService` 和 `AgentScratchWorkspace` 中。
- **[pi-plan-mode](https://github.com/narumiruna/pi-extensions/tree/main/packages/pi-plan-mode)**：
  隐藏且带版本的规划约定，以及显式结束规划运行的方式。AgentKit 通过 `AgentPlanContractInjection`
  和 `AgentPlanModeHook` 表达这些设计，而不是在用户审阅计划时挂起运行。
- **[pi-approval-guardian](https://github.com/mics8128/pi-approval-guardian)**：Guardian 策略和失败时拒绝执行的
  审查流程参考，包括先提供完整授权基线，再追加增量证据。AgentKit 将其适配为服务商中立的 Swift 类型，
  并保留由宿主掌握的审批边界。
- **[OpenAI Codex](https://github.com/openai/codex)**：自动审查与数量受限的结构化用户问题的行为参考，
  并非运行时依赖。

### 改编代码

- **[LanguageModelChatUI](https://github.com/Lakr233/LanguageModelChatUI)**，作者 Lakr233：
  `BalancedEmitter` 改编自其 MIT 许可的实现，用于将流式文本调节为有界、有序的更新。

### 可选依赖

- **[ScrubberKit](https://github.com/Lakr233/ScrubberKit)**，作者 Lakr233：
  为 `AgentKitScrubber` 提供 MIT 许可的网页提取与搜索实现。
  `AgentWebDocument` 保留了其“可读 Markdown 与原始文档并存”的数据形式；核心 `AgentKit` 目标不依赖它。

各上游项目保留自己的版权和许可。贡献者、源码与适用声明请参见所链接的仓库。

## 许可证

本仓库采用 [MIT 许可证](./LICENSE)。

SPDX-License-Identifier: [MIT](https://spdx.org/licenses/MIT.html)
