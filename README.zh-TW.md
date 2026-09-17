# AgentKit

[English](README.md) · [简体中文（中国）](README.zh-CN.md) · **正體中文（臺灣）**

以 Swift 打造 AI 代理，整合工具協調、明確的權限控管與持久保存的對話狀態。

## 適用情境

讓助理透過應用程式中的工具執行操作，而不只是產生文字。AgentKit 負責模型與工具之間的循環、核准與對話狀態；
應用程式負責介面、認證資訊、儲存與領域專屬功能。

## 安裝

需要 **macOS 15+ 或 iOS 18+**，以及 **Swift 6.2+** 工具鏈。

加入套件相依項目：

```swift
.package(url: "https://github.com/AkinoKaede/AgentKit.git", from: "0.13.2")
```

接著將核心產品加入目標：

```swift
.product(name: "AgentKit", package: "AgentKit")
```

`AgentKit` 目標沒有第三方相依項目。選用產品 `AgentKitScrubber` 提供以 ScrubberKit 實作的網頁用戶端，
不會讓核心目標相依於 WebKit。

## 使用方式

以下範例使用 Responses 端點，僅啟用目前對話的私有暫存區工具。
請在非同步情境中呼叫，從應用程式的認證資訊儲存區提供 API 金鑰，並傳入 `manualApproval` 閉包：
由閉包顯示核准介面，回傳 `.allow` 或 `.deny(reason)`。

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

暫存區操作僅限於應用程式自有的儲存空間，因此已預先核准；加入策略為 `.ask` 的工具後，才會呼叫核准回呼。
未提供 Guardian 審查器不影響 `.askForApproval`，但在 `.approveForMe` 模式下，這類呼叫會被拒絕執行。

整合至應用程式時，還需要注意：

- **每次執行建立一個 runtime。** `start(_:)` 回傳僅供單一消費者讀取的 `AsyncStream<AgentEvent>`。
  執行期間保留 runtime，讓介面可以呼叫 `steer(_:)` 或 `cancel()`。
- **接續對話。** 沿用 `conversationID` 並傳入 `priorMessages`；runtime 不會自動載入歷史紀錄。
  若對話經過上下文壓縮，請使用還原後的 `modelTranscript`。需要持久儲存時，提供實作
  `AgentRunPersisting` 的儲存庫；預設實作僅保存在記憶體中。
- **呈現串流輸出。** 使用 `.messageDelta` 與 `.reasoningDelta` 更新介面；收到
  `.modelRetryScheduled` 時，捨棄對應訊息的暫時輸出，並以 `.messageFinished` 為最終結果。
  範例只列印已完成的訊息。
- **另外整合使用者互動。** `.userInteraction` 只負責註冊工具；需要透過 runtime 的
  `userInteraction:` 參數傳入 `AgentUserInteractionHandling` 來整合介面。
  若要讓核准與審查事件進入同一事件串流，請將共用的 `AgentEventChannel` 傳給 runtime，
  並將其 `emit` 回呼傳給 broker 的 `event:` 參數。
- **區分使用者意圖與上下文。** `authoredPrompt` 是使用者的原始輸入，`prompt` 可以包含應用程式補充的上下文。
  `authorizationEvidence` 只能包含直接來自使用者的授權證據。撰寫自訂系統提示詞時，應包含
  `AgentSystemPrompt.default`。

## 架構

`AgentRuntime` 是協調器，而不是把模型介接與工具實作集中在一起的龐大元件。
它管理一次執行的工作、對話快照、引導訊息佇列與事件通道，將各階段委派給可獨立測試的元件。

### 一次執行如何進行

1. **決定可用能力。** 依執行模式（`.planning`、`.acting` 或 `.reviewing`）篩選 `AgentToolRegistry`。
   模型與執行器使用同一組已解析的工具。
2. **準備模型輸入。** `AgentContextPipeline` 建立提供給模型的對話紀錄，重播已凍結的上下文與輸出投影，
   修復工具訊息順序，但不裁剪顯示給使用者的歷史紀錄。
3. **串流產生一輪回覆。** `AgentTurnDriver` 呼叫 `AgentModelStreaming`，組合助理訊息與工具呼叫，
   並透過 `AgentEventChannel` 發布進度。
4. **規劃工具批次。** `AgentToolExecutor` 驗證參數並執行本機預檢；`AgentToolScheduler` 依結果，
   選擇循序執行或限制同時執行數量的平行執行。
5. **授權並執行。** 每個準備就緒的呼叫依序通過 `willExecute`、核准關卡、工具執行與 `didExecute`。
   掛鉤可以阻止呼叫，但不能略過授權。
6. **記錄並繼續。** 依模型原始呼叫順序附加工具結果，透過 `AgentRunPersisting` 保存快照，
   在下一次模型請求的邊界送出佇列中的引導訊息，接著再次請求模型。沒有工具呼叫與待送出的引導訊息時結束；
   掛鉤、錯誤或取消也可以終止執行。

### 原始碼結構

核心目錄在同一個 SPM 目標中劃分職責；`AgentKitScrubber` 是獨立的選用產品。

| 目錄 | 職責 | 主要型別 |
| --- | --- | --- |
| [`Core`](Sources/AgentKit/Core) | 共用訊息、事件、執行請求、技能與記憶資料型別 | `AgentTranscriptMessage`、`AgentEvent`、`AgentRunRequest`、`AgentSkill`、`AgentMemoryState` |
| [`Runtime`](Sources/AgentKit/Runtime) | 執行生命週期、串流生成、排程、上下文投影、壓縮與持久儲存介面 | `AgentRuntime`、`AgentTurnDriver`、`AgentToolScheduler`、`AgentToolExecutor`、`AgentContextPipeline` |
| [`Providers`](Sources/AgentKit/Providers) | HTTP/SSE 介接、身分驗證、模型探索與能力解析 | `AgentProviderClient`、`ModelProvider`、`AIModel`、`ModelCatalogClient` |
| [`Tools`](Sources/AgentKit/Tools) | 工具介面、註冊、參數結構、內建工具與呈現資料 | `AgentToolDefinition`、`AnyAgentTool`、`AgentToolCatalog`、`AgentToolServices`、`AgentToolDetail` |
| [`Security`](Sources/AgentKit/Security) | 本機核准策略、Guardian 審查、機密值控制代碼與敏感資訊遮蔽 | `AgentApprovalBroker`、`GuardianClient`、`GuardianSessionStore`、`SecretBroker` |
| [`MCP`](Sources/AgentKit/MCP) | 遠端伺服器設定與協定用戶端；由 `Tools/MCP` 介接至工具登錄表 | `MCPServer`、`MCPClient`、`AgentMCPTools` |
| [`Services`](Sources/AgentKit/Services) | 由主應用程式呼叫、位於主循環之外且不使用工具的功能 | `ConversationTitleService`、`AgentMemoryLearningService` |
| [`AgentKitScrubber`](Sources/AgentKitScrubber) | 實作網頁擷取與搜尋的選用產品 | `ScrubberWebClient` |

### 執行階段保障

- **策略在本機決定。** 預檢決定每次呼叫的核准策略與並行方式。模型宣告與遠端 MCP 註解不能核准呼叫；
  遠端工具的破壞性提示只能讓排程更保守，改為循序執行。
- **保守的並行策略。** 只有所有可執行呼叫都允許平行執行，且執行設定也允許時，批次才會平行執行。
  只要一個呼叫要求循序執行，整個批次就會循序執行。工具結果一律依呼叫順序寫入對話紀錄。
- **可復原的對話紀錄。** 遭拒絕或取消的批次仍會為每個工具呼叫提供結果。當機復原會將未回答的呼叫標記為
  *執行結果未知*，而不是「從未執行」，避免模型重複可能已完成的操作。
- **重試不會重播工具。** 暫時性的模型服務錯誤最多重試目前請求五次，退避時間分別為 1、2、4、8、16 秒。
  工具只會在串流回應結束後執行。可透過 `AgentLoopConfiguration.modelRetryPolicy` 設定，
  自訂模型則透過 `shouldRetry(after:)` 指定哪些錯誤允許重試。
- **引導不等於強制取消。** `steer(_:)` 將訊息加入佇列，在下一次模型請求的邊界送出。
  等待中的工具可以主動監聽插話訊號；一般執行中的工具不會被強制停止。
- **區分歷史紀錄與模型上下文。** 凍結的輸出投影與主應用程式主動觸發的壓縮可減少模型輸入，
  不必取代顯示用的歷史紀錄。主循環不限制輪數或工具呼叫次數；主應用程式決定何時呼叫
  `AgentCompactionService` 並持久保存壓縮紀錄。

## 內建工具

透過 `AgentBuiltInToolConfiguration.groups` 選擇工具群組，預設值為 `.all`。
各工具僅在相依項目可用時註冊；選擇工具群組不會自動建立所需服務。

| 工具群組 | 工具 | 相依項目 |
| --- | --- | --- |
| `.scratch` | `scratch_list`、`scratch_read`、`scratch_search`、`scratch_write`、`scratch_replace`、`scratch_copy`、`scratch_move`、`scratch_diff`、`scratch_delete` | `workspace: AgentScratchWorkspace` |
| `.web` | `fetch`、`web_search`、`scratch_fetch` | 擷取需要 `web: AgentWebFetching`；搜尋需要 `search: AgentWebSearching`；`scratch_fetch` 還需要 `.scratch` 與暫存區 |
| `.userInteraction` | `request_user_input`、`request_user_secret` | 無工具目錄相依項目；需要提供 runtime 的使用者互動處理器 |
| `.planning` | `present_plan` | 暫存區與 `plans: AgentPlanRecorder` |
| `.tasks` | `manage_tasks` | `tasks: AgentTaskList`；僅限行動模式 |
| `.skills` | `skill_read_file`、`skills_list`、`skill_manage`、`skill_install` | 讀取需要技能目錄或清單；管理需要 `skillLibrary`；安裝還需要 `skillPackageResolver` |
| `.memory` | `memory`、`session_search` | `memory: AgentMemoryAccessing`；透過 `memory` 修改記憶僅限行動模式 |
| `.mcp` | 已設定伺服器公布的工具 | `mcpServers` 項目 |

### 技能與記憶

- `skill_read_file` 讀取已啟用技能的 `SKILL.md`，或分頁讀取輔助檔案。
  `skills_list` 可以透過 `skillInventory` 顯示已停用與唯讀技能。
- `skill_manage` 與 `skill_install` 僅用於行動模式，採用 `.ask` 核准策略。
  主應用程式提供 `AgentSkillLibraryManaging`，必須針對已審查的版本以不可分割的交易提交，並強制遵守唯讀名稱限制。
  變更在下一次執行時生效。
- `GitHubSkillPackageResolver` 解析公開 GitHub 儲存庫中的技能套件。
  預檢會下載並暫存不可變的技能套件；核准控管的是保存已審查的內容，而不是下載動作。
  安裝過程不會執行指令稿。
- `AgentMemoryAccessing` 提供容量受限的記憶與已保存對話搜尋。
  在上下文管線中使用 `AgentMemoryContext` 可以注入可撤銷的快照。
  `AgentMemoryLearningService` 可以提出經過驗證的記憶更新，由主應用程式決定何時審查與套用。

工具註冊與上下文注入彼此獨立：透過 `AgentTurnContextSnapshot.skillCatalog` 傳入已啟用技能目錄的
`catalogBlock`，模型就能探索適用流程，而不必載入所有技能內文。
已保存的記憶與歷史搜尋結果只是參考資料，不能構成授權。

### 網頁擷取與搜尋

核心定義了 `AgentWebFetching` 與 `AgentWebSearching`，各有一個非同步方法。
可以使用自己的內容擷取器或搜尋 API 實作，也可以加入選用產品：

```swift
.product(name: "AgentKitScrubber", package: "AgentKit")
```

應用程式啟動時，在主 actor 上執行：

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

將設定傳給 `AgentToolCatalog.registry(builtIn:)`。只提供 `web:` 會啟用網頁擷取，**不會**啟用
`web_search`；`search:` 是獨立的相依項目。若要啟用 `scratch_fetch`，還需選擇 `.scratch` 並提供暫存區。

若服務供應商與模型支援原生搜尋，可以將 `AgentProviderClient(webSearch:)` 設為 `true`，並省略 `search:`。
請先檢查 `ModelProvider.supportsNativeWebSearch(model:)`；協定相容不代表閘道實作了伺服器端搜尋。

## 模型服務

`AgentProviderClient` 介接四種 `ModelAPIFormat`：`.chatCompletions`、`.responses`、`.messages`
與 `.generateContent`。Vertex 使用 `.generateContent`，其位址由專案與位置衍生。
相容閘道沿用這些格式，不需要分別實作供應商型別。

- **`inferenceURL` 是完整的請求端點。** 不會自動附加路徑或預設值。模型 ID 所在位置可以使用 `{model}`。
  推論端點留白時會回報錯誤，而不是猜測目的位址。
- **`baseURL` 是模型清單的根位址。** `ModelCatalogClient` 會在其後附加 `/models`；沒有清單介面時請留白。
  兩個位址都由呼叫端提供，不依賴路徑推斷。
- **認證資訊與設定分離。** `credentialRef` 是主應用程式用來查找認證資訊的識別值，不是機密值本身。
  讀取認證資訊後透過 `secret:` 傳入。無須身分驗證的端點使用 `secret: ""`，不會送出空白的驗證標頭。
  Vertex 服務帳戶的身分驗證仍然需要認證資訊。
- **明確宣告能力。** 模型清單缺少資訊時，透過 `AIModel.abilities` 與 `ModelCapabilityResolver`
  描述工具呼叫、推理、結構化輸出與原生搜尋能力。

即時與緩衝回應共用依請求建立的剖析器與 SSE 訊框處理。若要完全替換供應商介接層，請實作
`AgentModelStreaming`；`AgentModelCompleting` 則支援不使用工具、但需要完整回應的功能。
結構化輸出透過 `AgentModelOutputFormat` 傳遞，當模型宣告 `.structuredOutput` 時，會對應到所選協定。

## 核准與信任邊界

核准策略屬於個別呼叫，由本機決定：

| 策略 | 行為 |
| --- | --- |
| `.deny` | 在所有權限模式下拒絕 |
| `.approve` | 不必額外核准即可執行 |
| `.ask` | 交由下表的執行權限模式處理 |

| 權限模式 | `.ask` 呼叫的處理方式 |
| --- | --- |
| `.askForApproval` | 詢問主應用程式的 `manualApproval` 處理器 |
| `.approveForMe` | 交由 `GuardianReviewing` 審查；審查器不可用、逾時或回應無效時拒絕執行 |
| `.fullAccess` | 執行，但仍進行參數驗證、工具可用性檢查等結構性檢查 |

暫存區操作與明確啟用的 `web_search` 已預先核准。`fetch` 與 `scratch_fetch` 會存取呼叫端選擇的 URL，
因此採用 `.ask`。MCP 工具使用主應用程式在本機保存的策略；遭拒絕的工具仍保留註冊，
讓呼叫嘗試能收到明確的拒絕結果。

`AgentApprovalHandling` 是執行器的必經階段，掛鉤與技能不能移除或取代它。
Guardian 在隔離的 `.reviewing` 模式下執行，預設不註冊調查工具。
`ReviewerReadOnlyApproval` 只允許已標記為 `.approve` 的呼叫，且沒有升級核准途徑，避免遞迴審查。
`GuardianSessionStore` 在多次執行之間保存有界的授權基準與決定，不會將它們混入主對話。

使用者輸入的機密值透過 `SecretBroker`，以一次性控制代碼傳遞，並繫結至執行個體、工具與用途；
明文不會進入模型輸入、審查、事件與持久儲存紀錄。工具輸出一律視為不可信資料。
唯一的有限例外是已安裝技能的 `SKILL.md`：它可以提供操作流程，但不能授予權限；
輔助檔案仍是不可信的參考資料。

## 擴充 AgentKit

| 擴充點 | 主應用程式提供的內容 |
| --- | --- |
| `AgentToolDefinition` 與 `AgentToolCatalog.registry(builtIn:additional:)` | 領域專屬工具；不能覆蓋內建工具 |
| `AgentToolServices` | 對應用程式自有連線與服務的型別化存取 |
| `AgentLoopHook` | `willExecute`、`didExecute` 與 `shouldStop` 行為；`AgentPlanModeHook` 提供規劃模式限制與終止邏輯 |
| `AgentContextTransforming` | 與預設上下文管線組合的額外模型輸入投影 |
| `AgentModelStreaming` / `AgentModelCompleting` | 自訂模型服務、代理伺服器或確定性的測試模型 |
| `AgentRunPersisting` | 對話、執行快照、事件與壓縮紀錄的持久儲存 |
| `AgentSkillLibraryManaging` / `AgentMemoryAccessing` | 技能與記憶的儲存、修改與同步 |

工具預設可用於 `.planning` 與 `.acting`。透過 `AgentToolTypeRegistration(_:availableIn:make:)`
或 `AnyAgentTool(_:availableIn:)` 限制可用模式；不可用的工具既不會出現在模型請求中，
也無法由執行器查找到。模式互不重疊的註冊可以同名，包括為 Guardian 的 `.reviewing` 模式提供
獨立的參數結構與實作。

## 應用程式負責什麼

- 聊天介面、核准與輸入介面，以及工具卡片呈現。`AgentToolDetail` 與可信呈現器提供呈現資料，而不是檢視。
- 認證資訊儲存、持久儲存的資料庫，以及應用程式自有服務的生命週期。
- Shell/SSH 執行與一般檔案系統存取。內建檔案工具僅操作暫存區，更廣泛的存取由自訂工具提供。
  套件已包含模型服務的 HTTP 用戶端與 MCP 用戶端。
- 何時壓縮上下文、產生對話標題或執行記憶學習；這些服務不會自行啟動背景工作。

## 在地化

使用者介面的字串位於 `Localizations/Localizable.xcstrings`，包含英文、簡體中文與正體中文，
由 `Scripts/build-localizations.sh` 編譯至 `Sources/AgentKit/Resources/*.lproj`。
修改字串目錄後，需重新執行指令稿並提交產生的資源；`swift build` 只複製資源，不會編譯字串目錄。

工具卡片會在呈現時依閱讀者的地區設定解析文字，因此已記錄的卡片也能以另一種語言顯示。

## 致謝

AgentKit 參考並使用了以下專案的構想與成果。此處分別列出設計參考、改寫程式碼與套件相依項目。

### 設計參考

- **[Pi](https://github.com/badlogic/pi-mono)**：模型串流介面邊界（`streamFn`）、呼叫範圍內的工具進度回呼
  （`onUpdate`）、保守的批次排程、依輪次邊界壓縮上下文，以及暫存檔案編輯行為。
  這些構想分別以 Swift 實作於 `AgentTurnDriver`、`AgentToolExecutor`、`AgentToolScheduler`、
  `AgentCompactionService` 與 `AgentScratchWorkspace`。
- **[pi-plan-mode](https://github.com/narumiruna/pi-extensions/tree/main/packages/pi-plan-mode)**：
  隱藏且具版本的規劃約定，以及明確結束規劃執行的方式。AgentKit 透過 `AgentPlanContractInjection`
  與 `AgentPlanModeHook` 表達這些設計，而不是在使用者審閱計畫時暫停執行個體。
- **[pi-approval-guardian](https://github.com/mics8128/pi-approval-guardian)**：Guardian 策略與失敗時拒絕執行的
  審查流程參考，包括先提供完整授權基準，再附加增量證據。AgentKit 將其調整為供應商中立的 Swift 型別，
  並保留由主應用程式掌握的核准邊界。
- **[OpenAI Codex](https://github.com/openai/codex)**：自動審查與數量受限的結構化使用者問題的行為參考，
  並非執行階段相依項目。

### 改寫程式碼

- **[LanguageModelChatUI](https://github.com/Lakr233/LanguageModelChatUI)**，作者 Lakr233：
  `BalancedEmitter` 改寫自其 MIT 授權的實作，用於將串流文字調節為有界、有序的更新。

### 選用相依項目

- **[ScrubberKit](https://github.com/Lakr233/ScrubberKit)**，作者 Lakr233：
  為 `AgentKitScrubber` 提供 MIT 授權的網頁擷取與搜尋實作。
  `AgentWebDocument` 保留了其「可讀 Markdown 與原始文件並存」的資料形式；核心 `AgentKit` 目標不相依於它。

各上游專案保留自己的著作權與授權。貢獻者、原始碼與適用聲明請參閱連結中的儲存庫。

## 授權條款

本儲存庫採用 [MIT 授權條款](./LICENSE)。

SPDX-License-Identifier: [MIT](https://spdx.org/licenses/MIT.html)
