# AgentKit

[English](README.md) · [简体中文（中国）](README.zh-CN.md) · [正體中文（臺灣）](README.zh-TW.md) · **日本語**

ツールの実行管理、明示的な権限制御、永続的な会話状態を備えたAIエージェントをSwiftで構築できます。

## 用途

テキストを生成するだけでなく、アプリのツールを通じて操作を実行するアシスタントを構築するためのライブラリです。
AgentKitがモデルとツールの実行ループ、承認、会話状態を管理し、アプリがUI、認証資格情報、ストレージ、
アプリ固有の機能を提供します。

## インストール

**macOS 15+またはiOS 18+**と、**Swift 6.2+**のツールチェーンが必要です。

パッケージの依存関係を追加します。

```swift
.package(url: "https://github.com/AkinoKaede/AgentKit.git", from: "0.16.0")
```

次に、ターゲットにコアのプロダクトを追加します。

```swift
.product(name: "AgentKit", package: "AgentKit")
```

`AgentKit`ターゲットにはサードパーティへの依存がありません。オプションの`AgentKitScrubber`プロダクトは、
コアをWebKitに依存させずに、ScrubberKitを利用したWebクライアントを提供します。

## 使い方

次の例ではResponsesエンドポイントを使用し、会話専用の一時ワークスペースを操作するツールだけを有効にします。
非同期コンテキストから呼び出し、アプリの認証情報ストアから取得したAPIキーと、承認UIを表示して
`.allow`または`.deny(reason)`を返す`manualApproval`クロージャを渡してください。

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

一時ワークスペースの操作はアプリが管理するストレージ内で完結するため、事前承認されています。
承認コールバックは、ポリシーが`.ask`のツールを追加した場合に使用されます。
Guardianのレビュー担当が未設定でも`.askForApproval`には影響しませんが、`.approveForMe`では
これらの呼び出しを安全側に倒して拒否します。

アプリに組み込む際の要点は次のとおりです。

- **実行ごとにランタイムを用意する。** `start(_:)`は、単一のコンシューマが読み取る`AsyncStream<AgentEvent>`を返します。
  実行中はランタイムを保持し、UIから`steer(_:)`や`cancel()`を呼び出せるようにしてください。
- **会話を継続する。** 同じ`conversationID`を再利用し、`priorMessages`を渡します。ランタイムは履歴を自動で読み込みません。
  圧縮が適用済みの場合は、復元した`modelTranscript`を使用してください。
  永続保存には`AgentRunPersisting`リポジトリを渡します。デフォルトではメモリ内にのみ保存します。
- **ストリーミング出力を表示する。** `.messageDelta`と`.reasoningDelta`で表示を逐次更新し、
  `.modelRetryScheduled`では対象メッセージの途中の出力を破棄してください。確定した結果には`.messageFinished`を使用します。
  上の例では、完了したメッセージだけを出力しています。
- **ユーザ操作との接続を別途設定する。** `.userInteraction`はツールを登録しますが、そのUIを動作させるには
  `userInteraction:`に`AgentUserInteractionHandling`を渡す必要があります。承認とレビューのイベントも
  同じストリームに含めるには、共有の`AgentEventChannel`をランタイムに渡し、その`emit`コールバックを
  ブローカーの`event:`引数に渡してください。
- **ユーザの意図とコンテキストを分ける。** `authoredPrompt`はユーザが入力した元のテキストです。
  `prompt`にはアプリが追加したコンテキストを含められます。`authorizationEvidence`に含めるのは、
  ユーザ本人から直接得た承認の根拠だけにしてください。独自のシステムプロンプトを構成する際は、
  `AgentSystemPrompt.default`も含めてください。

## アーキテクチャ

`AgentRuntime`は実行全体を調整します。プロバイダやツールの実装をすべて抱えるクラスではありません。
1回の実行に属するタスク、会話履歴のスナップショット、追加指示のキュー、イベントチャネルを管理し、
各処理を個別にテストできるコンポーネントに委譲します。

### 実行の流れ

1. **利用可能な機能を決定する。** 実行モード（`.planning`、`.acting`、`.reviewing`）に応じて
   `AgentToolRegistry`を絞り込みます。モデルと実行側は、同じツール集合を使用します。
2. **モデルへの入力を準備する。** `AgentContextPipeline`がモデル用の会話履歴を構築します。
   確定済みのコンテキストと出力の投影を再適用し、表示用の履歴を削ることなくツールメッセージの順序を修復します。
3. **1ターンをストリーミングする。** `AgentTurnDriver`が`AgentModelStreaming`を呼び出し、
   アシスタントのメッセージとツール呼び出しを組み立て、`AgentEventChannel`で進捗を通知します。
4. **ツールの一括実行を計画する。** `AgentToolExecutor`が引数を検証し、ローカルの事前検査を行います。
   `AgentToolScheduler`はその結果から、直列実行か並列数を制限した並列実行かを決定します。
5. **承認を確認して実行する。** 実行可能になった各呼び出しは、`willExecute`、承認処理、ツール実行、
   `didExecute`の順に進みます。フックは呼び出しを阻止できますが、承認を迂回することはできません。
6. **記録して繰り返す。** モデルが指定した呼び出し順でツールの結果を追加し、`AgentRunPersisting`で
   スナップショットを保存します。次の処理の区切りで待機中の追加指示を届け、再びモデルに問い合わせます。
   ツール呼び出しも待機中の追加指示もなければ終了します。フック、エラー、キャンセルでも実行は終了します。

### ソース構成

コアの各ディレクトリは、1つのSPMターゲット内で責務を分担します。`AgentKitScrubber`は独立した
オプションのプロダクトです。

| 領域 | 責務 | 主な型 |
| --- | --- | --- |
| [`Core`](Sources/AgentKit/Core) | 共通のメッセージ、イベント、実行リクエスト、スキル、メモリの値 | `AgentTranscriptMessage`, `AgentEvent`, `AgentRunRequest`, `AgentSkill`, `AgentMemoryState` |
| [`Runtime`](Sources/AgentKit/Runtime) | 実行ライフサイクル、ターンのストリーミング、スケジューリング、コンテキストの投影、圧縮、永続化の契約 | `AgentRuntime`, `AgentTurnDriver`, `AgentToolScheduler`, `AgentToolExecutor`, `AgentContextPipeline` |
| [`Providers`](Sources/AgentKit/Providers) | HTTP/SSEアダプタ、認証、モデルの検出、機能の判定 | `AgentProviderClient`, `ModelProvider`, `AIModel`, `ModelCatalogClient` |
| [`Tools`](Sources/AgentKit/Tools) | ツールの契約、登録、スキーマ、組み込みツール、表示用の値 | `AgentToolDefinition`, `AnyAgentTool`, `AgentToolCatalog`, `AgentToolServices`, `AgentToolDetail` |
| [`Security`](Sources/AgentKit/Security) | ローカルの承認ポリシー、Guardianによるレビュー、シークレットハンドル、機密情報のマスキング | `AgentApprovalBroker`, `GuardianClient`, `GuardianSessionStore`, `SecretBroker` |
| [`MCP`](Sources/AgentKit/MCP) | リモートサーバの設定とプロトコルクライアント。`Tools/MCP`を通じてツールレジストリに登録 | `MCPServer`, `MCPClient`, `AgentMCPTools` |
| [`Services`](Sources/AgentKit/Services) | メインループの外で、ホストアプリが直接呼び出し、ツールを使わない機能 | `ConversationTitleService`, `AgentMemoryLearningService` |
| [`AgentKitScrubber`](Sources/AgentKitScrubber) | Webページの取得と検索を実装するオプションのプロダクト | `ScrubberWebClient` |

### プロバイダの内部構造

`AgentProviderClient`はHTTP通信、認証資格情報、キャンセル、サイズ制限、再試行の判定を管理します。
内部の`AgentProviderRequestEncoder`は、ツールの順序とモデルの機能を一度準備した後、ネットワークに
アクセスせずに、選択したプロトコル固有のリクエスト形式を構築します。

`AgentProviderResponseParser`は、応答ごとのツール識別情報と終了状態を管理します。
ストリーミング応答とバッファリングされた応答の両方で`AgentProviderResponseDecoder`を使用し、
形式別のデコーダは`+Responses`、`+ChatCompletions`、`+Anthropic`、`+Google`の各ファイルに配置されています。
新しいリクエストや再試行では、状態を新しく作り直します。`AgentProviderClient`の公開静的アダプタは、
互換性を維持するための入口として残されています。

共通化はプロトコルの意味に沿って行います。OpenAIの2つの形式は、構造化出力のスキーマのエンコードと
トークン使用量の変換を共有します。一方、Anthropicの互いに重ならないキャッシュのトークン数は別々に扱います。
ストリーミングのChat Completionsでは、終了理由の後に使用量が届く場合があるため、読み取りを続けます。

### ランタイムの保証

- **ポリシーはローカルで決定する。** 事前検査が、各呼び出しの承認ポリシーと並列実行の可否を決定します。
  モデルの主張やリモートMCPの注釈が承認を与えることはありません。リモート側の破壊的操作のヒントは、
  実行順序を直列に制限する方向にのみ作用します。
- **並列実行は慎重に判断する。** 実行可能なすべての呼び出しと実行設定が許可した場合にのみ、並列実行します。
  1つでも直列実行を必要とする呼び出しがあれば、全体を直列実行します。結果は常に呼び出し順に会話履歴へ追加されます。
- **会話履歴を復旧できる。** 拒否やキャンセルがあっても、すべてのツール呼び出しに結果を返します。
  クラッシュからの復旧時には、結果のない呼び出しを「未実行」ではなく「結果不明」として扱います。
  これにより、すでに完了している可能性のある操作をモデルが再実行しないようにします。
- **再試行時にツールを再実行しない。** プロバイダの一時的な障害では、現在のモデルリクエストを最大5回、
  1、2、4、8、16秒の間隔で再試行します。ツールはストリームが完了してから実行されます。
  `AgentLoopConfiguration.modelRetryPolicy`で設定でき、独自モデルでは`shouldRetry(after:)`で再試行対象のエラーを指定します。
- **強制キャンセルせずに追加指示を届ける。** `steer(_:)`は次のモデル処理の区切りで届けるメッセージをキューに入れます。
  待機中のツールは割り込みシグナルを受け取るようオプトインできますが、通常の実行中のツールを強制停止することはありません。
- **表示用の履歴とモデルのコンテキストを分ける。** 確定済みの出力の投影とホストアプリ主導の圧縮により、
  表示用の履歴を置き換えずにモデルへの入力を減らします。ループ自体にターン数やツール呼び出し回数の上限はありません。
  `AgentCompactionService`をいつ呼び出し、その記録をいつ保存するかはホストアプリが決定します。

## 組み込みツール

`AgentBuiltInToolConfiguration.groups`でグループを選択します。デフォルトは`.all`です。
各ツールは必要な依存サービスが利用可能な場合にのみ登録されます。グループを選択しても、サービス自体は作成されません。

| グループ | ツール | 依存サービス |
| --- | --- | --- |
| `.scratch` | `scratch_list`, `scratch_read`, `scratch_search`, `scratch_write`, `scratch_replace`, `scratch_copy`, `scratch_move`, `scratch_diff`, `scratch_delete` | `workspace: AgentScratchWorkspace` |
| `.web` | `fetch`, `web_search`, `scratch_fetch` | 取得には`web: AgentWebFetching`、検索には`search: AgentWebSearching`が必要。`scratch_fetch`にはさらに`.scratch`とワークスペースが必要 |
| `.userInteraction` | `request_user_input`, `request_user_secret` | カタログへの依存はなし。ランタイムにユーザ操作のハンドラを渡す |
| `.planning` | `present_plan` | ワークスペースと`plans: AgentPlanRecorder` |
| `.tasks` | `manage_tasks` | `tasks: AgentTaskList`。`.acting`の実行でのみ利用可能 |
| `.skills` | `skill_read_file`, `skills_list`, `skill_manage`, `skill_install` | 読み取りにはカタログ／インベントリ、管理には`skillLibrary`、インストールにはさらに`skillPackageResolver`が必要 |
| `.memory` | `memory_search`, `memory`, `session_search` | `memory: AgentMemoryAccessing`。`memory`による変更は`.acting`の実行でのみ利用可能 |
| `.chatCollaboration` | `list_models`, `create_new_chat`, `list_chats`, `read_chat`, `send_to_chat`, `wait_chats` | モデル一覧には`chatModels: AgentChatModelCatalog`、チャット操作には`chats: AgentChatCoordinating`と`chatSource`が必要 |
| `.mcp` | 設定済みサーバが公開するツール | `mcpServers`の項目 |

チャット連携ツールは`.approve`を使用し、ホストアプリが対応するサービスを提供した場合にのみ登録されます。
チャットのライフサイクル、永続化、配信の永続的な重複排除はホストアプリが管理します。
信頼されたプレゼンタは、プロンプト、送信したメッセージ、会話履歴は再掲せず、送信先と状態だけを簡潔に示します。
エージェントが作成したメッセージを保存・復元する際は、`AgentTranscriptMessage.origin`を保持してください。
これらのメッセージは、人間による承認の根拠とメモリ学習の参照元テキストから除外されます。

### スキルとメモリ

- `skill_read_file`は、有効なスキルの`SKILL.md`、または補助ファイルの指定範囲を読み取ります。
  `skills_list`は、`skillInventory`に含まれる無効なスキルや読み取り専用のスキルも一覧に含められます。
- `skill_manage`と`skill_install`は`.acting`の実行でのみ利用でき、`.ask`による承認を使用します。
  ホストアプリが提供する`AgentSkillLibraryManaging`は、レビュー済みのリビジョンに対してアトミックに変更を確定し、
  読み取り専用の名前を保護する必要があります。変更は次回の実行から利用可能になります。
- `GitHubSkillPackageResolver`は、インストール用に、公開されているGitHubパッケージを解決します。
  事前検査で変更不能なパッケージをダウンロードして一時保存します。承認の対象はダウンロードではなく、
  レビューした内容の保存です。インストール時にスクリプトが実行されることはありません。
- `AgentMemoryAccessing`は、必要に応じたメモリ取得と保存済みセッションの検索を提供します。
  コンテキストパイプラインで`AgentMemoryContext`を使用すると、メモリの内容を含めずに、撤回可能な検索ポリシーを挿入できます。
  `memory_search`は、件数を制限しつつ、各項目を省略せずに返します。字句検索では、自然言語の質問を語に分割し
  （中国語の語を含む）、まず意味のあるすべての語に一致する項目を探します。見つからない場合にのみ、いずれかの語に
  一致する項目へ範囲を広げます。同義語の推定や言語間の翻訳は行いません。
  `AgentSearchQuery`は、このクエリ解析と安全なFTS5検索語のクォートを、ホストアプリの`session_search`ストアと共有します。
  `AgentMemoryLearningService`は、範囲を制限した参照データから検証済みの更新案を作成し、
  ホストアプリがレビューと適用のタイミングを決定します。

ツールの登録とコンテキストの挿入は別の処理です。有効なカタログの`catalogBlock`を
`AgentTurnContextSnapshot.skillCatalog`に渡すことで、モデルはすべての本文を読み込まずに手順を見つけられます。
保存されたメモリと過去の検索結果は参照データであり、承認を与えるものではありません。

### Webページの取得と検索

コアには`AgentWebFetching`と`AgentWebSearching`が定義されており、それぞれ非同期メソッドを1つ持ちます。
独自の抽出処理や検索APIで実装するか、次のオプションのプロダクトを追加してください。

```swift
.product(name: "AgentKitScrubber", package: "AgentKit")
```

アプリの起動時に、メインアクタ上で設定します。

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

この設定を`AgentToolCatalog.registry(builtIn:)`に渡します。`web:`だけを指定した場合は取得が有効になりますが、
`web_search`は有効になりません。`search:`は独立した依存サービスです。`scratch_fetch`を有効にするには、
`.scratch`も選択し、ワークスペースを渡してください。

プロバイダとモデルがネイティブ検索に対応している場合は、代わりに`AgentProviderClient(webSearch:)`を
`true`に設定し、`search:`を省略できます。先に`ModelProvider.supportsNativeWebSearch(model:)`を確認してください。
プロトコルに互換性があっても、ゲートウェイがサーバ側の検索を実装しているとは限りません。

## プロバイダ

`AgentProviderClient`は、4種類の`ModelAPIFormat`（`.chatCompletions`、`.responses`、`.messages`、
`.generateContent`）に対応します。Vertexでは`.generateContent`を使用し、プロジェクトとロケーションから
アドレスを組み立てます。互換ゲートウェイも同じ形式を使用するため、個別のプロバイダ実装は不要です。

- **`inferenceURL`はリクエスト先の完全なエンドポイント。** パスやデフォルト値は自動で追加されません。
  モデルIDを埋め込む位置には`{model}`を使用してください。空欄の場合は、送信先を推測せずにエラーになります。
- **`baseURL`はモデル一覧取得用のルート。** `ModelCatalogClient`が`/models`を追加します。
  エンドポイントがモデル一覧を提供しない場合は空欄にしてください。パスの推測に頼らず、呼び出し側が両方のURLを指定します。
- **認証資格情報は設定の外で管理する。** `credentialRef`はホストアプリが検索に使うキーであり、シークレットそのものではありません。
  取得した値を`secret:`として渡してください。認証不要のエンドポイントには`secret: ""`を渡します。
  空の認証ヘッダは送信されません。Vertexのサービスアカウント認証では、認証資格情報が必要です。
- **モデルの機能は明示する。** モデル一覧に機能の情報がない場合は、`AIModel.abilities`と`ModelCapabilityResolver`で、
  ツール呼び出し、推論、構造化出力、ネイティブ検索への対応を指定してください。

ストリーミング応答とバッファリングされた応答は、リクエストごとの解析とSSEフレームの処理を共有します。
プロバイダ層全体を置き換えるには、`AgentModelStreaming`を実装してください。ツールを使わずに完全な応答を
必要とする機能には、`AgentModelCompleting`を使用できます。構造化出力は`AgentModelOutputFormat`で指定し、
モデルが`.structuredOutput`を宣言している場合に、選択したプロトコルの形式へ変換されます。

## 承認と信頼境界

承認ポリシーは呼び出しに属し、ローカルで決定されます。

| ポリシー | 動作 |
| --- | --- |
| `.deny` | すべての権限モードで拒否する |
| `.approve` | 追加の承認手順なしで実行する |
| `.ask` | 以下の実行時の権限モードに委ねる |

| 権限モード | `.ask`の呼び出しの扱い |
| --- | --- |
| `.askForApproval` | ホストアプリの`manualApproval`ハンドラに確認する |
| `.approveForMe` | `GuardianReviewing`に確認する。レビュー担当が利用できない、タイムアウトした、または応答が不正な場合は、安全側に倒して拒否する |
| `.fullAccess` | 実行する。ただし、検証、ツールの利用可否、その他の構造上のチェックは引き続き適用される |

一時ワークスペースの操作と、明示的に有効にした`web_search`は事前承認されています。
`fetch`と`scratch_fetch`は、呼び出し側が指定したURLにアクセスするため`.ask`を使用します。
MCPツールはホストアプリがローカルに永続保存したポリシーを使用します。拒否されたツールも登録は維持され、
呼び出しが試みられた場合に明示的な拒否を返します。

`AgentApprovalHandling`は実行処理の必須段階です。フックやスキルが取り除いたり、置き換えたりすることはできません。
Guardianは分離された`.reviewing`モードで動作し、デフォルトでは調査用ツールは登録されません。
`ReviewerReadOnlyApproval`は、すでに`.approve`に指定された呼び出しのみを許可し、権限を引き上げる経路を持ちません。
これにより、レビューが再帰的に発生することを防ぎます。`GuardianSessionStore`は、承認の根拠となる基準と判断を
上限のある形で複数の実行にわたって保持し、メインの会話には混ぜません。

ユーザが入力したシークレットは、消去可能な`AgentSecret`ストレージと`SecretBroker`を通じて扱われます。
実行、ツール、用途に紐付けられた一度限りのハンドルで受け渡され、平文はモデル入力、レビュー、イベント、
永続化の対象から除外されます。ツールの出力は信頼しないデータとして扱います。
限定的な例外は、インストール済みスキルの`SKILL.md`です。手順を提供することはできますが、
権限を与えることはできません。その補助ファイルは引き続き信頼しない参照データとして扱います。

## AgentKitの拡張

| 拡張ポイント | ホストアプリが提供するもの |
| --- | --- |
| `AgentToolDefinition`と`AgentToolCatalog.registry(builtIn:additional:)` | 組み込みツールを上書きせずに追加する、アプリ固有のツール |
| `AgentToolServices` | アプリが管理する接続とサービスへの型付きアクセス |
| `AgentLoopHook` | `willExecute`、`didExecute`、`shouldStop`の動作。`AgentPlanModeHook`は計画モードの制限と終了を提供 |
| `AgentContextTransforming` | デフォルトのコンテキストパイプラインに組み合わせる、モデル入力の追加の投影 |
| `AgentModelStreaming` / `AgentModelCompleting` | 独自のプロバイダ、プロキシ、決定論的なテスト用モデル |
| `AgentRunPersisting` | 永続的な会話、実行スナップショット、イベント、圧縮の記録 |
| `AgentSkillLibraryManaging` / `AgentMemoryAccessing` | スキルとメモリの保存、変更、同期 |

ツールはデフォルトで`.planning`と`.acting`で利用可能です。
`AgentToolTypeRegistration(_:availableIn:make:)`または`AnyAgentTool(_:availableIn:)`で登録先のモードを
制限できます。利用できないツールは、モデルへのリクエストにも実行側の検索対象にも含まれません。
モードが重複しない登録では同じ名前を共有でき、Guardianの`.reviewing`モード向けに別のスキーマと実装を用意することもできます。

## アプリが管理するもの

- チャットUI、承認や入力の画面、ツールカードの描画。`AgentToolDetail`と信頼されたプレゼンタが提供するのは、
  ビューではなく表示用の値です。
- 認証資格情報の保存、永続データベース、アプリが管理するサービスのライフサイクル。
- シェル／SSHの実行と一般的なファイルシステムへのアクセス。組み込みのファイルツールは一時ワークスペース内に
  制限されています。それを超えるアクセスは独自のツールで提供してください。プロバイダ用のHTTPクライアントとMCPクライアントは含まれています。
- コンテキストの圧縮、会話タイトルの生成、メモリ学習を実行するタイミング。これらのサービスが自発的に
  バックグラウンド処理を開始することはありません。

## ローカライズ

ユーザ向けの文字列は`Localizations/Localizable.xcstrings`にあり、英語、簡体字中国語、繁体字中国語、日本語に対応しています。
`Scripts/build-localizations.sh`で`Sources/AgentKit/Resources/*.lproj`にコンパイルします。
カタログを編集した後は、このスクリプトを再実行し、生成されたリソースもコミットしてください。
`swift build`はリソースをコピーするだけで、文字列カタログのコンパイルは行いません。
`python3 Scripts/check-cjk-localization.py`で、中国語と日本語の翻訳の網羅性、書式引数、間隔を検証できます。

ツールカードのテキストは、描画時に閲覧者のロケールで解決されます。そのため、記録済みのカードを別の言語で表示できます。

## 謝辞

AgentKitは、以下のプロジェクトのアイデアや成果を参考にしています。設計上の参考資料、移植したコード、
パッケージの依存関係は、それぞれ区別して示しています。

### 設計の参考

- **[Pi](https://github.com/badlogic/pi-mono)** — モデルのストリーム境界（`streamFn`）、呼び出しごとのツール進捗
  （`onUpdate`）、慎重な一括実行スケジューリング、ターンの区切りでの圧縮、一時ファイルの編集動作。
  これらのアイデアは、`AgentTurnDriver`、`AgentToolExecutor`、`AgentToolScheduler`、
  `AgentCompactionService`、`AgentScratchWorkspace`にSwiftで実装されています。
- **[pi-plan-mode](https://github.com/narumiruna/pi-extensions/tree/main/packages/pi-plan-mode)** —
  非表示でバージョン付きの計画の契約と、計画モードの実行を明示的に終了すること。AgentKitでは、ユーザが計画を確認する間に
  実行を中断して待つのではなく、`AgentPlanContractInjection`と`AgentPlanModeHook`でこれらの考え方を表現しています。
- **[pi-approval-guardian](https://github.com/mics8128/pi-approval-guardian)** — Guardianのポリシーと、
  安全側に倒して拒否するレビューフローの基礎。初期の承認基準と、その後に追加される根拠を含みます。
  AgentKitでは、特定のプロバイダに依存しないSwiftの型と、ホストアプリが管理する承認境界に合わせて実装しています。
- **[OpenAI Codex](https://github.com/openai/codex)** — 自動レビューと、件数を制限した、ユーザへの構造化質問の動作を参考にしています。動作上の参考であり、ランタイムの依存関係ではありません。

### 移植したコード

- Lakr233による**[LanguageModelChatUI](https://github.com/Lakr233/LanguageModelChatUI)** —
  `BalancedEmitter`は、このプロジェクトのMITライセンスの実装を基にしています。
  ストリーミングされたテキストを、件数を抑えた順序どおりの更新へペース調整するために使用します。

### オプションの依存関係

- Lakr233による**[ScrubberKit](https://github.com/Lakr233/ScrubberKit)** —
  `AgentKitScrubber`で使用する、MITライセンスのページ抽出と検索の実装です。
  `AgentWebDocument`は、読みやすいMarkdownと元の文書を保持する構造を引き継いでいます。
  コアの`AgentKit`ターゲットはScrubberKitに依存しません。

各プロジェクトの著作権とライセンスは、元の権利者に帰属します。貢献者、ソースコード、適用される告知については、
リンク先のリポジトリを参照してください。

## ライセンス

このリポジトリは[MITライセンス](./LICENSE)で提供されています。

SPDX-License-Identifier: [MIT](https://spdx.org/licenses/MIT.html)
