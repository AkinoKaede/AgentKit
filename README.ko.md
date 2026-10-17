# AgentKit

[Deutsch](README.de.md) · [English](README.md) · [Français](README.fr.md) · [日本語](README.ja.md) · **한국어** · [简体中文（中国）](README.zh-CN.md) · [正體中文（臺灣）](README.zh-TW.md)

도구 실행 조율, 명시적인 권한 제어, 영구 저장되는 대화 상태를 갖춘 AI 에이전트를 Swift로 구현하세요.

## 용도

텍스트를 생성하는 데 그치지 않고 앱의 도구를 통해 작업을 수행하는 어시스턴트를 만들 수 있습니다.
AgentKit은 모델과 도구 간의 실행 루프, 승인, 대화 상태를 담당합니다. 앱은 UI, 자격 증명, 저장소,
도메인별 기능을 제공합니다.

## 설치

**macOS 15+ 또는 iOS 18+**, **Swift 6.2+** 툴체인이 필요합니다.

패키지 의존성을 추가하세요.

```swift
.package(url: "https://github.com/AkinoKaede/AgentKit.git", from: "2.1.0")
```

그런 다음 대상 타깃에 코어 제품을 추가하세요.

```swift
.product(name: "AgentKit", package: "AgentKit")
```

`AgentKit` 타깃에는 서드파티 의존성이 없습니다. 선택적으로 사용할 수 있는 `AgentKitScrubber` 제품은
ScrubberKit 기반 웹 클라이언트를 제공하며, 코어에 WebKit 의존성을 추가하지 않습니다.

## 사용법

다음 예제는 Responses 엔드포인트와 항상 제공되는 공유 Scratch 도구를 사용합니다.
비동기 컨텍스트에서 호출하고 앱의 자격 증명 저장소에서 가져온 API 키를 전달하세요.
`manualApproval` 클로저는 승인 UI를 표시한 뒤 `.allow` 또는 `.deny(reason)`을 반환해야 합니다.

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
    let workspace = AgentScratchWorkspace.shared(applicationName: "MyApp")
    var configuration = AgentLoopConfiguration()
    configuration.outputProjection = AgentToolOutputProjection(workspace: workspace)
    let runtime = AgentRuntime(
        model: AgentProviderClient(provider: provider, model: model, secret: apiKey),
        registry: AgentToolCatalog.registry(
            builtIn: AgentBuiltInToolConfiguration(
                groups: [],
                workspace: workspace
            )
        ),
        approval: AgentApprovalBroker(reviewer: nil, manualApproval: manualApproval),
        configuration: configuration
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

임시 작업 공간의 작업은 앱이 관리하는 저장소 안에서만 이루어지므로 사전 승인됩니다.
승인 콜백은 정책이 `.ask`인 도구를 추가했을 때 사용됩니다. 가디언(Guardian) 검토기를 제공하지 않아도
`.askForApproval`에는 영향이 없지만, `.approveForMe`에서는 안전을 위해 이러한 호출을 거부합니다.

앱에 통합할 때는 다음 사항을 고려하세요.

- **실행마다 런타임을 하나씩 생성합니다.** `start(_:)`는 하나의 소비자만 읽을 수 있는
  `AsyncStream<AgentEvent>`를 반환합니다. 실행 중에는 런타임을 유지하여 UI에서 `steer(_:)`나
  `cancel()`을 호출할 수 있도록 하세요.
- **대화를 이어갑니다.** 같은 `conversationID`를 재사용하고 `priorMessages`를 전달하세요.
  런타임은 기록을 자동으로 불러오지 않습니다. 컨텍스트가 압축된 경우 복원한 `modelTranscript`를 사용하세요.
  영구 저장이 필요하면 `AgentRunPersisting` 저장소를 제공하세요. 기본 구현은 메모리에만 저장합니다.
- **스트리밍 출력을 표시합니다.** `.messageDelta`와 `.reasoningDelta`로 화면을 실시간 업데이트하세요.
  `.modelRetryScheduled`를 받으면 해당 메시지의 미완성 출력을 버리고, `.messageFinished`를 확정된
  결과로 사용하세요. 예제는 완료된 메시지만 출력합니다.
- **사용자 상호작용을 별도로 연결합니다.** `.userInteraction`은 도구를 등록하지만, UI를 연결하려면
  런타임의 `userInteraction:` 인수에 `AgentUserInteractionHandling`을 전달해야 합니다.
  승인 및 검토 이벤트도 같은 스트림에 포함하려면 공유 `AgentEventChannel`을 런타임에 전달하고,
  해당 채널의 `emit` 콜백을 브로커의 `event:` 인수에 전달하세요.
- **사용자 의도와 컨텍스트를 구분합니다.** `authoredPrompt`는 사용자가 직접 작성한 원문이며,
  `prompt`에는 앱이 추가한 컨텍스트가 포함될 수 있습니다. `authorizationEvidence`에는 사용자에게
  직접 받은 권한 부여의 근거만 포함하세요. 사용자 정의 시스템 프롬프트를 구성할 때는
  `AgentSystemPrompt.default`를 포함하세요.

## 아키텍처

각 `AgentToolDetailPresenter`의 `layout: AgentToolDetailLayout`으로 표시 정책을 등록합니다.
`singleLineHeader`와 `boundsApprovalHeight`는 각각 한 줄 제목과 승인 상세 높이 제한을 지정하고,
`truncateStrategy`는 표시 전용 접기에 `head`, `tail`, `middle`, `none`을 선택합니다.
기본값은 일반 제목, 자연스러운 승인 높이, `head`이며 `.compact`는 두 레이아웃 옵션을 모두 활성화합니다.
호스트는 도구 이름으로 분기하지 말고 등록된 설정을 `AgentToolDetail(items:layout:)`에 전달합니다.
메타데이터 텍스트 블록에 `isCollapsible: false`를 지정하면 위치와 무관하게 미리보기 제한에서 제외됩니다.
승인 인수는 항상 전체를 읽을 수 있어야 합니다. 설정은 신뢰할 수 있는 로컬 presenter 레지스트리에서만 해석하며
MCP 페이로드에서는 받지 않습니다. 모델 출력 잘라내기, 저장 파일, 잘라내기 마커에는 영향을 주지 않습니다.

```swift
static let presenter = AgentToolDetailPresenter(
    id: "example.logs",
    layout: .init(singleLineHeader: true, boundsApprovalHeight: true, truncateStrategy: .tail),
    present: present,
    presentArguments: presentArguments
)
```

`AgentRuntime`은 전체 실행을 조율하며, 제공업체나 도구 구현을 하나로 합친 거대한 구성 요소가 아닙니다.
한 번의 실행에 속한 태스크, 대화 기록 스냅샷, 추가 지시 큐, 이벤트 채널을 관리하고 각 단계를
독립적으로 테스트할 수 있는 구성 요소에 위임합니다.

### 실행 흐름

1. **사용 가능한 기능을 결정합니다.** 실행 모드(`.planning`, `.acting`, `.reviewing`)에 따라
   `AgentToolRegistry`를 필터링합니다. 모델과 실행기는 동일하게 확정된 도구 집합을 사용합니다.
2. **모델 입력을 준비합니다.** `AgentContextPipeline`이 모델에 전달할 대화 기록을 구성합니다.
   확정된 컨텍스트 및 출력 투영을 다시 적용하고 도구 메시지의 순서를 복구하되, 사용자에게 표시되는 기록은
   잘라내지 않습니다.
3. **한 턴의 응답을 스트리밍합니다.** `AgentTurnDriver`가 `AgentModelStreaming`을 호출하여 어시스턴트
   메시지와 도구 호출을 조립하고, `AgentEventChannel`을 통해 진행 상황을 알립니다.
4. **도구 배치의 실행을 계획합니다.** `AgentToolExecutor`가 인수를 검증하고 로컬 사전 검사를 수행합니다.
   `AgentToolScheduler`는 이 결과를 바탕으로 순차 실행 또는 동시 실행 수가 제한된 병렬 실행을 선택합니다.
5. **권한을 확인하고 실행합니다.** 준비된 각 호출은 `willExecute`, 승인 단계, 도구 실행, `didExecute`를
   차례로 거칩니다. 훅은 호출을 차단할 수 있지만 권한 확인을 우회할 수는 없습니다.
6. **기록하고 반복합니다.** 모델이 요청한 원래 호출 순서대로 도구 결과를 추가하고, `AgentRunPersisting`을
   통해 스냅샷을 저장합니다. 다음 모델 요청으로 넘어가는 시점에 대기 중인 추가 지시를 전달한 뒤 모델을
   다시 호출합니다. 도구 호출과 대기 중인 추가 지시가 모두 없으면 종료하며, 훅, 오류 또는 취소로도
   실행을 종료할 수 있습니다.

### 소스 구성

코어 디렉터리는 하나의 SPM 타깃 안에서 역할을 나눕니다. `AgentKitScrubber`는 별도의 선택적 제품입니다.

| 영역 | 역할 | 주요 타입 |
| --- | --- | --- |
| [`Core`](Sources/AgentKit/Core) | 공통 메시지, 이벤트, 실행 요청, 스킬 및 기억 데이터 타입 | `AgentTranscriptMessage`, `AgentEvent`, `AgentRunRequest`, `AgentSkill`, `AgentMemoryState` |
| [`Runtime`](Sources/AgentKit/Runtime) | 실행 수명 주기, 턴 스트리밍, 스케줄링, 컨텍스트 투영, 압축, 영구 저장 인터페이스 | `AgentRuntime`, `AgentTurnDriver`, `AgentToolScheduler`, `AgentToolExecutor`, `AgentContextPipeline` |
| [`Providers`](Sources/AgentKit/Providers) | HTTP/SSE 어댑터, 인증, 모델 검색, 지원 기능 판별 | `AgentProviderClient`, `ModelProvider`, `AIModel`, `ModelCatalogClient` |
| [`Tools`](Sources/AgentKit/Tools) | 도구 인터페이스, 등록, 스키마, 내장 도구, 표시용 데이터 | `AgentToolDefinition`, `AnyAgentTool`, `AgentToolCatalog`, `AgentToolServices`, `AgentToolDetail` |
| [`Security`](Sources/AgentKit/Security) | 로컬 승인 정책, 가디언 검토, 비밀 정보 핸들, 민감 정보 마스킹 | `AgentApprovalBroker`, `GuardianClient`, `GuardianSessionStore`, `SecretBroker` |
| [`MCP`](Sources/AgentKit/MCP) | 원격 서버 설정 및 프로토콜 클라이언트. `Tools/MCP`를 통해 도구 레지스트리에 연결 | `MCPServer`, `MCPClient`, `AgentMCPTools` |
| [`Services`](Sources/AgentKit/Services) | 호스트 앱이 주 실행 루프 밖에서 호출하는, 도구를 사용하지 않는 기능 | `ConversationTitleService`, `AgentMemoryLearningService` |
| [`AgentKitScrubber`](Sources/AgentKitScrubber) | 웹 콘텐츠 가져오기와 검색을 구현하는 선택적 제품 | `ScrubberWebClient` |

### 제공업체 계층의 내부 구조

`AgentProviderClient`는 HTTP 전송, 자격 증명, 취소, 크기 제한, 재시도 여부 판별을 담당합니다.
내부의 `AgentProviderRequestEncoder`는 도구 순서와 모델 기능을 한 번 준비한 다음, 네트워크에
접근하지 않고 선택된 프로토콜 고유의 요청 구조를 생성합니다.

`AgentProviderResponseParser`는 응답마다 도구 호출 식별 정보와 종료 상태를 관리합니다.
실시간 응답과 버퍼링된 응답 모두에 `AgentProviderResponseDecoder`를 사용하며, 형식별 디코더는
`+Responses`, `+ChatCompletions`, `+Anthropic`, `+Google` 파일에 있습니다.
새 요청이나 재시도에는 새로운 상태를 사용합니다. `AgentProviderClient`의 공개 정적 어댑터는
호환성을 위한 진입점으로 유지됩니다.

공유 코드는 프로토콜의 의미를 따릅니다. 두 OpenAI 형식은 구조화된 출력의 스키마 인코딩과 토큰 사용량
변환을 재사용하지만, 서로 중복되지 않는 Anthropic의 캐시 집계는 별도로 처리합니다.
실시간 Chat Completions는 종료 사유가 도착한 후에도 읽기를 계속합니다. 사용량이 그 뒤에 도착할 수
있기 때문입니다.

### 런타임 보장 사항

- **정책은 로컬에서 결정합니다.** 사전 검사가 호출별 승인 정책과 동시 실행 방식을 결정합니다.
  모델의 주장이나 원격 MCP 주석은 호출을 승인할 수 없습니다. 원격 도구의 파괴적 작업 힌트는
  스케줄링을 순차 실행으로 더 엄격하게 제한하는 데만 사용할 수 있습니다.
- **동시 실행은 보수적으로 판단합니다.** 실행 가능한 모든 호출과 실행 설정이 병렬 실행을 허용할 때만
  배치를 병렬로 실행합니다. 순차 실행이 필요한 호출이 하나라도 있으면 전체 배치를 순차 실행합니다.
  결과는 항상 호출 순서대로 대화 기록에 추가됩니다.
- **대화 기록을 복구할 수 있습니다.** 거부되거나 취소된 배치에서도 모든 도구 호출에 결과를 돌려줍니다.
  비정상 종료 후 복구할 때는 결과가 없는 호출을 *실행 결과 불명*으로 표시합니다.
  실행된 적이 없다고 단정하지 않으므로, 이미 완료되었을 수 있는 작업을 모델이 다시 수행하도록 유도하지 않습니다.
- **모델 재시도 시 도구를 재실행하지 않습니다.** 제공업체의 일시적 오류가 발생하면 현재 모델 요청을
  최대 다섯 번 재시도하며, 대기 시간은 1, 2, 4, 8, 16초입니다. 도구는 스트림이 완료된 뒤에만 실행합니다.
  `AgentLoopConfiguration.modelRetryPolicy`로 설정할 수 있으며, 사용자 정의 모델에서는
  `shouldRetry(after:)`를 통해 재시도할 오류를 지정합니다.
- **강제 취소 없이 추가 지시를 전달합니다.** `steer(_:)`는 다음 모델 처리 경계에서 전달할 메시지를
  큐에 넣습니다. 대기 중인 도구는 추가 지시 신호를 받도록 선택할 수 있지만, 일반적으로 실행 중인 도구를
  강제로 중지하지는 않습니다.
- **표시용 기록과 모델 컨텍스트를 분리합니다.** 확정된 출력 투영과 호스트 앱이 시작하는 압축은 표시용
  기록을 대체하지 않고 모델 입력을 줄입니다. 루프 자체에는 턴 수나 도구 호출 횟수 제한이 없습니다.
  `AgentCompactionService`를 호출하고 그 기록을 영구 저장할 시점은 호스트 앱이 결정합니다.

## 내장 도구

`AgentBuiltInToolConfiguration.groups`로 도구 그룹을 선택합니다. 기본값은 `.all`입니다.
각 도구는 필요한 의존성이 있을 때만 등록됩니다. 그룹을 선택한다고 해당 서비스가 자동 생성되지는 않습니다.

| 그룹 | 도구 | 의존성 |
| --- | --- | --- |
| 항상 제공 | `scratch_list`, `scratch_read`, `scratch_search`, `scratch_write`, `scratch_replace`, `scratch_copy`, `scratch_move`, `scratch_diff`, `scratch_delete` | `workspace: AgentScratchWorkspace` |
| `.web` | `fetch`, `web_search`, `scratch_fetch` | `web: AgentWebFetching`, `search: AgentWebSearching` |
| `.userInteraction` | `request_user_input`, `request_user_secret` | 카탈로그 의존성 없음. 런타임에 사용자 상호작용 핸들러 제공 |
| `.planning` | `present_plan` | 작업 공간과 `plans: AgentPlanRecorder` |
| `.tasks` | `manage_tasks` | `tasks: AgentTaskList`. 작업 수행 모드(`.acting`)에서만 사용 가능 |
| `.skills` | `skill_read_file`, `skills_list`, `skill_manage`, `skill_install` | 읽기에는 카탈로그 또는 스킬 목록, 관리에는 `skillLibrary`, 설치에는 추가로 `skillPackageResolver` 필요 |
| `.memory` | `memory_search`, `memory`, `session_search` | `memory: AgentMemoryAccessing`. `memory`를 통한 변경은 작업 수행 모드(`.acting`)에서만 가능 |
| `.chatCollaboration` | `list_models`, `create_new_chat`, `list_chats`, `read_chat`, `send_to_chat`, `wait_chats` | 모델 목록에는 `chatModels: AgentChatModelCatalog`, 채팅 작업에는 `chats: AgentChatCoordinating`과 `chatSource` 필요 |
| `.mcp` | 설정된 서버가 제공하는 도구 | `mcpServers` 항목 |

채팅 협업 도구는 `.approve`를 사용하며, 호스트 앱이 해당 서비스를 제공할 때만 등록됩니다.
호스트 앱은 채팅 수명 주기, 영구 저장, 영구 기록에 기반한 중복 전달 방지를 담당합니다.
신뢰할 수 있는 표시기는 프롬프트, 전송한 메시지, 대화 기록을 반복해서 표시하지 않고 대상과 상태만 간결하게
보여 줍니다. 에이전트가 작성한 메시지를 저장하거나 복원할 때는 `AgentTranscriptMessage.origin`을
보존하세요. 이러한 메시지는 사용자의 권한 부여 근거와 기억 학습의 원문에서 제외됩니다.

### 스킬과 기억

- `skill_read_file`은 활성화된 스킬의 `SKILL.md` 또는 보조 파일에서 크기가 제한된 구간을 읽습니다.
  `skills_list`에는 `skillInventory`의 비활성화된 스킬과 읽기 전용 스킬도 포함할 수 있습니다.
- `skill_manage`와 `skill_install`은 작업 수행 모드(`.acting`)에서만 사용할 수 있으며 `.ask` 승인 정책을 적용합니다.
  호스트 앱이 제공하는 `AgentSkillLibraryManaging`은 검토된 리비전을 기준으로 변경 사항을 원자적으로
  커밋하고, 읽기 전용 이름을 보호해야 합니다. 변경 사항은 다음 실행부터 사용할 수 있습니다.
- `GitHubSkillPackageResolver`는 설치할 공개 GitHub 스킬 패키지를 확인하고 가져옵니다.
  사전 검사에서 변경 불가능한 패키지를 다운로드하여 임시 보관합니다. 승인 대상은 다운로드가 아니라
  검토한 바이트를 저장하는 작업입니다. 설치 과정에서는 스크립트를 실행하지 않습니다.
- `AgentMemoryAccessing`은 필요할 때 기억을 조회하고 저장된 세션을 검색하는 기능을 제공합니다.
  컨텍스트 파이프라인에서 `AgentMemoryContext`를 사용하면 기억 내용 자체는 넣지 않고 철회 가능한
  검색 정책만 삽입할 수 있습니다. `memory_search`는 반환 범위를 제한하되 각 항목을 생략 없이 반환합니다.
  어휘 기반 검색은 자연어 질문을 검색어로 나누며 중국어 단어도 처리합니다. 먼저 의미 있는 모든 검색어와
  일치하는 항목을 찾고, 결과가 없을 때만 하나 이상의 검색어와 일치하는 항목으로 범위를 넓힙니다.
  동의어를 추론하거나 언어 간 번역을 수행하지는 않습니다. `AgentSearchQuery`는 이 쿼리 분석과
  안전한 FTS5 검색어 인용 처리를 호스트 앱의 `session_search` 저장소와 공유합니다.
  `AgentMemoryLearningService`는 범위가 제한된 참고 데이터를 바탕으로 검증된 업데이트를 제안하며,
  검토하고 적용할 시점은 호스트 앱이 결정합니다.

도구 등록과 컨텍스트 삽입은 별개입니다. 활성화된 카탈로그의 `catalogBlock`을
`AgentTurnContextSnapshot.skillCatalog`에 전달하면 모든 스킬 본문을 불러오지 않고도 모델이 절차를
찾을 수 있습니다. 저장된 기억과 과거 검색 결과는 참고 데이터일 뿐, 권한을 부여하는 근거가 아닙니다.

### 웹 콘텐츠 가져오기와 검색

코어에는 각각 하나의 비동기 메서드를 갖는 `AgentWebFetching`과 `AgentWebSearching`이 정의되어 있습니다.
자체 추출기나 검색 API로 구현하거나, 다음 선택적 제품을 추가하세요.

```swift
.product(name: "AgentKitScrubber", package: "AgentKit")
```

앱이 시작될 때 메인 액터에서 다음을 실행하세요.

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

이 설정을 `AgentToolCatalog.registry(builtIn:)`에 전달하세요. `web:`만 제공하면 가져오기만 활성화되며
`web_search`는 **활성화되지 않습니다**. `search:`는 별도의 의존성입니다. `scratch_fetch`는 공유 작업 공간을 자동으로 사용합니다.

제공업체와 모델이 네이티브 검색을 지원한다면 `AgentProviderClient(webSearch:)`를 `true`로 설정하고
`search:`를 생략할 수도 있습니다. 먼저 `ModelProvider.supportsNativeWebSearch(model:)`를 확인하세요.
프로토콜 호환성만으로 게이트웨이가 서버 측 검색을 구현한다고 보장할 수는 없습니다.

## 모델 제공업체

`AgentProviderClient`는 네 가지 `ModelAPIFormat`, 즉 `.chatCompletions`, `.responses`, `.messages`,
`.generateContent`를 지원합니다. Vertex는 `.generateContent`를 사용하며 주소는 프로젝트와 위치에서
생성합니다. 호환 게이트웨이도 같은 형식을 사용하므로 별도의 제공업체 구현이 필요하지 않습니다.

- **`inferenceURL`은 완전한 요청 엔드포인트입니다.** 경로나 기본값을 자동으로 붙이지 않습니다.
  모델 ID가 들어갈 위치에는 `{model}`을 사용하세요. 추론 엔드포인트가 비어 있으면 목적지를 추측하지 않고
  실패합니다.
- **`baseURL`은 모델 목록의 루트 주소입니다.** `ModelCatalogClient`가 `/models`를 덧붙입니다.
  목록 기능이 없는 엔드포인트라면 비워 두세요. 경로를 추론하도록 맡기지 말고 호출자가 두 URL을 모두 제공해야 합니다.
- **자격 증명은 설정과 분리합니다.** `credentialRef`는 호스트 앱의 조회 키이며 비밀 정보 자체가 아닙니다.
  조회한 값은 `secret:`으로 전달하세요. 인증이 필요 없는 엔드포인트에는 `secret: ""`를 전달하면
  빈 인증 헤더를 보내지 않습니다. Vertex 서비스 계정 인증에는 여전히 자격 증명이 필요합니다.
- **지원 기능을 명시합니다.** 모델 목록에 기능 정보가 없으면 `AIModel.abilities`와
  `ModelCapabilityResolver`로 도구 호출, 추론, 구조화된 출력, 네이티브 검색 기능을 지정하세요.

실시간 응답과 버퍼링된 응답은 요청별 파싱과 SSE 프레임 처리를 공유합니다. 제공업체 계층을 완전히
대체하려면 `AgentModelStreaming`을 구현하세요. `AgentModelCompleting`은 도구를 사용하지 않으면서
완전한 응답이 필요한 기능을 지원합니다. 구조화된 출력은 `AgentModelOutputFormat`으로 전달하며,
모델이 `.structuredOutput`을 선언하면 선택된 프로토콜에 맞게 변환됩니다.

## 승인과 신뢰 경계

승인 정책은 개별 호출에 속하며 로컬에서 결정됩니다.

| 정책 | 동작 |
| --- | --- |
| `.deny` | 모든 권한 모드에서 거부 |
| `.approve` | 추가 승인 단계 없이 실행 |
| `.ask` | 아래 실행 권한 모드에 따라 처리 |

| 권한 모드 | `.ask` 호출 처리 |
| --- | --- |
| `.askForApproval` | 호스트 앱의 `manualApproval` 핸들러에 요청 |
| `.approveForMe` | `GuardianReviewing`에 검토 요청. 검토기 사용 불가, 시간 초과, 유효하지 않은 응답 시 실행 거부 |
| `.fullAccess` | 실행하되 인수 검증, 도구 사용 가능 여부 등 구조적 검사는 계속 적용 |

임시 작업 공간 작업과 명시적으로 활성화한 `web_search`는 사전 승인됩니다. `fetch`와 `scratch_fetch`는
호출자가 선택한 URL에 접속하므로 `.ask`를 사용합니다. MCP 도구는 호스트 앱이 로컬에 영구 저장한 정책을
사용합니다. 거부된 도구도 등록 상태를 유지하므로 호출을 시도하면 명시적인 거부 결과를 받을 수 있습니다.

`AgentApprovalHandling`은 실행기의 필수 단계입니다. 훅이나 스킬은 이 단계를 제거하거나 대체할 수 없습니다.
가디언은 격리된 `.reviewing` 모드에서 실행되며, 기본적으로 조사 도구가 등록되어 있지 않습니다.
`ReviewerReadOnlyApproval`은 이미 `.approve`로 지정된 호출만 허용하고 상위 승인으로 넘기는 경로를
제공하지 않아 재귀적 검토를 방지합니다. `GuardianSessionStore`는 범위가 제한된 권한 부여 기준과
결정을 여러 실행에 걸쳐 보존하며, 이를 주 대화에 섞지 않습니다.

사용자가 입력한 비밀 정보는 내용을 지울 수 있는 `AgentSecret` 저장소와 `SecretBroker`를 거쳐
일회용 핸들로 전달됩니다. `issue(secret)`으로 저장하고 `consume(handle)`로 한 번 가져옵니다.
호출자가 broker의 수명 주기를 관리하며, 여러 실행에서 재사용하고 해당 범위가 끝나면 `discardAll()`로 정리합니다.
`request_user_secret`은 `prompt`, 사용자에게 표시할 `purpose`, 선택적 `timeout_seconds`를 받아
`secret_handle`과 `single_use`를 반환합니다. 평문은 모델 입력, 검토, 이벤트, 영구 저장 기록에 포함되지 않습니다.
도구 출력은 신뢰할 수 없는 데이터입니다. 제한적인 예외는 설치된 스킬의
`SKILL.md`로, 절차를 제공할 수는 있지만 권한을 부여할 수는 없습니다.
스킬의 보조 파일은 여전히 신뢰할 수 없는 참고 데이터로 취급합니다.

## 공유 Scratch와 도구 출력

Scratch는 필수 기능이며 같은 기기의 같은 앱에 속한 모든 대화가 공유합니다. `AgentScratchWorkspace.shared(applicationName:)`가 반환한 동일한 조정자를 도구 설정과 `AgentLoopConfiguration.outputProjection`에 전달하세요. 루트는 Application Support / applicationName / Scratch이며 대화 ID를 붙이지 않습니다. 대화를 삭제하거나 분기해도 파일을 삭제하거나 복사하지 않습니다. AI는 작업별 상대 경로를 선택하고 덮어쓰기 전에 기존 파일을 확인해야 합니다. 상위 디렉터리는 자동으로 생성하며 경로, 심볼릭 링크 검사와 파일/작업 공간 할당량은 유지합니다.

`AgentTruncateStrategy`는 `head`(기본값), `tail`, `middle`, `none`을 지원합니다. `AgentTruncateLimits`의 기본값은 64 KiB(65,536 UTF-8 바이트)와 논리적 줄 2,000개입니다. 매우 긴 한 줄도 중간에서 자르지 않습니다. 모델 투영은 JSON 이스케이프와 외부 필드의 크기도 계산합니다. 페이지 읽기는 실제 다음 오프셋을 유지하며 accumulator나 추가 저장 파일을 만들지 않습니다.

저장은 도구별 선택 기능이며 모델 인자나 Scratch 켜기/끄기 설정이 아닙니다. 아래 팩터리에 Scratch 기준의 전체 상대 경로를 반환하는 클로저를 전달하며 저장이 필요할 때만 호출합니다. 디렉터리와 파일 이름은 도구가 결정합니다. AgentKit은 접두사나 확장자를 강제하지 않고 부모 디렉터리를 만들고 경계를 검증하며 이름 충돌 시 덮어쓰지 않습니다. 권장 규칙은 `<conversationID>/outputs/<tool-name>-<UUID>.txt`이며 밑줄은 하이픈으로 바꿉니다. 이는 파일 정리 규칙이지 대화 격리가 아닙니다. conversationID가 없으면 runID를 사용할 수 있습니다. 외부 MCP 저장은 호출된 도구 이름을 사용합니다. 누적 스냅샷은 같은 파일을 갱신합니다. 비스트리밍 도구는 `await accumulator.capturing(result)`를 사용할 수 있습니다.

AgentKit은 번역하지 않는 두 마커만 생성합니다. 저장 성공 시 `[Showing lines <start>-<end> of <total>. Full output: <path>]`, 그 외에는 `[Showing lines <start>-<end> of <total>]`를 사용합니다. 저장 오류와 이어 읽기 offset/cursor는 별도 결과 필드에 유지하며 마커를 추가하지 않습니다. UI 접기는 독립적이며 자르기 마커나 파일을 생성하지 않습니다. 표시 계층은 실제 자르기 시 확정된 `AgentToolResult.truncateMarker`를 표시할 수 있습니다. 외부 MCP 결과에는 `middle`과 저장을 사용하지만 외부 클라이언트 응답에는 모델 자르기나 Scratch 저장을 적용하지 않습니다.

```swift
let conversationID = (context.conversationID ?? context.runID).uuidString.lowercased()
let accumulator = context.makeOutputAccumulator {
    "\(conversationID)/outputs/my-tool-\(UUID().uuidString.lowercased()).txt"
}
accumulator.append(Data("one complete line\n".utf8))
let snapshot = await accumulator.snapshot()
// snapshot.output, snapshot.capture?.path, snapshot.capture?.error
```

Scratch 할당량은 파일당 8 MiB, 작업 공간당 64 MiB, 항목 512개입니다. 모델용 accumulator는 제한된 데이터를 유지하고 누적 스냅샷을 원자적으로 교체하며 무제한 디스크 스풀이 아닙니다. `snapshot(capturePath:)`로 도구가 지정한 경로에 별도 스냅샷을 저장할 수 있습니다. 할당량 초과나 쓰기 실패는 `capture.error`로 보고하며 완전한 사본을 저장했다고 표시하지 않습니다.

마커는 Pi의 줄 범위 형식을 참고합니다. `middle`은 유지된 두 범위를 나열하고 전체 줄 수를 모르면 `of <total>`을 생략합니다. 너무 긴 한 줄은 `[Showing 0 of 1 lines]`가 될 수 있습니다. 저장에 성공했을 때만 `Full output: <path>`를 추가합니다.

### 내장 도구 출력 정책

| 도구 / 결과 | 전략 | 자동 저장 |
| --- | --- | --- |
| `fetch`, `web_search` | `head` | 예 |
| MCP | `middle` | 예 |
| `scratch_read`, `skill_read_file` | `head`, 페이지 처리 | 아니요 |
| `read_chat` | `head`, 페이지 처리 | 아니요 |
| `scratch_search` | `head` | 아니요 |
| 기타 내장 도구 | `head` | 아니요 |
| 외부 클라이언트 응답 | 적용 안 함 | 아니요 |

`scratch_fetch`는 호출자가 지정한 경로에 쓰는 것이 주 작업이며 자동 자르기 저장이 아닙니다. 결과 수와 페이지 범위 같은 원본 제한은 유지됩니다. 신뢰할 수 있는 설치된 `SKILL.md` 지침은 별도의 가져오기/검증 제한을 사용합니다.

### 1.x에서 마이그레이션

카탈로그와 출력 투영에 같은 공유 workspace를 사용하세요. `.scratch`는 호환용 그룹 이름으로 남지만 도구를 끄지 못하며 카탈로그 workspace가 nil이면 `.shared()`를 사용합니다. `AgentToolOutputProjection.workspace`는 더 이상 Optional이 아니므로 명시적 `nil`을 공유 workspace로 바꾸세요. 기존 workspace의 `conversationID` 인자는 디렉터리를 선택하지 않으며 `copyScope`는 아무 작업도 하지 않습니다. 기존 대화 폴더는 일반 상대 경로 디렉터리로 유지되므로 이전 파일을 읽을 때 원래 폴더 이름을 포함해야 합니다. 대화와 함께 공유 Scratch를 삭제하지 마세요. 자동 저장이 필요한 도구는 accumulator를 사용해야 하며 출력 투영은 더 이상 모든 초과 결과를 자동 저장하지 않습니다.

## AgentKit 확장

| 확장 지점 | 호스트 앱이 제공하는 항목 |
| --- | --- |
| `AgentToolDefinition` 및 `AgentToolCatalog.registry(builtIn:additional:)` | 내장 도구를 가리지 않고 추가하는 도메인별 도구 |
| `AgentToolServices` | 앱이 관리하는 연결 및 서비스에 대한 타입이 지정된 접근 |
| `AgentLoopHook` | `willExecute`, `didExecute`, `shouldStop` 동작. `AgentPlanModeHook`은 계획 모드의 제한과 종료 처리 제공 |
| `AgentContextTransforming` | 기본 컨텍스트 파이프라인과 결합하는 추가 모델 입력 투영 |
| `AgentModelStreaming` / `AgentModelCompleting` | 사용자 정의 제공업체, 프록시, 결정적 테스트 모델 |
| `AgentRunPersisting` | 대화, 실행 스냅샷, 이벤트, 압축 기록의 영구 저장 |
| `AgentSkillLibraryManaging` / `AgentMemoryAccessing` | 스킬과 기억의 저장, 변경, 동기화 |

도구는 기본적으로 `.planning`과 `.acting`에서 사용할 수 있습니다.
`AgentToolTypeRegistration(_:availableIn:make:)` 또는 `AnyAgentTool(_:availableIn:)`으로 등록을
제한하세요. 사용 불가능한 도구는 모델 요청에도, 실행기의 도구 조회에도 포함되지 않습니다.
사용 가능한 모드가 서로 겹치지 않는 등록은 같은 이름을 쓸 수 있습니다. 이를 통해 가디언의 `.reviewing`
모드에 별도의 스키마와 구현을 제공할 수 있습니다.

## 앱이 담당하는 부분

- 채팅 UI, 승인 및 입력 화면, 도구 카드 표시. `AgentToolDetail`과 신뢰할 수 있는 표시기는
  뷰가 아니라 표시용 데이터를 제공합니다.
- 자격 증명 저장소, 영구 데이터베이스, 앱이 관리하는 서비스의 수명 주기.
- Shell/SSH 실행과 일반 파일 시스템 접근. 내장 파일 도구는 임시 작업 공간 안에서만 동작합니다.
  더 넓은 범위의 접근은 앱의 자체 도구에서 구현해야 합니다. 제공업체용 HTTP 클라이언트와 MCP 클라이언트는
  패키지에 포함되어 있습니다.
- 컨텍스트 압축, 대화 제목 생성, 기억 학습을 수행할 시점.
  이러한 서비스는 스스로 백그라운드 작업을 시작하지 않습니다.

## 현지화

사용자에게 표시되는 문자열은 `Localizations/Localizable.xcstrings`에 있으며, 영어, 독일어, 프랑스어,
일본어, 한국어, 중국어 간체, 중국어 번체를 포함합니다.
`Scripts/build-localizations.sh`는 이를 `Sources/AgentKit/Resources/*.lproj`로 컴파일합니다.
카탈로그를 수정한 뒤에는 스크립트를 다시 실행하고 생성된 리소스도 커밋하세요.
`swift build`는 리소스를 복사할 뿐 문자열 카탈로그를 컴파일하지 않습니다.
`python3 Scripts/check-localization.py`로 여섯 번역 언어의 누락 여부, 서식 인수, 복수형,
언어별 공백 규칙을 검증할 수 있습니다.

도구 카드는 표시 시점에 읽는 사람의 로케일에 맞춰 텍스트를 결정하므로,
이미 기록된 카드도 다른 언어로 표시할 수 있습니다.

## 감사의 말

AgentKit은 다음 프로젝트의 아이디어와 작업을 바탕으로 합니다.
설계 참고 자료는 수정하여 사용한 코드 및 패키지 의존성과 구분됩니다.

### 설계 참고 자료

- **[Pi](https://github.com/badlogic/pi-mono)** — 모델 스트림 경계(`streamFn`), 도구별 진행 상황
  콜백(`onUpdate`), 보수적인 배치 스케줄링, 턴 경계에서의 컨텍스트 압축, 임시 파일 편집 동작을
  참고했습니다. 이러한 아이디어는 Swift로 `AgentTurnDriver`, `AgentToolExecutor`,
  `AgentToolScheduler`, `AgentCompactionService`, `AgentScratchWorkspace`에 구현되어 있습니다.
- **[pi-plan-mode](https://github.com/narumiruna/pi-extensions/tree/main/packages/pi-plan-mode)** —
  숨겨진 버전 관리형 계획 계약과 계획 실행의 명시적인 완료 방식을 참고했습니다.
  AgentKit은 사용자가 계획을 검토하는 동안 실행을 일시 중단하는 대신,
  `AgentPlanContractInjection`과 `AgentPlanModeHook`으로 이러한 설계를 구현합니다.
- **[pi-approval-guardian](https://github.com/mics8128/pi-approval-guardian)** — 가디언의 정책과,
  실패 시 실행을 거부하는 검토 흐름의 기반입니다. 초기 권한 부여 기준을 제시한 뒤 근거를 점진적으로
  추가하는 방식도 포함합니다. AgentKit은 이를 제공업체에 종속되지 않는 Swift 타입과 호스트 앱이
  관리하는 승인 경계에 맞게 적용합니다.
- **[OpenAI Codex](https://github.com/openai/codex)** — 자동 검토와 개수가 제한된 구조화된 사용자
  질문의 동작을 참고했습니다. 동작에 대한 참고 자료이며 런타임 의존성은 아닙니다.

### 수정하여 사용한 코드

- Lakr233의 **[LanguageModelChatUI](https://github.com/Lakr233/LanguageModelChatUI)** —
  `BalancedEmitter`는 MIT 라이선스로 제공되는 구현을 수정하여 사용합니다.
  스트리밍 텍스트를 크기가 제한되고 순서가 유지되는 업데이트로 나누어 전달 속도를 조절합니다.

### 선택적 의존성

- Lakr233의 **[ScrubberKit](https://github.com/Lakr233/ScrubberKit)** —
  `AgentKitScrubber`에 MIT 라이선스의 웹 페이지 추출 및 검색 구현을 제공합니다.
  `AgentWebDocument`는 읽기 좋은 Markdown과 원본 문서를 함께 보존하는 구조를 유지합니다.
  코어 `AgentKit` 타깃은 이 라이브러리에 의존하지 않습니다.

각 원본 프로젝트는 자체 저작권과 라이선스를 유지합니다.
기여자, 소스 코드, 적용되는 고지 사항은 링크된 저장소를 참조하세요.

## 라이선스

이 저장소는 [MIT 라이선스](./LICENSE)를 따릅니다.

SPDX-License-Identifier: [MIT](https://spdx.org/licenses/MIT.html)
