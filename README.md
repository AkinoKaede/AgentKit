# AgentKit

A tool-calling agent runtime for Swift apps. No UI, no dependencies.

The loop, the approval gate, the provider adapters, and a set of built-in tools you choose from.
Everything with an opinion about what your app actually does — where it connects, what it can
reach, how it draws a tool card — is yours to supply.

```swift
.package(url: "https://github.com/AkinoKaede/AgentKit.git", from: "0.1.0")
```

macOS 15+, iOS 18+, Swift 6.

## What it does

```swift
import AgentKit

let runtime = AgentRuntime(
    model: AgentProviderClient(provider: provider, model: model, secret: key),
    registry: AgentToolCatalog.registry(
        builtIn: AgentBuiltInToolConfiguration(
            groups: [.scratch, .web, .userInteraction],
            workspace: AgentScratchWorkspace(
                conversationID: conversation, applicationName: "MyApp"
            ),
            web: MyWebClient()
        )
    ),
    approval: AgentApprovalBroker(reviewer: nil) { request in
        await askTheUser(request) ? .allow : .deny("Declined.")
    }
)

for await event in await runtime.start(AgentRunRequest(
    conversationID: conversation,
    prompt: "Summarize what changed in the staged config",
    permissionMode: .askForApproval
)) {
    switch event {
    case .messageDelta(_, let text): print(text, terminator: "")
    case .toolFinished(let invocation, let result): log(invocation, result)
    default: break
    }
}
```

The loop is: stream one assistant turn, run the tools it asked for, feed the results back, ask
again. Every phase is a separate value you can hold still in a test — `AgentTurnDriver` streams a
turn, `AgentToolScheduler` plans its batch, `AgentToolExecutor` takes one call through validation,
preflight, hooks, authorization, and execution in that fixed order.

## Built-in tools

Tools are selected by group. A group whose dependency is missing contributes nothing rather than
offering the model a tool that could only fail.

| Group | Tools | Needs |
| --- | --- | --- |
| `.scratch` | `scratch_list` `scratch_read` `scratch_search` `scratch_write` `scratch_edit` `scratch_diff` `scratch_delete` | `AgentScratchWorkspace` |
| `.web` | `fetch` `web_search`, and `scratch_fetch` when `.scratch` is on too | `AgentWebFetching`; `web_search` also needs `AgentWebSearching` |
| `.userInteraction` | `request_user_input` `request_user_secret` | nothing — the handler comes from the run |
| `.planning` | `present_plan` | a workspace and an `AgentPlanRecorder` |
| `.tasks` | `manage_tasks` | an `AgentTaskList` |
| `.skills` | `load_skill` | a non-empty `AgentSkillCatalog` |
| `.mcp` | whatever your configured MCP servers advertise | `MCPServer` entries |

Your own tools join the same registry after the built-ins, so a name of yours can never shadow one
of theirs:

```swift
AgentToolCatalog.registry(builtIn: builtIn, additional: myTools)
```

A tool is a `descriptor` plus `preflight` and `execute`. `preflight` is where locally-proven facts
are established — whether *this* call is read-only, whether it may run beside others — and nothing
a model or a remote server said can override it afterwards.

## Providers

`AgentProviderClient` speaks OpenAI Responses, OpenAI Chat Completions, Anthropic Messages, and
Gemini (including Vertex). Every OpenAI-compatible gateway is the OpenAI kind with a different base
URL. `ModelCatalogClient` lists a provider's models; `ModelCapabilityResolver` fills in what the
listing did not say. If you would rather not use any of it, `AgentModelStreaming` is a
single-method protocol and the runtime knows nothing else about the boundary.

## Permission modes

Safety is a property of the call, established locally, never asserted by the model:

- `.locallyReadOnly` — proven to change nothing.
- `.locallyContained` — changes only storage the app owns, i.e. the scratch workspace.
- `.requiresAuthorization` — everything else.

The first two are allowed in every mode. A staging area you have to approve into is not a staging
area, and dialogs nobody can act on teach the reader to click through the one that matters.

| Mode | Non-read-only calls |
| --- | --- |
| `.askForApproval` | go to your `manualApproval` handler |
| `.approveForMe` | go to `SecurityReviewing`; missing credentials, timeouts, and malformed JSON fail closed |
| `.fullAccess` | run, while every structural boundary still holds |

Authorization is deliberately not an extension point. `AgentApprovalHandling` is a structural stage
of the executor that no configuration removes; hooks run on either side of it.

## Extension points

All additive:

- `AgentToolCatalog.registry(builtIn:additional:)` — your tools.
- `AgentToolServices` — a typed bag your tools reach app-owned things through, so a credential
  prompt of yours never has to appear in a runtime protocol.
- `AgentLoopHook` — `willExecute` / `didExecute` / `shouldStop`. `AgentPlanModeHook` is one, and
  takes a `hostDecision` closure for judgements only your own tools can make.
- `AgentContextTransforming` — rewrites what is sent at the model boundary. The built-in chain
  reorders tool results to match the calls they answer, drops orphans, repairs calls a dead process
  never answered, trims older results head-and-tail, and injects session context.
- `AgentModelStreaming` / `AgentModelCompleting` — the provider boundary.
- `AgentRunPersisting` — where runs are stored. An in-memory one ships; a database one is yours.

## Not included

No UI. `AgentToolDetail` is a value type describing what a tool wants shown — labels, fields, lists
— and drawing it is yours.

No transports, no shell, and no filesystem access outside the scratch workspace. A tool that
reaches a remote machine belongs to the app that owns the connection, which is what `additional:`
and `AgentToolServices` exist for.

## Localization

User-facing strings live in `Localizations/Localizable.xcstrings` (English and Simplified Chinese)
and are compiled into `Sources/AgentKit/Resources/*.lproj` by `Scripts/build-localizations.sh`,
which must be re-run after editing the catalog. The compiled output is committed because
`swift build` copies resources verbatim and does not compile string catalogs the way Xcode does.

Tool cards resolve their text at render time from the reader's locale, so a card recorded in one
language reads correctly in another.

## Credits

The loop's shape is [Pi](https://github.com/badlogic/pi-mono)'s. `AgentModelStreaming` is its
`streamFn`, the per-call progress callback is its `onUpdate`, plan mode ends its turn the way
`pi-plan-mode` terminates, and compaction cuts at a turn boundary against a recent-token budget
because that is what Pi found worked. Where this diverges it says so at the divergence.

`AgentWebFetching` is shaped after [ScrubberKit](https://github.com/Lakr233/ScrubberKit), which is
what `fetch` and `web_search` were first written against: a page reduced to readable Markdown, with
the original kept beside it. Nothing here depends on it — the protocol is two methods and any
implementation will do — but the result shape is its.

## License

This repository is licensed under [MIT License](./LICENSE).

SPDX-License-Identifier: [MIT](https://spdx.org/licenses/MIT.html)
