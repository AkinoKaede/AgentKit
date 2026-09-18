# AgentKit

**English** · [简体中文（中国）](README.zh-CN.md) · [正體中文（臺灣）](README.zh-TW.md)

Build AI agents in Swift with tool orchestration, explicit permissions, and persistent conversation state.

## What it is for

Build assistants that act through your app's tools, not just generate text. AgentKit handles the
model–tool loop, approval, and conversation state; your app supplies the UI, credentials, storage,
and domain-specific capabilities.

## Installation

Requires **macOS 15+ or iOS 18+**, with a **Swift 6.2+** toolchain.

Add the package dependency:

```swift
.package(url: "https://github.com/AkinoKaede/AgentKit.git", from: "0.13.3")
```

Then add the core product to your target:

```swift
.product(name: "AgentKit", package: "AgentKit")
```

The `AgentKit` target has no third-party dependencies. The optional `AgentKitScrubber` product
provides a ScrubberKit-backed web client without making the core depend on WebKit.

## Usage

This example uses a Responses endpoint and enables only the conversation's private scratch tools.
Call it from an async context, supplying an API key from your app's credential store and a
`manualApproval` closure that presents your approval UI and returns `.allow` or `.deny(reason)`.

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

Scratch operations are pre-approved because they stay within app-owned storage; the callback is
used when you add tools whose policy is `.ask`. A missing Guardian reviewer does not affect
`.askForApproval`, but makes `.approveForMe` fail closed for those calls.

For app integration:

- **One runtime per run.** `start(_:)` returns a single-consumer `AsyncStream<AgentEvent>`.
  Retain the runtime while running so your UI can call `steer(_:)` or `cancel()`.
- **Continue a conversation.** Reuse its `conversationID` and supply `priorMessages`; the runtime
  does not load history for you. Use the restored `modelTranscript` when compaction is present.
  Supply an `AgentRunPersisting` repository for durable storage; the default is in-memory.
- **Render streaming output.** Handle `.messageDelta` and `.reasoningDelta` for live updates,
  discard the affected message's partial output on `.modelRetryScheduled`, and use
  `.messageFinished` as the authoritative result. The example prints only finished messages.
- **Wire interaction separately.** `.userInteraction` registers the tools, but their UI needs an
  `AgentUserInteractionHandling` passed as `userInteraction:`. To include approval/review events in
  the same stream, pass a shared `AgentEventChannel` to the runtime and its `emit` callback to the
  broker's `event:` parameter.
- **Keep user intent separate from context.** `authoredPrompt` is the user's original text;
  `prompt` may include app-added context. Only direct-user evidence belongs in
  `authorizationEvidence`. Include `AgentSystemPrompt.default` when composing a custom system prompt.

## Architecture

`AgentRuntime` is the coordinator, not a monolithic provider or tool implementation. It owns one
run's task, transcript snapshot, steering queue, and event channel, and delegates each phase to a
separately testable component.

### How a run works

1. **Resolve capabilities.** Filter the `AgentToolRegistry` for the run's mode (`.planning`,
   `.acting`, or `.reviewing`). The model and executor use the same resolved tool set.
2. **Prepare model input.** `AgentContextPipeline` builds the model-facing transcript, replaying
   frozen context/output projections and repairing tool-message ordering without trimming display history.
3. **Stream one turn.** `AgentTurnDriver` calls `AgentModelStreaming`, assembles the assistant
   message and tool calls, and publishes progress through `AgentEventChannel`.
4. **Plan the tool batch.** `AgentToolExecutor` validates arguments and runs local preflight;
   `AgentToolScheduler` uses those results to choose serial or bounded-parallel execution.
5. **Authorize and execute.** Each ready call passes through `willExecute`, the approval gate,
   tool execution, and `didExecute`. Hooks can block calls, but cannot bypass authorization.
6. **Record and repeat.** Append tool results in the model's original call order, persist the
   snapshot through `AgentRunPersisting`, deliver queued steering at the next boundary, and ask
   the model again. Finish when there are no tool calls or pending steering, or a hook, error,
   or cancellation ends the run.

### Source map

Core directories separate responsibilities within one SPM target. `AgentKitScrubber` is a separate,
optional product.

| Area | Responsibility | Main types |
| --- | --- | --- |
| [`Core`](Sources/AgentKit/Core) | Shared messages, events, run requests, skills, and memory values | `AgentTranscriptMessage`, `AgentEvent`, `AgentRunRequest`, `AgentSkill`, `AgentMemoryState` |
| [`Runtime`](Sources/AgentKit/Runtime) | Run lifecycle, turn streaming, scheduling, context projection, compaction, and persistence contracts | `AgentRuntime`, `AgentTurnDriver`, `AgentToolScheduler`, `AgentToolExecutor`, `AgentContextPipeline` |
| [`Providers`](Sources/AgentKit/Providers) | HTTP/SSE adapters, authentication, model discovery, and capability resolution | `AgentProviderClient`, `ModelProvider`, `AIModel`, `ModelCatalogClient` |
| [`Tools`](Sources/AgentKit/Tools) | Tool contracts, registration, schemas, built-ins, and presentation values | `AgentToolDefinition`, `AnyAgentTool`, `AgentToolCatalog`, `AgentToolServices`, `AgentToolDetail` |
| [`Security`](Sources/AgentKit/Security) | Local approval policy, Guardian review, secret handles, and redaction | `AgentApprovalBroker`, `GuardianClient`, `GuardianSessionStore`, `SecretBroker` |
| [`MCP`](Sources/AgentKit/MCP) | Remote server configuration and protocol client; adapted into the tool registry by `Tools/MCP` | `MCPServer`, `MCPClient`, `AgentMCPTools` |
| [`Services`](Sources/AgentKit/Services) | Host-invoked, tool-free features outside the main loop | `ConversationTitleService`, `AgentMemoryLearningService` |
| [`AgentKitScrubber`](Sources/AgentKitScrubber) | Optional product implementing web fetch and search | `ScrubberWebClient` |

### Provider internals

`AgentProviderClient` owns HTTP transport, credentials, cancellation, size limits, and retry
classification. Its internal `AgentProviderRequestEncoder` prepares tool ordering and model
capabilities once, then builds the selected native request envelope without accessing the network.

`AgentProviderResponseParser` owns each response's tool identities and termination state. It uses
`AgentProviderResponseDecoder` for both live and buffered responses; the format-specific decoders
live in `+Responses`, `+ChatCompletions`, `+Anthropic`, and `+Google` files. A new request or retry
gets fresh state. The public static adapters on `AgentProviderClient` remain compatibility entry points.

Shared code follows protocol semantics: the two OpenAI formats reuse structured-output schema
encoding and token-usage conversion, while Anthropic's disjoint cache counts stay separate.
Live Chat Completions keep reading after a finish reason because usage may follow it.

### Runtime guarantees

- **Locally established policy.** Preflight determines each call's approval policy and concurrency.
  Model claims and remote MCP annotations cannot approve it; a remote destructive hint can only
  tighten scheduling to serial.
- **Conservative concurrency.** A batch runs in parallel only if every runnable call permits it
  and the run configuration allows it. One sequential call makes the whole batch serial. Results
  always enter the transcript in call order.
- **Recoverable transcripts.** Refused and cancelled batches still answer every tool call. Crash
  recovery marks unanswered calls as having an *unknown outcome*, not as having never run, so
  the model is not encouraged to repeat a potentially completed action.
- **Retries without tool replay.** Transient provider failures retry the current model request up
  to five times, with 1, 2, 4, 8, and 16 second backoff. Tools run only after the stream finishes.
  Configure this through `AgentLoopConfiguration.modelRetryPolicy`; custom models opt errors in
  through `shouldRetry(after:)`.
- **Steering without forced cancellation.** `steer(_:)` queues a message for the next model boundary.
  Waiting tools may opt into the interjection signal; ordinary executing tools are not forcibly stopped.
- **Separate history and model context.** Frozen output projections and host-driven compaction reduce
  model input without replacing display history. The loop has no turn/tool-call count limit; the host decides
  when to invoke `AgentCompactionService` and persist its records.

## Built-in tools

Select groups with `AgentBuiltInToolConfiguration.groups` (default: `.all`). Individual tools are
registered only when their dependencies are available; selecting a group does not create its services.

| Group | Tools | Dependencies |
| --- | --- | --- |
| `.scratch` | `scratch_list`, `scratch_read`, `scratch_search`, `scratch_write`, `scratch_replace`, `scratch_copy`, `scratch_move`, `scratch_diff`, `scratch_delete` | `workspace: AgentScratchWorkspace` |
| `.web` | `fetch`, `web_search`, `scratch_fetch` | `web: AgentWebFetching` for fetch; `search: AgentWebSearching` for search; `scratch_fetch` also requires `.scratch` and a workspace |
| `.userInteraction` | `request_user_input`, `request_user_secret` | No catalog dependency; supply the runtime's user-interaction handler |
| `.planning` | `present_plan` | A workspace and `plans: AgentPlanRecorder` |
| `.tasks` | `manage_tasks` | `tasks: AgentTaskList`; acting runs only |
| `.skills` | `skill_read_file`, `skills_list`, `skill_manage`, `skill_install` | Catalog/inventory for reads; `skillLibrary` for management; also `skillPackageResolver` for installation |
| `.memory` | `memory`, `session_search` | `memory: AgentMemoryAccessing`; mutations through `memory` are acting-only |
| `.mcp` | Tools advertised by configured servers | `mcpServers` entries |

### Skills and memory

- `skill_read_file` reads an enabled skill's `SKILL.md` or bounded windows of supporting files.
  `skills_list` can include disabled and read-only skills from `skillInventory`.
- `skill_manage` and `skill_install` are acting-only and use `.ask` approval. The host supplies
  `AgentSkillLibraryManaging`; it must commit atomically against the reviewed revision and enforce
  read-only names. Changes become available on the next run.
- `GitHubSkillPackageResolver` resolves public GitHub packages for installation. Preflight downloads
  and stages an immutable package; approval gates saving those reviewed bytes, not the download.
  Installation never executes scripts.
- `AgentMemoryAccessing` supplies bounded memory and saved-session search. Use `AgentMemoryContext`
  in a context pipeline to inject a revocable snapshot. `AgentMemoryLearningService` can propose
  validated memory updates; the host decides when to review and apply them.

Tool registration and context injection are separate: pass the enabled catalog's `catalogBlock`
through `AgentTurnContextSnapshot.skillCatalog` so the model can discover procedures without loading
all their bodies. Saved memory and historical search results are reference data, never authorization.

### Web fetching and search

The core defines `AgentWebFetching` and `AgentWebSearching`, each with one async method. Implement
them using your own extractor/search API, or add the optional product:

```swift
.product(name: "AgentKitScrubber", package: "AgentKit")
```

At app launch, on the main actor:

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

Pass this configuration to `AgentToolCatalog.registry(builtIn:)`. Supplying only `web:` enables
fetching, **not** `web_search`; the `search:` dependency is independent. To enable `scratch_fetch`,
also select `.scratch` and supply a workspace.

When the provider/model supports native search, you can instead set `AgentProviderClient(webSearch:)`
to `true` and omit `search:`. Check `ModelProvider.supportsNativeWebSearch(model:)` first; protocol
compatibility alone does not guarantee a gateway implements server-side search.

## Providers

`AgentProviderClient` adapts four `ModelAPIFormat`s: `.chatCompletions`, `.responses`, `.messages`,
and `.generateContent`. Vertex uses `.generateContent` with its address derived from project and
location. Compatible gateways use the same formats, not separate provider implementations.

- **`inferenceURL` is the complete request endpoint.** No path or default is appended. Use `{model}`
  where the model ID belongs. A blank inference endpoint fails rather than guessing a destination.
- **`baseURL` is the model-listing root.** `ModelCatalogClient` appends `/models`; leave it blank if
  the endpoint has no listing. The caller supplies both URLs rather than relying on path inference.
- **Credentials stay outside configuration.** `credentialRef` is a host lookup key, not the secret
  itself. Pass the retrieved value as `secret:`. For an unauthenticated endpoint, pass `secret: ""`;
  empty authentication headers are omitted. Vertex service-account authentication still requires credentials.
- **Capabilities are explicit.** Use `AIModel.abilities` and `ModelCapabilityResolver` to describe
  tool calling, reasoning, structured output, and native search when a model listing omits them.

Live and buffered responses share per-request parsing and SSE framing. To replace the provider
layer entirely, implement `AgentModelStreaming`; `AgentModelCompleting` supports tool-free features
that need a complete response. Structured output is carried by `AgentModelOutputFormat` and mapped
to the selected protocol when the model declares `.structuredOutput`.

## Approval and trust boundaries

Approval policy belongs to the call and is established locally:

| Policy | Behavior |
| --- | --- |
| `.deny` | Refuse in every permission mode |
| `.approve` | Run without another approval step |
| `.ask` | Delegate to the run's permission mode below |

| Permission mode | Handling of `.ask` calls |
| --- | --- |
| `.askForApproval` | Ask the host's `manualApproval` handler |
| `.approveForMe` | Ask `GuardianReviewing`; an unavailable reviewer, timeout, or invalid response fails closed |
| `.fullAccess` | Run, while validation, tool availability, and other structural checks still apply |

Scratch operations and explicitly enabled `web_search` are pre-approved. `fetch` and `scratch_fetch`
use `.ask` because they contact a caller-selected URL. MCP tools use the host's locally persisted
policy; denied tools remain registered so attempted calls receive an explicit refusal.

`AgentApprovalHandling` is a mandatory executor stage. Hooks and skills cannot remove or replace
it. Guardian runs in an isolated `.reviewing` mode, with no investigation tools registered by default.
`ReviewerReadOnlyApproval` allows only calls already marked `.approve` and has no escalation path,
preventing recursive review. `GuardianSessionStore` keeps bounded authorization baselines and decisions
across runs without mixing them into the main conversation.

User-entered secrets travel through `SecretBroker` as single-use handles bound to run, tool, and
purpose; the plaintext is excluded from model input, reviews, events, and persistence. Tool output
is untrusted data. The narrow exception is an installed skill's `SKILL.md`, which may supply
procedures but never permissions; its supporting files remain untrusted reference data.

## Extending AgentKit

| Extension point | What the host supplies |
| --- | --- |
| `AgentToolDefinition` and `AgentToolCatalog.registry(builtIn:additional:)` | Domain-specific tools, added without shadowing built-ins |
| `AgentToolServices` | Typed access to app-owned connections and services |
| `AgentLoopHook` | `willExecute`, `didExecute`, and `shouldStop` behavior; `AgentPlanModeHook` supplies plan-mode restrictions and termination |
| `AgentContextTransforming` | Additional model-input projections, composed with the default context pipeline |
| `AgentModelStreaming` / `AgentModelCompleting` | Custom providers, proxies, or deterministic test models |
| `AgentRunPersisting` | Durable conversations, run snapshots, events, and compaction records |
| `AgentSkillLibraryManaging` / `AgentMemoryAccessing` | Skill and memory storage, mutation, and synchronization |

Tools default to `.planning` and `.acting`. Restrict registrations with
`AgentToolTypeRegistration(_:availableIn:make:)` or `AnyAgentTool(_:availableIn:)`; unavailable tools
are absent from both model requests and executor lookup. Disjoint mode-specific registrations may
share a name, including separate schemas and implementations for Guardian's `.reviewing` mode.

## What your app owns

- Chat UI, approval/input surfaces, and tool-card rendering. `AgentToolDetail` and trusted
  presenters provide display values, not views.
- Credential storage, durable databases, and the lifetime of app-owned services.
- Shell/SSH execution and general filesystem access. The built-in file tools are confined to the
  scratch workspace; broader access belongs in your own tools. Provider HTTP and MCP clients are included.
- When to compact, generate conversation titles, or run memory learning; these services do not
  start background work on their own.

## Localization

User-facing strings live in `Localizations/Localizable.xcstrings` (English, Simplified Chinese,
and Traditional Chinese) and are compiled into `Sources/AgentKit/Resources/*.lproj` by
`Scripts/build-localizations.sh`. Re-run it after catalog edits and commit the generated resources:
`swift build` copies them rather than compiling string catalogs.

Tool cards resolve text at render time from the reader's locale, so a recorded card can be displayed
in a different language.

## Credits

AgentKit builds on the ideas and work of the following projects. Design references are distinct
from adapted code and package dependencies.

### Design references

- **[Pi](https://github.com/badlogic/pi-mono)** — the model-stream boundary (`streamFn`), scoped tool
  progress (`onUpdate`), conservative batch scheduling, turn-boundary compaction, and scratch-file
  editing behavior. These ideas are implemented in Swift across `AgentTurnDriver`, `AgentToolExecutor`,
  `AgentToolScheduler`, `AgentCompactionService`, and `AgentScratchWorkspace`.
- **[pi-plan-mode](https://github.com/narumiruna/pi-extensions/tree/main/packages/pi-plan-mode)** —
  the hidden, versioned plan contract and explicit completion of a planning run. AgentKit expresses
  those ideas through `AgentPlanContractInjection` and `AgentPlanModeHook`, rather than suspending
  a run while the user reviews a plan.
- **[pi-approval-guardian](https://github.com/mics8128/pi-approval-guardian)** — the basis for Guardian's
  policy and fail-closed review flow, including an initial authorization baseline followed by
  incremental evidence. AgentKit adapts it to provider-neutral Swift types and a host-owned approval boundary.
- **[OpenAI Codex](https://github.com/openai/codex)** — reference behavior for Auto-reviewing and
  bounded structured user questions. This is a behavioral reference, not a runtime dependency.

### Adapted code

- **[LanguageModelChatUI](https://github.com/Lakr233/LanguageModelChatUI)** by Lakr233 —
  `BalancedEmitter` is adapted from its MIT-licensed implementation to pace streamed text into
  bounded, ordered updates.

### Optional dependencies

- **[ScrubberKit](https://github.com/Lakr233/ScrubberKit)** by Lakr233 — the MIT-licensed page
  extraction and search implementation behind `AgentKitScrubber`. `AgentWebDocument` preserves
  its readable-Markdown/original-document shape. The core `AgentKit` target does not depend on it.

Each upstream project retains its own copyright and license. See the linked repositories for
contributors, source, and applicable notices.

## License

This repository is licensed under the [MIT License](./LICENSE).

SPDX-License-Identifier: [MIT](https://spdx.org/licenses/MIT.html)
