# AgentKit

**Deutsch** · [English](README.md) · [Français](README.fr.md) · [日本語](README.ja.md) · [한국어](README.ko.md) ·
[简体中文（中国）](README.zh-CN.md) · [正體中文（臺灣）](README.zh-TW.md)

Entwickeln Sie KI-Agenten in Swift mit Werkzeugorchestrierung, expliziten Berechtigungen und dauerhaft gespeichertem Gesprächszustand.

## Einsatzzweck

Erstellen Sie Assistenten, die über die Werkzeuge Ihrer App handeln, statt nur Text zu erzeugen.
AgentKit übernimmt die Modell-Werkzeug-Schleife, Genehmigungen und den Gesprächszustand.
Ihre App stellt Oberfläche, Anmeldedaten, Speicherung und domänenspezifische Funktionen bereit.

## Installation

Erfordert **macOS 15+ oder iOS 18+** und eine **Swift-6.2+-Toolchain**.

Fügen Sie die Paketabhängigkeit hinzu:

```swift
.package(url: "https://github.com/AkinoKaede/AgentKit.git", from: "2.0.0")
```

Fügen Sie anschließend Ihrem Target das Kernprodukt hinzu:

```swift
.product(name: "AgentKit", package: "AgentKit")
```

Das Target `AgentKit` hat keine Abhängigkeiten von Drittanbietern. Das optionale Produkt
`AgentKitScrubber` bietet einen Webclient auf Basis von ScrubberKit, ohne den Kern von WebKit abhängig zu machen.

## Verwendung

Dieses Beispiel verwendet einen Responses-Endpunkt mit dem verpflichtenden gemeinsamen Scratch-Bereich. Rufen Sie es aus einem asynchronen Kontext auf.
Übergeben Sie einen API-Schlüssel aus dem Anmeldedatenspeicher Ihrer App und eine
`manualApproval`-Closure, die Ihre Genehmigungsoberfläche anzeigt und `.allow` oder `.deny(reason)` zurückgibt.

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

Operationen im temporären Arbeitsbereich sind vorab genehmigt, weil sie auf den app-eigenen Speicher
beschränkt bleiben. Der Callback wird verwendet, wenn Sie Werkzeuge mit der Richtlinie `.ask` hinzufügen.
Ein fehlender Wächter-Prüfer (Guardian) beeinträchtigt `.askForApproval` nicht. Bei `.approveForMe`
werden solche Aufrufe jedoch aus Sicherheitsgründen abgelehnt.

Für die Integration in Ihre App:

- **Eine Runtime pro Lauf.** `start(_:)` liefert einen `AsyncStream<AgentEvent>` für genau einen Consumer.
  Halten Sie die Runtime während des Laufs am Leben, damit Ihre Oberfläche `steer(_:)` oder `cancel()` aufrufen kann.
- **Eine Unterhaltung fortsetzen.** Verwenden Sie dieselbe `conversationID` und übergeben Sie `priorMessages`.
  Die Runtime lädt den Verlauf nicht selbst. Nach einer Kontextkomprimierung verwenden Sie das wiederhergestellte
  `modelTranscript`. Für dauerhafte Speicherung übergeben Sie ein `AgentRunPersisting`-Repository;
  standardmäßig erfolgt die Speicherung nur im Arbeitsspeicher.
- **Streaming-Ausgaben anzeigen.** Verarbeiten Sie `.messageDelta` und `.reasoningDelta` für laufende Aktualisierungen.
  Verwerfen Sie bei `.modelRetryScheduled` die Teilausgabe der betroffenen Nachricht und verwenden Sie
  `.messageFinished` als maßgebliches Ergebnis. Das Beispiel gibt nur abgeschlossene Nachrichten aus.
- **Benutzerinteraktion separat anbinden.** `.userInteraction` registriert die Werkzeuge. Deren Oberfläche benötigt
  jedoch ein `AgentUserInteractionHandling`, das als `userInteraction:` übergeben wird. Sollen auch Genehmigungs-
  und Prüfereignisse im selben Stream erscheinen, übergeben Sie der Runtime einen gemeinsamen `AgentEventChannel`
  und dem Parameter `event:` des Brokers dessen `emit`-Callback.
- **Benutzerabsicht und Kontext trennen.** `authoredPrompt` enthält den ursprünglichen Benutzertext;
  `prompt` darf von der App ergänzten Kontext enthalten. In `authorizationEvidence` gehören ausschließlich
  direkt vom Benutzer stammende Autorisierungsbelege. Binden Sie beim Zusammenstellen eines eigenen
  System-Prompts `AgentSystemPrompt.default` ein.

## Architektur

`AgentRuntime` koordiniert den Ablauf, statt Anbieter- und Werkzeugimplementierungen in einer
monolithischen Komponente zu bündeln. Die Runtime verwaltet Task, Gesprächssnapshot, Warteschlange
für zusätzliche Anweisungen und Ereigniskanal eines Laufs und delegiert jede Phase an eine separat testbare Komponente.

### Ablauf eines Laufs

1. **Funktionen bestimmen.** Filtern Sie die `AgentToolRegistry` nach dem Modus des Laufs
   (`.planning`, `.acting` oder `.reviewing`). Modell und Executor verwenden dieselbe aufgelöste Werkzeugmenge.
2. **Modelleingabe vorbereiten.** `AgentContextPipeline` erstellt das Modelltranskript, wendet eingefrorene
   Kontext- und Ausgabeprojektionen erneut an und repariert die Reihenfolge von Werkzeugnachrichten,
   ohne den angezeigten Verlauf zu kürzen.
3. **Eine Runde streamen.** `AgentTurnDriver` ruft `AgentModelStreaming` auf, setzt Assistentennachricht und
   Werkzeugaufrufe zusammen und veröffentlicht den Fortschritt über `AgentEventChannel`.
4. **Den Werkzeugbatch planen.** `AgentToolExecutor` validiert Argumente und führt die lokale Vorprüfung aus.
   `AgentToolScheduler` entscheidet anhand der Ergebnisse zwischen serieller und begrenzt paralleler Ausführung.
5. **Autorisieren und ausführen.** Jeder bereite Aufruf durchläuft `willExecute`, die Genehmigungsprüfung,
   die Werkzeugausführung und `didExecute`. Hooks können Aufrufe blockieren, aber keine Autorisierung umgehen.
6. **Aufzeichnen und wiederholen.** Fügen Sie Werkzeugergebnisse in der ursprünglichen Aufrufreihenfolge des
   Modells hinzu, speichern Sie den Snapshot über `AgentRunPersisting`, übermitteln Sie wartende Zusatzanweisungen
   an der nächsten Modellgrenze und fragen Sie das Modell erneut an. Der Lauf endet, wenn weder Werkzeugaufrufe
   noch Zusatzanweisungen ausstehen oder wenn ein Hook, ein Fehler oder ein Abbruch ihn beendet.

### Quellcodestruktur

Die Kernverzeichnisse trennen Verantwortlichkeiten innerhalb eines SPM-Targets.
`AgentKitScrubber` ist ein separates, optionales Produkt.

| Bereich | Verantwortung | Zentrale Typen |
| --- | --- | --- |
| [`Core`](Sources/AgentKit/Core) | Gemeinsame Nachrichten, Ereignisse, Laufanfragen, Skills und Erinnerungsdaten | `AgentTranscriptMessage`, `AgentEvent`, `AgentRunRequest`, `AgentSkill`, `AgentMemoryState` |
| [`Runtime`](Sources/AgentKit/Runtime) | Lauflebenszyklus, Runden-Streaming, Scheduling, Kontextprojektion, Komprimierung und Persistenzverträge | `AgentRuntime`, `AgentTurnDriver`, `AgentToolScheduler`, `AgentToolExecutor`, `AgentContextPipeline` |
| [`Providers`](Sources/AgentKit/Providers) | HTTP/SSE-Adapter, Authentifizierung, Modellerkennung und Ermittlung unterstützter Funktionen | `AgentProviderClient`, `ModelProvider`, `AIModel`, `ModelCatalogClient` |
| [`Tools`](Sources/AgentKit/Tools) | Werkzeugverträge, Registrierung, Schemas, integrierte Werkzeuge und Darstellungswerte | `AgentToolDefinition`, `AnyAgentTool`, `AgentToolCatalog`, `AgentToolServices`, `AgentToolDetail` |
| [`Security`](Sources/AgentKit/Security) | Lokale Genehmigungsrichtlinien, Wächter-Prüfung, Geheimnis-Handles und Maskierung sensibler Daten | `AgentApprovalBroker`, `GuardianClient`, `GuardianSessionStore`, `SecretBroker` |
| [`MCP`](Sources/AgentKit/MCP) | Konfiguration entfernter Server und Protokollclient; über `Tools/MCP` in die Werkzeugregistrierung eingebunden | `MCPServer`, `MCPClient`, `AgentMCPTools` |
| [`Services`](Sources/AgentKit/Services) | Vom Host aufgerufene Funktionen außerhalb der Hauptschleife, die keine Werkzeuge verwenden | `ConversationTitleService`, `AgentMemoryLearningService` |
| [`AgentKitScrubber`](Sources/AgentKitScrubber) | Optionales Produkt zum Abrufen und Durchsuchen von Webinhalten | `ScrubberWebClient` |

### Interna der Anbieterschicht

`AgentProviderClient` verwaltet HTTP-Transport, Anmeldedaten, Abbrüche, Größenlimits und die Einordnung
wiederholbarer Fehler. Sein interner `AgentProviderRequestEncoder` bereitet Werkzeugreihenfolge und
Modellfunktionen einmal vor und erzeugt danach das native Anfrageformat des gewählten Protokolls, ohne auf das Netzwerk zuzugreifen.

`AgentProviderResponseParser` verwaltet Werkzeugidentitäten und Abschlusszustand jeder Antwort.
Für Live-Antworten wie für gepufferte Antworten verwendet er `AgentProviderResponseDecoder`.
Formatspezifische Decoder liegen in den Dateien `+Responses`, `+ChatCompletions`, `+Anthropic` und `+Google`.
Jede neue Anfrage und jeder Wiederholungsversuch erhält einen frischen Zustand.
Die öffentlichen statischen Adapter von `AgentProviderClient` bleiben als Kompatibilitätseinstiegspunkte erhalten.

Gemeinsamer Code folgt der Protokollsemantik: Die beiden OpenAI-Formate teilen die Schemakodierung für
strukturierte Ausgaben und die Umrechnung der Token-Nutzung. Anthropic-spezifische, nicht überlappende
Cache-Zähler bleiben getrennt. Live-Chat-Completions werden nach einem Abschlussgrund weitergelesen,
weil Nutzungsdaten erst danach eintreffen können.

### Garantien der Runtime

- **Lokal festgelegte Richtlinien.** Die Vorprüfung bestimmt Genehmigungsrichtlinie und Nebenläufigkeit jedes Aufrufs.
  Weder Behauptungen des Modells noch entfernte MCP-Annotationen können ihn genehmigen.
  Ein entfernter Hinweis auf destruktives Verhalten kann das Scheduling nur auf serielle Ausführung einschränken.
- **Konservative Nebenläufigkeit.** Ein Batch läuft nur dann parallel, wenn alle ausführbaren Aufrufe und
  die Laufkonfiguration dies erlauben. Ein einziger sequenzieller Aufruf macht den gesamten Batch seriell.
  Ergebnisse werden stets in Aufrufreihenfolge in das Transkript aufgenommen.
- **Wiederherstellbare Transkripte.** Auch abgelehnte oder abgebrochene Batches beantworten jeden Werkzeugaufruf.
  Nach einem Absturz werden unbeantwortete Aufrufe mit *unbekanntem Ergebnis* gekennzeichnet, nicht als nie ausgeführt.
  So wird das Modell nicht dazu verleitet, eine möglicherweise bereits abgeschlossene Aktion zu wiederholen.
- **Wiederholungsversuche ohne erneute Werkzeugausführung.** Vorübergehende Anbieterfehler führen zu höchstens
  fünf Wiederholungen der aktuellen Modellanfrage, mit Wartezeiten von 1, 2, 4, 8 und 16 Sekunden.
  Werkzeuge laufen erst nach Abschluss des Streams. Konfigurieren Sie dies über
  `AgentLoopConfiguration.modelRetryPolicy`; eigene Modelle kennzeichnen wiederholbare Fehler über `shouldRetry(after:)`.
- **Zusatzanweisungen ohne erzwungenen Abbruch.** `steer(_:)` stellt eine Nachricht für die nächste Modellgrenze
  in die Warteschlange. Wartende Werkzeuge können das Unterbrechungssignal abonnieren;
  gewöhnliche laufende Werkzeuge werden nicht zwangsweise angehalten.
- **Verlauf und Modellkontext bleiben getrennt.** Eingefrorene Ausgabeprojektionen und vom Host angestoßene
  Komprimierung verringern die Modelleingabe, ohne den angezeigten Verlauf zu ersetzen.
  Die Schleife begrenzt weder Runden noch Werkzeugaufrufe. Der Host entscheidet, wann er
  `AgentCompactionService` aufruft und dessen Aufzeichnungen dauerhaft speichert.

## Integrierte Werkzeuge

Wählen Sie Gruppen über `AgentBuiltInToolConfiguration.groups` aus; der Standard ist `.all`.
Einzelne Werkzeuge werden nur registriert, wenn ihre Abhängigkeiten verfügbar sind.
Die Auswahl einer Gruppe erzeugt nicht automatisch die benötigten Dienste.

| Gruppe | Werkzeuge | Abhängigkeiten |
| --- | --- | --- |
| Immer verfügbar | `scratch_list`, `scratch_read`, `scratch_search`, `scratch_write`, `scratch_replace`, `scratch_copy`, `scratch_move`, `scratch_diff`, `scratch_delete` | `workspace: AgentScratchWorkspace` |
| `.web` | `fetch`, `web_search`, `scratch_fetch` | `web: AgentWebFetching`, `search: AgentWebSearching` |
| `.userInteraction` | `request_user_input`, `request_user_secret` | Keine Katalogabhängigkeit; stellen Sie den Benutzerinteraktions-Handler der Runtime bereit |
| `.planning` | `present_plan` | Ein Arbeitsbereich und `plans: AgentPlanRecorder` |
| `.tasks` | `manage_tasks` | `tasks: AgentTaskList`; nur im Ausführungsmodus |
| `.skills` | `skill_read_file`, `skills_list`, `skill_manage`, `skill_install` | Katalog/Inventar für Lesezugriffe; `skillLibrary` für die Verwaltung; zusätzlich `skillPackageResolver` für die Installation |
| `.memory` | `memory_search`, `memory`, `session_search` | `memory: AgentMemoryAccessing`; Änderungen über `memory` nur im Ausführungsmodus |
| `.chatCollaboration` | `list_models`, `create_new_chat`, `list_chats`, `read_chat`, `send_to_chat`, `wait_chats` | `chatModels: AgentChatModelCatalog` für Modelllisten; `chats: AgentChatCoordinating` und `chatSource` für Chatoperationen |
| `.mcp` | Von konfigurierten Servern angebotene Werkzeuge | Einträge in `mcpServers` |

Werkzeuge zur Chat-Zusammenarbeit verwenden `.approve` und werden nur registriert, wenn der Host die
zugehörigen Dienste bereitstellt. Der Host verwaltet Chatlebenszyklen, Persistenz und eine dauerhaft
gespeicherte Deduplizierung der Zustellung. Vertrauenswürdige Presenter zeigen Ziele und Status kompakt an,
ohne Prompts, gesendete Nachrichten oder Transkripte zu wiederholen.
Erhalten Sie `AgentTranscriptMessage.origin` beim Speichern und Wiederherstellen agentenverfasster Nachrichten.
Diese Nachrichten werden weder als menschliche Autorisierungsbelege noch als Quelltext für das Lernen von Erinnerungen verwendet.

### Skills und Erinnerungen

- `skill_read_file` liest die `SKILL.md` eines aktivierten Skills oder begrenzte Ausschnitte seiner Hilfsdateien.
  `skills_list` kann deaktivierte und schreibgeschützte Skills aus `skillInventory` einschließen.
- `skill_manage` und `skill_install` sind auf den Ausführungsmodus beschränkt und verwenden die Genehmigungsrichtlinie
  `.ask`. Der Host stellt `AgentSkillLibraryManaging` bereit. Diese Implementierung muss Änderungen atomar
  gegen die geprüfte Revision übernehmen und schreibgeschützte Namen schützen.
  Änderungen werden im nächsten Lauf verfügbar.
- `GitHubSkillPackageResolver` ermittelt öffentliche GitHub-Pakete für die Installation.
  Die Vorprüfung lädt ein unveränderliches Paket herunter und legt es bereit.
  Die Genehmigung kontrolliert das Speichern der geprüften Bytes, nicht den Download.
  Bei der Installation werden niemals Skripte ausgeführt.
- `AgentMemoryAccessing` bietet Erinnerungsabruf bei Bedarf und die Suche in gespeicherten Sitzungen.
  Verwenden Sie `AgentMemoryContext` in einer Kontextpipeline, um eine widerrufbare Abrufrichtlinie ohne
  Erinnerungsinhalte einzufügen. `memory_search` liefert vollständige Einträge in begrenztem Umfang.
  Die lexikalische Suche zerlegt natürlichsprachliche Fragen in Begriffe, einschließlich chinesischer Wörter.
  Zuerst sucht sie Einträge, die alle bedeutungstragenden Begriffe enthalten. Nur wenn es keine Treffer gibt,
  erweitert sie die Suche auf Einträge mit mindestens einem passenden Begriff.
  Sie leitet keine Synonyme ab und übersetzt nicht zwischen Sprachen. `AgentSearchQuery` teilt diese
  Anfrageanalyse und das sichere Quotieren von FTS5-Suchbegriffen mit den host-eigenen `session_search`-Speichern.
  `AgentMemoryLearningService` schlägt geprüfte Aktualisierungen auf Basis begrenzter Referenzdaten vor.
  Der Host entscheidet, wann diese geprüft und angewendet werden.

Werkzeugregistrierung und Kontextinjektion sind getrennt: Übergeben Sie den `catalogBlock` des aktivierten
Katalogs über `AgentTurnContextSnapshot.skillCatalog`, damit das Modell Abläufe entdecken kann,
ohne sämtliche Skill-Inhalte zu laden. Gespeicherte Erinnerungen und historische Suchergebnisse sind
Referenzdaten, niemals Autorisierungen.

### Webinhalte abrufen und durchsuchen

Der Kern definiert `AgentWebFetching` und `AgentWebSearching` mit jeweils einer asynchronen Methode.
Implementieren Sie diese mit einem eigenen Extraktor oder einer Such-API oder fügen Sie das optionale Produkt hinzu:

```swift
.product(name: "AgentKitScrubber", package: "AgentKit")
```

Beim App-Start auf dem Main Actor:

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

Übergeben Sie die Konfiguration an `AgentToolCatalog.registry(builtIn:)`. Nur `web:` bereitzustellen,
aktiviert den Abruf, **nicht** `web_search`; `search:` ist eine eigenständige Abhängigkeit.
`scratch_fetch` verwendet den gemeinsamen Arbeitsbereich automatisch.

Unterstützen Anbieter und Modell die native Suche, können Sie stattdessen
`AgentProviderClient(webSearch:)` auf `true` setzen und `search:` weglassen.
Prüfen Sie zuerst `ModelProvider.supportsNativeWebSearch(model:)`: Protokollkompatibilität allein
garantiert nicht, dass ein Gateway serverseitige Suche implementiert.

## Anbieter

`AgentProviderClient` adaptiert vier `ModelAPIFormat`s: `.chatCompletions`, `.responses`, `.messages`
und `.generateContent`. Vertex verwendet `.generateContent` mit einer aus Projekt und Standort
abgeleiteten Adresse. Kompatible Gateways verwenden dieselben Formate, keine separaten Anbieterimplementierungen.

- **`inferenceURL` ist der vollständige Anfrageendpunkt.** Es werden weder Pfade noch Standardwerte angehängt.
  Verwenden Sie `{model}` an der Stelle der Modell-ID. Ein leerer Inferenzendpunkt führt zu einem Fehler,
  statt ein Ziel zu erraten.
- **`baseURL` ist die Basisadresse für Modelllisten.** `ModelCatalogClient` hängt `/models` an.
  Lassen Sie die Adresse leer, wenn der Endpunkt keine Modellliste anbietet. Der Aufrufer liefert beide URLs,
  statt sich auf eine Ableitung von Pfaden zu verlassen.
- **Anmeldedaten bleiben außerhalb der Konfiguration.** `credentialRef` ist ein Suchschlüssel des Hosts,
  nicht das Geheimnis selbst. Übergeben Sie den abgerufenen Wert als `secret:`.
  Bei einem Endpunkt ohne Authentifizierung verwenden Sie `secret: ""`; leere Authentifizierungsheader
  werden weggelassen. Die Vertex-Dienstkontoauthentifizierung erfordert weiterhin Anmeldedaten.
- **Funktionen werden explizit angegeben.** Verwenden Sie `AIModel.abilities` und `ModelCapabilityResolver`,
  um Werkzeugaufrufe, Reasoning, strukturierte Ausgaben und native Suche zu beschreiben,
  wenn diese Angaben in der Modellliste fehlen.

Live- und gepufferte Antworten teilen sich das Parsing pro Anfrage und die SSE-Rahmung.
Um die Anbieterschicht vollständig zu ersetzen, implementieren Sie `AgentModelStreaming`.
`AgentModelCompleting` unterstützt werkzeugfreie Funktionen, die eine vollständige Antwort benötigen.
Strukturierte Ausgaben werden über `AgentModelOutputFormat` transportiert und auf das gewählte
Protokoll abgebildet, wenn das Modell `.structuredOutput` deklariert.

## Genehmigung und Vertrauensgrenzen

Die Genehmigungsrichtlinie gehört zum jeweiligen Aufruf und wird lokal festgelegt:

| Richtlinie | Verhalten |
| --- | --- |
| `.deny` | In jedem Berechtigungsmodus ablehnen |
| `.approve` | Ohne weiteren Genehmigungsschritt ausführen |
| `.ask` | An den unten beschriebenen Berechtigungsmodus des Laufs delegieren |

| Berechtigungsmodus | Behandlung von `.ask`-Aufrufen |
| --- | --- |
| `.askForApproval` | Den `manualApproval`-Handler des Hosts fragen |
| `.approveForMe` | `GuardianReviewing` fragen; ein nicht verfügbarer Prüfer, Timeout oder eine ungültige Antwort führt zur Ablehnung |
| `.fullAccess` | Ausführen; Validierung, Werkzeugverfügbarkeit und andere strukturelle Prüfungen gelten weiterhin |

Operationen im temporären Arbeitsbereich und explizit aktiviertes `web_search` sind vorab genehmigt.
`fetch` und `scratch_fetch` verwenden `.ask`, da sie eine vom Aufrufer gewählte URL kontaktieren.
MCP-Werkzeuge verwenden die lokal gespeicherte Richtlinie des Hosts. Abgelehnte Werkzeuge bleiben
registriert, damit Aufrufversuche eine ausdrückliche Ablehnung erhalten.

`AgentApprovalHandling` ist eine verpflichtende Stufe des Executors. Hooks und Skills können sie
weder entfernen noch ersetzen. Der Wächter läuft im isolierten Modus `.reviewing`; standardmäßig
sind keine Untersuchungswerkzeuge registriert. `ReviewerReadOnlyApproval` erlaubt nur bereits
mit `.approve` markierte Aufrufe und bietet keinen Eskalationsweg. Das verhindert rekursive Prüfungen.
`GuardianSessionStore` bewahrt Autorisierungsgrundlagen und Entscheidungen in begrenztem Umfang
über Läufe hinweg auf, ohne sie in die Hauptunterhaltung einzumischen.

Vom Benutzer eingegebene Geheimnisse werden über löschbaren `AgentSecret`-Speicher und `SecretBroker`
als einmalig verwendbare Handles weitergegeben. `issue(secret)` speichert ein Geheimnis,
`consume(handle)` ruft es genau einmal ab. Der Aufrufer verwaltet den Lebenszyklus des Brokers,
kann ihn über mehrere Läufe hinweg verwenden und leert ihn mit `discardAll()`, wenn sein Gültigkeitsbereich endet.
`request_user_secret` nimmt `prompt`, den dem Benutzer angezeigten `purpose` und optional `timeout_seconds`
entgegen und gibt `secret_handle` und `single_use` zurück.
Der Klartext gelangt weder in Modelleingaben noch in Prüfungen, Ereignisse oder persistente Aufzeichnungen.
Werkzeugausgaben sind nicht vertrauenswürdige Daten. Die eng begrenzte Ausnahme ist die `SKILL.md`
eines installierten Skills: Sie darf Abläufe vorgeben, niemals Berechtigungen.
Die Hilfsdateien des Skills bleiben nicht vertrauenswürdige Referenzdaten.

## Gemeinsamer Scratch-Bereich und Werkzeugausgaben

Scratch ist verpflichtend und wird von allen Unterhaltungen derselben Anwendung auf diesem Gerät gemeinsam genutzt.
Übergeben Sie denselben Koordinator aus `AgentScratchWorkspace.shared(applicationName:)` an die
Werkzeugkonfiguration und `AgentLoopConfiguration.outputProjection`. Der Stamm ist Application Support /
applicationName / Scratch, ohne Unterhaltungs-ID. Löschen oder Verzweigen einer Unterhaltung löscht oder kopiert
keine Dateien. Der Agent muss aufgabenspezifische relative Pfade wählen und vorhandene Dateien vor dem
Überschreiben prüfen. Fehlende Elternverzeichnisse werden automatisch erstellt; Pfad-, Symlink- und
Kontingentprüfungen bleiben bestehen.

`AgentTruncateStrategy` unterstützt `head` (Standard), `tail`, `middle` und `none`. `AgentTruncateLimits` verwendet
standardmäßig 64 KiB (65.536 UTF-8-Bytes) und 2.000 logische Zeilen. Auch übergroße Einzelzeilen werden niemals
teilweise ausgegeben. Die Modellprojektion berücksichtigt JSON-Escaping und Hüllfelder. Seitenweise Lesezugriffe
behalten den tatsächlichen nächsten Offset und erzeugen weder einen Accumulator noch zusätzliche Ausgabedateien.

Die Erfassung ist je Werkzeug optional, kein Modellargument und kein Scratch-Schalter. Die folgende Factory erhält
eine Closure für den vollständigen Scratch-relativen Pfad, die erst bei Bedarf aufgerufen wird. Das Werkzeug
bestimmt Verzeichnis und Dateinamen; AgentKit erzwingt weder Präfix noch Erweiterung, erstellt Elternverzeichnisse,
prüft Pfadgrenzen und überschreibt keine Namenskollision. Empfohlen wird
`<conversationID>/outputs/<tool-name>-<UUID>.txt` mit Bindestrichen statt Unterstrichen im Werkzeugnamen. Dies
organisiert Dateien, isoliert aber keine Gespräche. Ohne conversationID kann runID verwendet werden. Ausgehende
MCP-Erfassungen verwenden den Namen des aufgerufenen Werkzeugs. Kumulative Schnappschüsse aktualisieren dieselbe
Datei. Nicht streamende Werkzeuge können `await accumulator.capturing(result)` verwenden.

AgentKit erzeugt nur zwei unübersetzte Marker: `[Showing lines <start>-<end> of <total>. Full output: <path>]` nach
erfolgreichem Speichern, sonst `[Showing lines <start>-<end> of <total>]`. Fehler sowie Offsets und Cursor zur
Fortsetzung bleiben separate Ergebnisfelder und bilden keine weiteren Marker. Das Einklappen der UI ist unabhängig
und erzeugt weder Kürzungsmarker noch Dateien. Die Darstellung kann den bei tatsächlicher Kürzung eingefrorenen
`AgentToolResult.truncateMarker` anzeigen. Ausgehende MCP-Ergebnisse verwenden `middle` mit Erfassung; Antworten an
externe Clients umgehen Modellkürzung und Scratch-Erfassung.

```swift
let conversationID = (context.conversationID ?? context.runID).uuidString.lowercased()
let accumulator = context.makeOutputAccumulator {
    "\(conversationID)/outputs/my-tool-\(UUID().uuidString.lowercased()).txt"
}
accumulator.append(Data("one complete line\n".utf8))
let snapshot = await accumulator.snapshot()
// snapshot.output, snapshot.capture?.path, snapshot.capture?.error
```

Scratch erlaubt 8 MiB pro Datei, 64 MiB pro Arbeitsbereich und 512 Einträge. Accumulatoren für das Modell halten
begrenzte Daten und ersetzen kumulative Schnappschüsse atomar; sie sind keine unbegrenzten Festplattenspools.
`snapshot(capturePath:)` speichert bei Bedarf einen separaten Schnappschuss unter einem werkzeugeigenen Pfad.
Kontingent- und Schreibfehler werden als `capture.error` gemeldet, ohne eine vollständige gespeicherte Kopie zu
versprechen.

Die Marker orientieren sich an Pis Zeilenbereichen. `middle` nennt beide erhaltenen Bereiche, unbekannte
Gesamtzahlen lassen `of <total>` weg, und eine übergroße Einzelzeile kann `[Showing 0 of 1 lines]` ergeben. Nur
erfolgreiche Erfassungen ergänzen `Full output: <path>`.

### Ausgaberichtlinien integrierter Werkzeuge

| Werkzeug / Ergebnis | Strategie | Automatische Erfassung |
| --- | --- | --- |
| `fetch`, `web_search` | `head` | Ja |
| MCP | `middle` | Ja |
| `scratch_read`, `skill_read_file` | `head`, seitenweise | Nein |
| `read_chat` | `head`, seitenweise | Nein |
| `scratch_search` | `head` | Nein |
| Andere integrierte Werkzeuge | `head` | Nein |
| Antworten an externe Clients | Umgehen | Nein |

`scratch_fetch` schreibt als Hauptoperation an das vom Aufrufer gewählte Ziel, nicht als automatische Erfassung.
Quellseitige Grenzen wie Ergebnisanzahl und Seitenfenster bleiben erhalten. Vertrauenswürdige installierte
`SKILL.md`-Anweisungen nutzen separate Import- und Validierungsgrenzen.

### Migration von 1.x

Verwenden Sie denselben gemeinsamen Workspace für Katalog und Ausgabeprojektion. `.scratch` bleibt als
Kompatibilitätslabel erhalten, schaltet Werkzeuge aber nicht mehr ab; ein nil-Workspace im Katalog nutzt
`.shared()`. `AgentToolOutputProjection.workspace` ist nicht mehr optional: Ersetzen Sie explizites `nil` durch
einen gemeinsamen Workspace. Das bisherige `conversationID`-Argument wählt kein Verzeichnis mehr, und `copyScope`
tut nichts mehr. Bestehende Gesprächsordner bleiben als normale relative Verzeichnisse erhalten; verwenden Sie beim
Lesen alter Dateien deren bisherige Ordnernamen. Löschen Sie gemeinsamen Scratch nicht mit einer Unterhaltung.
Werkzeuge müssen den Accumulator für automatische Erfassung ausdrücklich verwenden; die Projektion archiviert nicht
mehr jedes übergroße Ergebnis.

## AgentKit erweitern

| Erweiterungspunkt | Was der Host bereitstellt |
| --- | --- |
| `AgentToolDefinition` und `AgentToolCatalog.registry(builtIn:additional:)` | Domänenspezifische Werkzeuge, ohne integrierte Werkzeuge zu verdecken |
| `AgentToolServices` | Typisierten Zugriff auf app-eigene Verbindungen und Dienste |
| `AgentLoopHook` | Verhalten für `willExecute`, `didExecute` und `shouldStop`; `AgentPlanModeHook` liefert Einschränkungen und Beendigung im Planungsmodus |
| `AgentContextTransforming` | Zusätzliche Modelleingabeprojektionen, kombiniert mit der Standardkontextpipeline |
| `AgentModelStreaming` / `AgentModelCompleting` | Eigene Anbieter, Proxys oder deterministische Testmodelle |
| `AgentRunPersisting` | Dauerhafte Speicherung von Unterhaltungen, Laufsnapshots, Ereignissen und Komprimierungsaufzeichnungen |
| `AgentSkillLibraryManaging` / `AgentMemoryAccessing` | Speicherung, Änderung und Synchronisierung von Skills und Erinnerungen |

Werkzeuge sind standardmäßig in `.planning` und `.acting` verfügbar. Schränken Sie Registrierungen mit
`AgentToolTypeRegistration(_:availableIn:make:)` oder `AnyAgentTool(_:availableIn:)` ein.
Nicht verfügbare Werkzeuge fehlen sowohl in Modellanfragen als auch bei der Suche des Executors.
Registrierungen für nicht überlappende Modi dürfen denselben Namen verwenden, einschließlich
separater Schemas und Implementierungen für den Wächter-Modus `.reviewing`.

## Was Ihre App verantwortet

- Chatoberfläche, Genehmigungs- und Eingabedialoge sowie die Darstellung von Werkzeugkarten.
  `AgentToolDetail` und vertrauenswürdige Presenter liefern Darstellungswerte, keine Views.
- Speicherung von Anmeldedaten, dauerhafte Datenbanken und Lebenszyklen app-eigener Dienste.
- Shell-/SSH-Ausführung und allgemeiner Dateisystemzugriff. Integrierte Dateiwerkzeuge bleiben auf
  den temporären Arbeitsbereich beschränkt; weitergehende Zugriffe gehören in Ihre eigenen Werkzeuge.
  HTTP-Clients für Anbieter und MCP-Clients sind enthalten.
- Die Entscheidung, wann Kontext komprimiert, Unterhaltungstitel erzeugt oder Erinnerungen gelernt werden.
  Diese Dienste starten von sich aus keine Hintergrundarbeit.

## Lokalisierung

Benutzerseitige Texte liegen in `Localizations/Localizable.xcstrings` vor: Englisch, Deutsch, Französisch,
Japanisch, Koreanisch sowie vereinfachtes und traditionelles Chinesisch.
`Scripts/build-localizations.sh` kompiliert sie nach `Sources/AgentKit/Resources/*.lproj`.
Führen Sie das Skript nach Katalogänderungen erneut aus und committen Sie die erzeugten Ressourcen.
`swift build` kopiert diese lediglich, statt Zeichenfolgenkataloge zu kompilieren.
`python3 Scripts/check-localization.py` prüft Vollständigkeit, Formatargumente, Pluralformen und
sprachspezifische Abstandsregeln aller sechs Übersetzungssprachen.

Werkzeugkarten lösen Texte bei der Darstellung anhand der Locale des Lesers auf.
Eine bereits aufgezeichnete Karte kann deshalb in einer anderen Sprache angezeigt werden.

## Danksagungen

AgentKit baut auf Ideen und Arbeit der folgenden Projekte auf.
Entwurfsreferenzen sind von adaptiertem Code und Paketabhängigkeiten zu unterscheiden.

### Entwurfsreferenzen

- **[Pi](https://github.com/badlogic/pi-mono)** — die Modell-Stream-Grenze (`streamFn`), werkzeugbezogene
  Fortschrittsmeldungen (`onUpdate`), konservatives Batch-Scheduling, Komprimierung an Rundengrenzen
  und das Bearbeiten temporärer Dateien. Diese Ideen sind in Swift in `AgentTurnDriver`,
  `AgentToolExecutor`, `AgentToolScheduler`, `AgentCompactionService` und `AgentScratchWorkspace` umgesetzt.
- **[pi-plan-mode](https://github.com/narumiruna/pi-extensions/tree/main/packages/pi-plan-mode)** —
  der verborgene, versionierte Planvertrag und der explizite Abschluss eines Planungslaufs.
  AgentKit setzt diese Ideen mit `AgentPlanContractInjection` und `AgentPlanModeHook` um,
  statt einen Lauf auszusetzen, während der Benutzer einen Plan prüft.
- **[pi-approval-guardian](https://github.com/mics8128/pi-approval-guardian)** — Grundlage der
  Wächter-Richtlinie und des Prüfablaufs, der bei Fehlern ablehnt. Dazu gehören eine anfängliche
  Autorisierungsgrundlage und anschließend inkrementelle Belege. AgentKit überträgt dies auf
  anbieterneutrale Swift-Typen und eine vom Host kontrollierte Genehmigungsgrenze.
- **[OpenAI Codex](https://github.com/openai/codex)** — Verhaltensreferenz für automatische Prüfung
  und strukturierte Benutzerfragen in begrenzter Anzahl. Dies ist keine Runtime-Abhängigkeit.

### Adaptierter Code

- **[LanguageModelChatUI](https://github.com/Lakr233/LanguageModelChatUI)** von Lakr233 —
  `BalancedEmitter` ist aus der MIT-lizenzierten Implementierung adaptiert.
  Er taktet gestreamten Text in begrenzte, geordnete Aktualisierungen.

### Optionale Abhängigkeiten

- **[ScrubberKit](https://github.com/Lakr233/ScrubberKit)** von Lakr233 — die MIT-lizenzierte
  Implementierung für Seitenextraktion und Suche hinter `AgentKitScrubber`.
  `AgentWebDocument` bewahrt die gemeinsame Struktur aus lesbarem Markdown und Originaldokument.
  Das Kerntarget `AgentKit` hängt nicht davon ab.

Jedes Ursprungsprojekt behält seine eigenen Urheberrechte und seine eigene Lizenz.
Mitwirkende, Quellcode und geltende Hinweise finden Sie in den verlinkten Repositorys.

## Lizenz

Dieses Repository steht unter der [MIT-Lizenz](./LICENSE).

SPDX-License-Identifier: [MIT](https://spdx.org/licenses/MIT.html)
