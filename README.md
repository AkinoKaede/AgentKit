# AgentKit

A tool-calling agent runtime for Swift apps. No UI.

The loop, the approval gate, the provider adapters, and a set of built-in tools you choose from.
Everything with an opinion about what your app actually does — where it connects, what it can
reach, how it draws a tool card — is yours to supply.

```swift
.package(url: "https://github.com/AkinoKaede/AgentKit.git", from: "0.5.0")
```

macOS 15+, iOS 18+, Swift 6.

## What it is for

An agent that only talks is easy. One that *acts* — writes things, changes things, spends money,
and does it somewhere the consequences are real — is where the hard parts are, and they are all in
the same place: between the model asking and the thing happening. This is a runtime for that gap.

**Approval policy is decided locally, never asserted.** Every call is classified before it runs, and
the classification comes from evidence this process established — a resolved path, a parsed URL, a
command a classifier could read, or a choice the user saved for an MCP tool. Nothing a model claims
about its own call, and nothing a remote MCP server annotates onto its tool, can approve a call.
Remote metadata can only tighten: a server's "destructive" hint makes a tool serial, while a
server's "safe" hint does nothing.

**Three policies, three permission modes, one gate.** `.deny` refuses every mode and `.approve` runs
in every mode. `.ask` delegates: `.askForApproval` puts the call to the user, `.approveForMe` sends
it to a model reviewer that fails closed, and `.fullAccess` runs it. Reads and writes confined to
app-owned storage are pre-approved, because a staging area you have to approve into is not a staging
area. Approval is deliberately *not* an extension point: `AgentApprovalHandling` is a structural
stage of the executor, and hooks run on either side of it rather than in place of it.

**Concurrency is opt-in per call, and the batch is only as parallel as its least parallel member.**
A turn's calls run together only when every one of them is marked parallel; a single sequential call
makes the whole turn serial rather than being fenced off into its own segment. A tool can also
decide per call — the same preflight that proves a command safe is what marks it parallel, because
both answers come from reading the command. Whatever the execution order, results reach the
transcript in the order the model asked for them, and **every call is answered** even when the run
is cancelled or refused. That last part is load-bearing: an assistant turn carrying an unanswered
tool call is rejected outright by every provider on the next request, so a stopped run that skipped
its answers would leave a permanently unusable conversation.

**The transcript is repaired at the model boundary, not in your history.** A pipeline rewrites what
is *sent*: tool results reordered to match the calls they answer, orphans dropped, and frozen
output/context projections replayed at their original message boundaries. Run snapshots and stored history keep everything. It also repairs what a crash left
behind — a process killed mid-batch leaves calls nothing answered, and those are answered with *the
outcome is unknown* rather than *the tool did not run*, because a model told the latter will simply
run the command again.

**Interruption is a first-class state, not a cancellation.** A user can steer mid-run; the message
is delivered at the next turn boundary and restamped so the conversation orders the way the model
saw it. A tool that is deliberately waiting can opt into hearing about it and stop waiting early —
offered to tools rather than imposed on them, because giving up on a poll costs nothing and giving
up on a running command strands it.

**Secrets never become context.** A value the user types is a single-use handle bound to run, tool,
and purpose; the plaintext goes straight to the executor and is excluded from model input, reviews,
events, logs, and persistence. Everything a tool returns is wrapped in untrusted-data framing, with
exactly one documented exception — a skill the user installed, whose provenance is what earns it.

**It runs long conversations.** Compaction cuts at a turn boundary against a recent-token budget,
keeps the display history intact, and records what it replaced so a relaunch does not silently
resurrect it. Token accounting uses the provider's own numbers where they exist and says so where it
is estimating.

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
| `.scratch` | `scratch_list` `scratch_read` `scratch_search` `scratch_write` `scratch_replace` `scratch_copy` `scratch_move` `scratch_diff` `scratch_delete` | `AgentScratchWorkspace` |
| `.web` | `fetch` `web_search`, and `scratch_fetch` when `.scratch` is on too | `AgentWebFetching`; `web_search` also needs `AgentWebSearching` — see below |
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

A registration may limit a tool to planning or acting runs. Both modes are the default, so existing
tools need no annotation; mode-specific tools opt in where they are registered:

```swift
AgentToolTypeRegistration(MyTaskTool.self, availableIn: [.acting]) { environment in
    MyTaskTool(environment: environment)
}
```

The runtime resolves that availability once per run. An unavailable tool is absent from every model
request in that run and from the executor's lookup, so what the model is offered and what can run do
not diverge.

### The web client

`AgentWebFetching` and `AgentWebSearching` are two methods each, and the core ships no
implementation: how a page becomes readable text is a product decision. A ready-made one lives in a
separate product, so nothing pulls in WebKit unless you ask for it.

```swift
.product(name: "AgentKitScrubber", package: "AgentKit")
```

```swift
import AgentKitScrubber

ScrubberWebClient.setup()                       // once, at launch
let web = ScrubberWebClient()                   // AgentWebFetching + AgentWebSearching
```

Reach for `web_search` when the model cannot search on its own. A provider that runs search on its
own servers should usually be left to — it searches better and costs no round trip.

A tool is a `descriptor` plus `preflight` and `execute`. `preflight` is where locally-proven facts
are established — whether *this* call is read-only, whether it may run beside others — and nothing
a model or a remote server said can override it afterwards.

## Providers

`AgentProviderClient` speaks four `ModelAPIFormat`s — Chat Completions, Responses, Messages, and
generateContent (including Vertex, whose address is derived from a project and a location). They are
named for the protocol rather than for whoever published it first, because every compatible gateway
serves one of the four at an address of its own.

A `ModelProvider` carries two addresses. `inferenceURL` is the complete address a request goes to,
with `{model}` where the model id belongs; this package appends no path to it and applies no
default, so the stored value *is* where requests land — deciding whether a pasted URL already
carried `/v1` is the caller's job, and guessing at it is the single most common source of "why does
my custom endpoint 404". A blank one is a provider pointed nowhere, and it fails as one.

`baseURL` is that address with its endpoint segment removed, and it is what `ModelCatalogClient`
hangs `/models` off. Removing the segment is the caller's job too, because only the caller knows
which part it appended — `/v1/chat/completions` and `/v1beta/models/{model}:generateContent` do not
put their endpoints in comparable places.

`ModelCapabilityResolver` fills in what a listing did not say. If you would rather not use any of
it, `AgentModelStreaming` is a single-method protocol and the runtime knows nothing else about the
boundary.

## Approval policies and permission modes

Approval policy is a property of the call, established locally, never asserted by the model:

- `.deny` — refuse the call in every permission mode.
- `.ask` — delegate to the run's permission mode.
- `.approve` — run without another approval step.

Calls proven read-only or confined to storage the app owns, such as the scratch workspace, are
marked `.approve`. MCP tools use the locally persisted choice made by the host app; denied tools
remain registered so an attempted call receives an explicit refusal.
Outbound `fetch` and `scratch_fetch` calls are `.ask` even though they read, because they contact a
caller-selected URL. The explicitly enabled `web_search` capability remains pre-approved.

| Mode | `.ask` calls |
| --- | --- |
| `.askForApproval` | go to your `manualApproval` handler |
| `.approveForMe` | go to `GuardianReviewing`; missing credentials, timeouts, and malformed JSON fail closed |
| `.fullAccess` | run, while every structural boundary still holds |

Approval is deliberately not an extension point. `AgentApprovalHandling` is a structural stage
of the executor that no configuration removes; hooks run on either side of it.

Guardian is an isolated, in-memory reviewing agent. `GuardianSessionStore` serializes each channel,
sends a bounded full authorization baseline once, then appends only new direct-user evidence and
canonical decisions. A host can keep the store across ordinary runs and give its model client a
stable `guardian:<conversation-id>` prompt-cache key. `.reviewing` is a third `AgentRunMode`; ordinary
tools default to `.planning` and `.acting`. A registry may hold disjoint same-name registrations with
different schema, preflight, and execution for `.reviewing`; no reviewing tools are registered by default.
`ReviewerReadOnlyApproval` has no reviewer or manual-approval reference and refuses every tool whose
preflight is not already `.approve`, preventing a Guardian tool call from recursively starting
Auto-reviewing.

`AgentModelOutputFormat` carries an optional JSON schema through the provider-neutral request. Models
marked with `.structuredOutput` use Responses `text.format`, Chat Completions `response_format`,
Anthropic `output_config.format`, or Gemini `generationConfig.responseFormat`; other models fall back
to the same local Guardian JSON validator.

## Extension points

All additive:

- `AgentToolCatalog.registry(builtIn:additional:)` — your tools.
- `AgentToolServices` — a typed bag your tools reach app-owned things through, so a credential
  prompt of yours never has to appear in a runtime protocol.
- `AgentLoopHook` — `willExecute` / `didExecute` / `shouldStop`. `AgentPlanModeHook` is one, and
  takes a `hostDecision` closure for judgements only your own tools can make.
- `AgentContextTransforming` — rewrites what is sent at the model boundary. The built-in chain
  reorders tool results to match the calls they answer, drops orphans, repairs calls a dead process
  never answered, and replays frozen output and per-message context snapshots.
- `AgentModelStreaming` / `AgentModelCompleting` — the provider boundary.
- `AgentRunPersisting` — where runs are stored. An in-memory one ships; a database one is yours.

## Not included

No UI. `AgentToolDetail` is a value type describing what a tool wants shown — labels, fields, lists
— and drawing it is yours.

No transports, no shell, and no filesystem access outside the scratch workspace. Tools of your own
go in through `additional:` and reach whatever your app owns through `AgentToolServices`.

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

`BalancedEmitter`, which paces streamed deltas into a bounded number of ordered updates, is adapted
from [LanguageModelChatUI](https://github.com/Lakr233/LanguageModelChatUI) by Lakr233, under the MIT
License.

[ScrubberKit](https://github.com/Lakr233/ScrubberKit) is what `fetch` and `web_search` were first
written against, and `AgentWebDocument` keeps its shape: a page reduced to readable Markdown with
the original kept beside it. It backs the optional `AgentKitScrubber` product; the core target does
not depend on it.

## License

This repository is licensed under [MIT License](./LICENSE).

SPDX-License-Identifier: [MIT](https://spdx.org/licenses/MIT.html)
