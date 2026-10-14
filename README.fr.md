# AgentKit

[Deutsch](README.de.md) · [English](README.md) · **Français** · [日本語](README.ja.md) · [한국어](README.ko.md) · [简体中文（中国）](README.zh-CN.md) · [正體中文（臺灣）](README.zh-TW.md)

Créez des agents IA en Swift avec orchestration d’outils, permissions explicites et état de conversation persistant.

## À quoi sert AgentKit ?

Créez des assistants qui agissent au moyen des outils de votre app, au lieu de simplement générer du texte.
AgentKit prend en charge la boucle entre le modèle et les outils, les approbations et l’état de la conversation.
Votre app fournit l’interface, les identifiants d’authentification, le stockage et les fonctionnalités métier.

## Installation

Nécessite **macOS 15+ ou iOS 18+**, ainsi qu’une chaîne d’outils **Swift 6.2+**.

Ajoutez la dépendance au package :

```swift
.package(url: "https://github.com/AkinoKaede/AgentKit.git", from: "0.19.2")
```

Ajoutez ensuite le produit principal à votre cible :

```swift
.product(name: "AgentKit", package: "AgentKit")
```

La cible `AgentKit` n’a aucune dépendance tierce. Le produit facultatif `AgentKitScrubber` fournit
un client web reposant sur ScrubberKit, sans imposer de dépendance à WebKit au cœur du package.

## Utilisation

Cet exemple utilise un point de terminaison Responses et active uniquement les outils de l’espace
de travail temporaire privé de la conversation. Appelez-le depuis un contexte asynchrone en fournissant
une clé API issue du stockage d’identifiants de votre app, ainsi qu’une closure `manualApproval`
qui présente votre interface d’approbation et renvoie `.allow` ou `.deny(reason)`.

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

Les opérations dans l’espace de travail temporaire sont préapprouvées, car elles restent limitées au
stockage géré par l’app. Le rappel est utilisé lorsque vous ajoutez des outils dont la politique est `.ask`.
L’absence de vérificateur Gardien (Guardian) n’affecte pas `.askForApproval`, mais entraîne le refus
de ces appels en mode `.approveForMe`, par mesure de sécurité.

Pour intégrer AgentKit à votre app :

- **Une instance du runtime par exécution.** `start(_:)` renvoie un `AsyncStream<AgentEvent>` destiné à un seul
  consommateur. Conservez le runtime pendant l’exécution pour que l’interface puisse appeler `steer(_:)` ou `cancel()`.
- **Poursuivre une conversation.** Réutilisez son `conversationID` et fournissez `priorMessages` ;
  le runtime ne charge pas l’historique à votre place. Si le contexte a été compacté, utilisez le
  `modelTranscript` restauré. Fournissez un dépôt `AgentRunPersisting` pour le stockage durable ;
  par défaut, les données restent en mémoire.
- **Afficher la sortie en streaming.** Traitez `.messageDelta` et `.reasoningDelta` pour les mises à jour en direct.
  À la réception de `.modelRetryScheduled`, abandonnez la sortie partielle du message concerné et utilisez
  `.messageFinished` comme résultat définitif. L’exemple n’affiche que les messages terminés.
- **Raccorder séparément les interactions utilisateur.** `.userInteraction` enregistre les outils, mais leur
  interface nécessite un `AgentUserInteractionHandling` passé dans `userInteraction:`.
  Pour inclure les événements d’approbation et de vérification dans le même flux, transmettez un
  `AgentEventChannel` partagé au runtime et son rappel `emit` au paramètre `event:` du courtier d’approbation.
- **Séparer l’intention de l’utilisateur du contexte.** `authoredPrompt` contient le texte original de l’utilisateur ;
  `prompt` peut inclure du contexte ajouté par l’app. `authorizationEvidence` ne doit contenir que des éléments
  d’autorisation provenant directement de l’utilisateur. Incluez `AgentSystemPrompt.default` dans tout prompt
  système personnalisé.

## Architecture

`AgentRuntime` coordonne l’exécution ; il ne regroupe pas les fournisseurs et les outils dans une
implémentation monolithique. Il gère la tâche, l’instantané de la conversation, la file d’instructions
supplémentaires et le canal d’événements d’une exécution, puis délègue chaque phase à un composant testable séparément.

### Déroulement d’une exécution

1. **Déterminer les capacités disponibles.** Filtrez `AgentToolRegistry` selon le mode d’exécution
   (`.planning`, `.acting` ou `.reviewing`). Le modèle et l’exécuteur utilisent le même ensemble d’outils résolu.
2. **Préparer l’entrée du modèle.** `AgentContextPipeline` construit la transcription destinée au modèle.
   Il réapplique les projections figées du contexte et des sorties, et répare l’ordre des messages d’outils
   sans raccourcir l’historique affiché.
3. **Diffuser un tour.** `AgentTurnDriver` appelle `AgentModelStreaming`, assemble le message de l’assistant
   et les appels d’outils, puis publie la progression via `AgentEventChannel`.
4. **Planifier le lot d’outils.** `AgentToolExecutor` valide les arguments et effectue les vérifications
   préalables locales. `AgentToolScheduler` utilise ces résultats pour choisir une exécution séquentielle
   ou une exécution parallèle à concurrence limitée.
5. **Autoriser et exécuter.** Chaque appel prêt passe par `willExecute`, le contrôle d’approbation,
   l’exécution de l’outil et `didExecute`. Les hooks peuvent bloquer des appels, mais pas contourner l’autorisation.
6. **Enregistrer et recommencer.** Ajoutez les résultats dans l’ordre initial des appels du modèle,
   enregistrez l’instantané via `AgentRunPersisting`, transmettez les instructions en attente à la prochaine
   étape d’appel du modèle, puis interrogez-le à nouveau. L’exécution se termine lorsqu’il ne reste ni appel
   d’outil ni instruction en attente, ou lorsqu’un hook, une erreur ou une annulation y met fin.

### Organisation du code

Les répertoires du cœur répartissent les responsabilités au sein d’une seule cible SPM.
`AgentKitScrubber` est un produit facultatif distinct.

| Zone | Responsabilité | Types principaux |
| --- | --- | --- |
| [`Core`](Sources/AgentKit/Core) | Messages, événements, requêtes d’exécution, compétences et données de mémoire partagés | `AgentTranscriptMessage`, `AgentEvent`, `AgentRunRequest`, `AgentSkill`, `AgentMemoryState` |
| [`Runtime`](Sources/AgentKit/Runtime) | Cycle de vie, streaming des tours, ordonnancement, projection du contexte, compactage et contrats de persistance | `AgentRuntime`, `AgentTurnDriver`, `AgentToolScheduler`, `AgentToolExecutor`, `AgentContextPipeline` |
| [`Providers`](Sources/AgentKit/Providers) | Adaptateurs HTTP/SSE, authentification, découverte des modèles et détermination des capacités | `AgentProviderClient`, `ModelProvider`, `AIModel`, `ModelCatalogClient` |
| [`Tools`](Sources/AgentKit/Tools) | Contrats, enregistrement, schémas, outils intégrés et données de présentation | `AgentToolDefinition`, `AnyAgentTool`, `AgentToolCatalog`, `AgentToolServices`, `AgentToolDetail` |
| [`Security`](Sources/AgentKit/Security) | Politique locale d’approbation, vérification par le Gardien, références aux secrets et masquage des données sensibles | `AgentApprovalBroker`, `GuardianClient`, `GuardianSessionStore`, `SecretBroker` |
| [`MCP`](Sources/AgentKit/MCP) | Configuration des serveurs distants et client du protocole ; intégration au registre d’outils via `Tools/MCP` | `MCPServer`, `MCPClient`, `AgentMCPTools` |
| [`Services`](Sources/AgentKit/Services) | Fonctions sans outils, appelées par l’hôte en dehors de la boucle principale | `ConversationTitleService`, `AgentMemoryLearningService` |
| [`AgentKitScrubber`](Sources/AgentKitScrubber) | Produit facultatif implémentant la récupération et la recherche web | `ScrubberWebClient` |

### Fonctionnement interne des fournisseurs

`AgentProviderClient` gère le transport HTTP, les identifiants, l’annulation, les limites de taille
et la classification des erreurs pour les nouvelles tentatives. Son `AgentProviderRequestEncoder`
interne prépare une seule fois l’ordre des outils et les capacités du modèle, puis construit la
structure de requête native du protocole choisi, sans accéder au réseau.

`AgentProviderResponseParser` gère les identités des outils et l’état de terminaison de chaque réponse.
Il utilise `AgentProviderResponseDecoder` pour les réponses en direct comme pour celles mises en mémoire tampon.
Les décodeurs propres à chaque format se trouvent dans les fichiers `+Responses`, `+ChatCompletions`,
`+Anthropic` et `+Google`. Toute nouvelle requête ou tentative repart d’un état neuf.
Les adaptateurs statiques publics d’`AgentProviderClient` restent des points d’entrée de compatibilité.

Le code partagé respecte la sémantique des protocoles : les deux formats OpenAI réutilisent l’encodage
des schémas de sortie structurée et la conversion de l’utilisation des jetons, tandis que les décomptes
de cache disjoints d’Anthropic restent séparés. Les Chat Completions en direct continuent d’être lues
après le motif de terminaison, car les données d’utilisation peuvent arriver ensuite.

### Garanties du runtime

- **Politique établie localement.** Les vérifications préalables déterminent la politique d’approbation et la
  concurrence de chaque appel. Ni les affirmations du modèle ni les annotations MCP distantes ne peuvent
  l’approuver. Une indication distante d’opération destructive peut uniquement restreindre l’ordonnancement
  à une exécution séquentielle.
- **Concurrence prudente.** Un lot ne s’exécute en parallèle que si tous les appels exécutables et la configuration
  l’autorisent. Un seul appel séquentiel impose une exécution séquentielle à tout le lot.
  Les résultats rejoignent toujours la transcription dans l’ordre des appels.
- **Transcriptions récupérables.** Les lots refusés ou annulés répondent tout de même à chaque appel d’outil.
  Après un plantage, les appels sans résultat sont marqués comme ayant une *issue inconnue*, et non comme
  n’ayant jamais été exécutés. Le modèle n’est donc pas incité à répéter une action peut-être déjà terminée.
- **Nouvelles tentatives sans réexécution des outils.** Les erreurs temporaires du fournisseur déclenchent
  jusqu’à cinq nouvelles tentatives de la requête de modèle en cours, après 1, 2, 4, 8 et 16 secondes.
  Les outils ne s’exécutent qu’une fois le flux terminé. Ce comportement se configure via
  `AgentLoopConfiguration.modelRetryPolicy`. Les modèles personnalisés désignent les erreurs réessayables
  au moyen de `shouldRetry(after:)`.
- **Instructions supplémentaires sans annulation forcée.** `steer(_:)` met un message en file pour la prochaine
  étape d’appel du modèle. Les outils en attente peuvent choisir de recevoir le signal d’interjection ;
  les outils ordinaires en cours d’exécution ne sont pas arrêtés de force.
- **Historique et contexte du modèle séparés.** Les projections de sortie figées et le compactage déclenché
  par l’hôte réduisent l’entrée du modèle sans remplacer l’historique affiché.
  La boucle n’impose aucune limite de tours ou d’appels d’outils. L’hôte décide quand appeler
  `AgentCompactionService` et conserver durablement ses enregistrements.

## Outils intégrés

Sélectionnez les groupes avec `AgentBuiltInToolConfiguration.groups` ; la valeur par défaut est `.all`.
Chaque outil n’est enregistré que si ses dépendances sont disponibles.
La sélection d’un groupe ne crée pas ses services.

| Groupe | Outils | Dépendances |
| --- | --- | --- |
| `.scratch` | `scratch_list`, `scratch_read`, `scratch_search`, `scratch_write`, `scratch_replace`, `scratch_copy`, `scratch_move`, `scratch_diff`, `scratch_delete` | `workspace: AgentScratchWorkspace` |
| `.web` | `fetch`, `web_search`, `scratch_fetch` | `web: AgentWebFetching` pour la récupération ; `search: AgentWebSearching` pour la recherche ; `scratch_fetch` nécessite aussi `.scratch` et un espace de travail |
| `.userInteraction` | `request_user_input`, `request_user_secret` | Aucune dépendance du catalogue ; fournir le gestionnaire d’interactions utilisateur du runtime |
| `.planning` | `present_plan` | Un espace de travail et `plans: AgentPlanRecorder` |
| `.tasks` | `manage_tasks` | `tasks: AgentTaskList` ; uniquement en mode action |
| `.skills` | `skill_read_file`, `skills_list`, `skill_manage`, `skill_install` | Catalogue/inventaire pour la lecture ; `skillLibrary` pour la gestion ; également `skillPackageResolver` pour l’installation |
| `.memory` | `memory_search`, `memory`, `session_search` | `memory: AgentMemoryAccessing` ; les modifications via `memory` sont réservées au mode action |
| `.chatCollaboration` | `list_models`, `create_new_chat`, `list_chats`, `read_chat`, `send_to_chat`, `wait_chats` | `chatModels: AgentChatModelCatalog` pour la liste des modèles ; `chats: AgentChatCoordinating` et `chatSource` pour les opérations de chat |
| `.mcp` | Outils annoncés par les serveurs configurés | Entrées de `mcpServers` |

Les outils de collaboration entre chats utilisent `.approve` et ne sont enregistrés que si l’hôte
fournit leurs services. L’hôte gère le cycle de vie des chats, la persistance et la déduplication
durable des livraisons. Les présentateurs de confiance affichent les destinations et les états de
façon compacte, sans répéter les prompts, les messages envoyés ou les transcriptions.
Préservez `AgentTranscriptMessage.origin` lors du stockage et de la restauration de messages rédigés
par un agent : ces messages sont exclus des preuves d’autorisation humaine et des textes sources
servant à l’apprentissage de la mémoire.

### Compétences et mémoire

- `skill_read_file` lit le fichier `SKILL.md` d’une compétence activée ou des plages limitées de ses
  fichiers complémentaires. `skills_list` peut inclure les compétences désactivées et en lecture seule
  de `skillInventory`.
- `skill_manage` et `skill_install` sont réservés au mode action et utilisent l’approbation `.ask`.
  L’hôte fournit `AgentSkillLibraryManaging`, qui doit appliquer les changements de façon atomique par
  rapport à la révision examinée et protéger les noms en lecture seule.
  Les changements sont disponibles à l’exécution suivante.
- `GitHubSkillPackageResolver` résout les packages GitHub publics à installer.
  Les vérifications préalables téléchargent et préparent un package immuable.
  L’approbation contrôle l’enregistrement des octets examinés, pas leur téléchargement.
  L’installation n’exécute jamais de scripts.
- `AgentMemoryAccessing` fournit un accès à la mémoire à la demande et une recherche dans les sessions sauvegardées.
  Utilisez `AgentMemoryContext` dans un pipeline de contexte pour injecter une politique de récupération
  révocable, sans le contenu de la mémoire. `memory_search` renvoie des entrées complètes dans des limites définies.
  Sa recherche lexicale découpe les questions en langage naturel en termes, y compris les mots chinois.
  Elle recherche d’abord les entrées correspondant à tous les termes significatifs, puis élargit à celles
  correspondant à au moins un terme uniquement si aucun résultat n’a été trouvé.
  Elle ne déduit pas de synonymes et ne traduit pas entre les langues. `AgentSearchQuery` partage cette analyse
  des requêtes et la mise entre guillemets sûre des termes FTS5 avec les stockages `session_search` gérés par l’hôte.
  `AgentMemoryLearningService` propose des mises à jour validées à partir de données de référence de portée limitée.
  L’hôte décide quand les examiner et les appliquer.

L’enregistrement des outils et l’injection de contexte sont distincts : transmettez le `catalogBlock`
du catalogue activé via `AgentTurnContextSnapshot.skillCatalog` pour que le modèle découvre les procédures
sans charger tous leurs contenus. La mémoire sauvegardée et les résultats de recherche historiques
sont des données de référence, jamais des autorisations.

### Récupération et recherche web

Le cœur définit `AgentWebFetching` et `AgentWebSearching`, chacun avec une méthode asynchrone.
Implémentez-les avec votre propre extracteur ou API de recherche, ou ajoutez le produit facultatif :

```swift
.product(name: "AgentKitScrubber", package: "AgentKit")
```

Au lancement de l’app, sur l’acteur principal :

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

Transmettez cette configuration à `AgentToolCatalog.registry(builtIn:)`.
Fournir uniquement `web:` active la récupération, **pas** `web_search` ; `search:` est une dépendance indépendante.
Pour activer `scratch_fetch`, sélectionnez également `.scratch` et fournissez un espace de travail.

Si le fournisseur et le modèle prennent en charge la recherche native, vous pouvez à la place définir
`AgentProviderClient(webSearch:)` à `true` et omettre `search:`.
Vérifiez d’abord `ModelProvider.supportsNativeWebSearch(model:)` : la compatibilité du protocole ne garantit
pas à elle seule qu’une passerelle implémente la recherche côté serveur.

## Fournisseurs

`AgentProviderClient` adapte quatre `ModelAPIFormat` : `.chatCompletions`, `.responses`, `.messages`
et `.generateContent`. Vertex utilise `.generateContent`, avec une adresse dérivée du projet et de
la localisation. Les passerelles compatibles utilisent ces mêmes formats, sans implémentation distincte par fournisseur.

- **`inferenceURL` est le point de terminaison complet de la requête.** Aucun chemin ni valeur par défaut
  n’est ajouté. Utilisez `{model}` à l’emplacement de l’identifiant du modèle.
  Un point de terminaison d’inférence vide provoque un échec plutôt qu’une destination devinée.
- **`baseURL` est la racine de la liste des modèles.** `ModelCatalogClient` y ajoute `/models`.
  Laissez cette valeur vide si le point de terminaison ne propose pas de liste.
  L’appelant fournit les deux URL, sans dépendre d’une déduction des chemins.
- **Les identifiants restent hors de la configuration.** `credentialRef` est une clé de recherche de l’hôte,
  pas le secret lui-même. Passez la valeur récupérée dans `secret:`.
  Pour un point de terminaison sans authentification, passez `secret: ""` ; les en-têtes d’authentification
  vides sont omis. L’authentification par compte de service Vertex nécessite toujours des identifiants.
- **Les capacités sont explicites.** Utilisez `AIModel.abilities` et `ModelCapabilityResolver` pour décrire
  les appels d’outils, le raisonnement, la sortie structurée et la recherche native lorsque la liste des modèles les omet.

Les réponses en direct et celles mises en mémoire tampon partagent l’analyse propre à chaque requête
et le découpage des trames SSE. Pour remplacer entièrement la couche fournisseur, implémentez
`AgentModelStreaming`. `AgentModelCompleting` prend en charge les fonctionnalités sans outils qui
nécessitent une réponse complète. La sortie structurée est transportée par `AgentModelOutputFormat`
et adaptée au protocole choisi lorsque le modèle déclare `.structuredOutput`.

## Approbation et frontières de confiance

La politique d’approbation appartient à chaque appel et est établie localement :

| Politique | Comportement |
| --- | --- |
| `.deny` | Refuser dans tous les modes de permission |
| `.approve` | Exécuter sans étape d’approbation supplémentaire |
| `.ask` | Déléguer au mode de permission de l’exécution décrit ci-dessous |

| Mode de permission | Traitement des appels `.ask` |
| --- | --- |
| `.askForApproval` | Interroger le gestionnaire `manualApproval` de l’hôte |
| `.approveForMe` | Interroger `GuardianReviewing` ; refus si le vérificateur est indisponible, si le délai expire ou si la réponse est invalide |
| `.fullAccess` | Exécuter tout en conservant la validation, la vérification de disponibilité des outils et les autres contrôles structurels |

Les opérations de l’espace de travail temporaire et `web_search` explicitement activé sont préapprouvés.
`fetch` et `scratch_fetch` utilisent `.ask`, car ils contactent une URL choisie par l’appelant.
Les outils MCP utilisent la politique stockée localement par l’hôte ; les outils refusés restent
enregistrés afin que les tentatives d’appel reçoivent un refus explicite.

`AgentApprovalHandling` est une étape obligatoire de l’exécuteur. Les hooks et les compétences ne
peuvent ni la supprimer ni la remplacer. Le Gardien s’exécute dans un mode `.reviewing` isolé, sans
outil d’investigation enregistré par défaut. `ReviewerReadOnlyApproval` n’autorise que les appels
déjà marqués `.approve` et ne permet aucune escalade de l’approbation, ce qui empêche les vérifications récursives.
`GuardianSessionStore` conserve des bases d’autorisation et des décisions de portée limitée entre
les exécutions, sans les mélanger à la conversation principale.

Les secrets saisis par l’utilisateur passent par un stockage `AgentSecret` effaçable et par
`SecretBroker`, sous forme de références à usage unique liées à l’exécution, à l’outil et à la finalité.
Le texte en clair est exclu des entrées du modèle, des vérifications, des événements et de la persistance.
Les sorties des outils sont des données non fiables. La seule exception, étroitement délimitée,
est le fichier `SKILL.md` d’une compétence installée : il peut fournir des procédures, jamais des permissions.
Ses fichiers complémentaires restent des données de référence non fiables.

## Étendre AgentKit

| Point d’extension | Ce que fournit l’hôte |
| --- | --- |
| `AgentToolDefinition` et `AgentToolCatalog.registry(builtIn:additional:)` | Outils métier, ajoutés sans masquer les outils intégrés |
| `AgentToolServices` | Accès typé aux connexions et services gérés par l’app |
| `AgentLoopHook` | Comportements `willExecute`, `didExecute` et `shouldStop` ; `AgentPlanModeHook` fournit les restrictions et la terminaison du mode Plan |
| `AgentContextTransforming` | Projections supplémentaires de l’entrée du modèle, combinées au pipeline de contexte par défaut |
| `AgentModelStreaming` / `AgentModelCompleting` | Fournisseurs personnalisés, proxys ou modèles de test déterministes |
| `AgentRunPersisting` | Stockage durable des conversations, instantanés d’exécution, événements et enregistrements de compactage |
| `AgentSkillLibraryManaging` / `AgentMemoryAccessing` | Stockage, modification et synchronisation des compétences et de la mémoire |

Les outils sont disponibles par défaut en modes `.planning` et `.acting`.
Restreignez les enregistrements avec `AgentToolTypeRegistration(_:availableIn:make:)` ou
`AnyAgentTool(_:availableIn:)` : les outils indisponibles sont absents à la fois des requêtes du
modèle et des recherches de l’exécuteur. Des enregistrements propres à des modes disjoints peuvent
partager un nom, notamment avec des schémas et implémentations distincts pour le mode `.reviewing` du Gardien.

## Ce que votre app prend en charge

- L’interface de chat, les écrans d’approbation et de saisie, ainsi que l’affichage des cartes d’outils.
  `AgentToolDetail` et les présentateurs de confiance fournissent des données d’affichage, pas des vues.
- Le stockage des identifiants, les bases de données durables et le cycle de vie des services de l’app.
- L’exécution Shell/SSH et l’accès général au système de fichiers. Les outils de fichiers intégrés
  restent confinés à l’espace de travail temporaire ; les accès plus larges relèvent de vos propres outils.
  Les clients HTTP des fournisseurs et les clients MCP sont inclus.
- Le choix du moment où compacter le contexte, générer des titres de conversation ou lancer l’apprentissage
  de la mémoire. Ces services ne démarrent pas spontanément de tâches en arrière-plan.

## Localisation

Les textes destinés aux utilisateurs se trouvent dans `Localizations/Localizable.xcstrings`, en anglais,
allemand, français, japonais, coréen, chinois simplifié et chinois traditionnel.
`Scripts/build-localizations.sh` les compile dans `Sources/AgentKit/Resources/*.lproj`.
Relancez ce script après toute modification du catalogue et commitez les ressources générées :
`swift build` les copie au lieu de compiler les catalogues de chaînes.
Exécutez `python3 Scripts/check-localization.py` pour vérifier la couverture, les arguments de format,
les pluriels et les règles d’espacement propres aux six langues traduites.

Les cartes d’outils résolvent leurs textes au moment de l’affichage selon la locale du lecteur.
Une carte déjà enregistrée peut donc être affichée dans une autre langue.

## Remerciements

AgentKit s’appuie sur les idées et les travaux des projets suivants.
Les références de conception sont distinctes du code adapté et des dépendances de packages.

### Références de conception

- **[Pi](https://github.com/badlogic/pi-mono)** — la frontière du flux du modèle (`streamFn`),
  la progression propre à chaque outil (`onUpdate`), l’ordonnancement prudent des lots,
  le compactage entre les tours et le comportement d’édition des fichiers temporaires.
  Ces idées sont implémentées en Swift dans `AgentTurnDriver`, `AgentToolExecutor`,
  `AgentToolScheduler`, `AgentCompactionService` et `AgentScratchWorkspace`.
- **[pi-plan-mode](https://github.com/narumiruna/pi-extensions/tree/main/packages/pi-plan-mode)** —
  le contrat de plan masqué et versionné, ainsi que la clôture explicite d’une exécution de planification.
  AgentKit exprime ces idées avec `AgentPlanContractInjection` et `AgentPlanModeHook`,
  plutôt qu’en suspendant l’exécution pendant que l’utilisateur examine un plan.
- **[pi-approval-guardian](https://github.com/mics8128/pi-approval-guardian)** — la base de la politique
  du Gardien et du processus de vérification qui refuse l’exécution en cas d’échec, avec une base
  d’autorisation initiale suivie d’éléments de preuve incrémentaux.
  AgentKit l’adapte à des types Swift indépendants des fournisseurs et à une frontière d’approbation contrôlée par l’hôte.
- **[OpenAI Codex](https://github.com/openai/codex)** — référence de comportement pour la vérification
  automatique et les questions structurées à l’utilisateur en nombre limité.
  Il ne s’agit pas d’une dépendance du runtime.

### Code adapté

- **[LanguageModelChatUI](https://github.com/Lakr233/LanguageModelChatUI)** de Lakr233 —
  `BalancedEmitter` est adapté de son implémentation sous licence MIT afin de réguler le texte
  en streaming sous forme de mises à jour ordonnées et de taille limitée.

### Dépendances facultatives

- **[ScrubberKit](https://github.com/Lakr233/ScrubberKit)** de Lakr233 — l’implémentation sous licence MIT
  de l’extraction de pages et de la recherche utilisée par `AgentKitScrubber`.
  `AgentWebDocument` conserve sa structure associant Markdown lisible et document original.
  La cible principale `AgentKit` n’en dépend pas.

Chaque projet d’origine conserve ses propres droits d’auteur et sa licence.
Consultez les dépôts liés pour connaître les contributeurs, le code source et les mentions applicables.

## Licence

Ce dépôt est distribué sous [licence MIT](./LICENSE).

SPDX-License-Identifier: [MIT](https://spdx.org/licenses/MIT.html)
