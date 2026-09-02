import Foundation

/// One selectable family of built-in tools.
///
/// Selection is by group rather than by name because the tools inside one are
/// only useful together: `scratch_read` without `scratch_write` is a directory
/// nothing can put anything in, and `scratch_edit` without `scratch_diff` is an
/// edit nobody can check. An app that genuinely wants a subset of a group can
/// still take the group and filter the registry — see
/// `AgentToolRegistry.filtering(_:)` — but that is an unusual thing to want, and
/// the ordinary choice is which capabilities the agent has at all.
///
/// Open rather than an enum, for symmetry with the presentation vocabularies: an
/// app grouping its own registrations names its groups the same way.
public nonisolated struct AgentToolGroup: RawRepresentable, Hashable, Sendable {
    public let rawValue: String

    public init(rawValue: String) { self.rawValue = rawValue }
    public init(_ rawValue: String) { self.rawValue = rawValue }

    /// `scratch_list`, `scratch_read`, `scratch_search`, `scratch_write`,
    /// `scratch_edit`, `scratch_diff`, `scratch_delete`. Needs a workspace.
    public static let scratch = Self("scratch")
    /// `fetch`, `web_search`, `scratch_fetch`. Needs a fetcher; `web_search`
    /// additionally needs a searcher and `scratch_fetch` a workspace.
    public static let web = Self("web")
    /// `request_user_input`, `request_user_secret`. Needs nothing: the handler
    /// comes from the run rather than from this configuration.
    public static let userInteraction = Self("userInteraction")
    /// `present_plan`. Needs a workspace and a recorder — a plan is drafted in
    /// the workspace and read from there, never typed into the tool call.
    public static let planning = Self("planning")
    /// `manage_tasks`. Needs a task list.
    public static let tasks = Self("tasks")
    /// `load_skill`. Needs a non-empty catalog; an empty one removes the tool
    /// rather than offering one with nothing to read.
    public static let skills = Self("skills")
    /// Whatever the configured MCP servers advertise. Needs servers.
    public static let mcp = Self("mcp")

}
nonisolated

    extension Set where Element == AgentToolGroup
{
    /// Every group the runtime ships, which is the default a host gets by saying
    /// nothing. Opting *out* rather than in: an app that adds a capability to a
    /// later release should not have to remember to enable it here.
    public static let all: Self = [
        .scratch, .web, .userInteraction, .planning, .tasks, .skills, .mcp,
    ]
}

/// Which built-in groups a run gets, and what they are given to work with.
///
/// A group with a missing dependency contributes nothing rather than trapping or
/// registering a tool that would fail on its first call: whether an app has a
/// web client this run is an ordinary runtime fact, and the honest response to
/// "no fetcher" is a model that was never told `fetch` existed.
public nonisolated struct AgentBuiltInToolConfiguration: Sendable {
    public var groups: Set<AgentToolGroup>
    /// Per conversation rather than per run, so a file staged before the user
    /// interrupted is still there for the run that answers them.
    public var workspace: AgentScratchWorkspace?
    public var web: (any AgentWebFetching)?
    /// Separate from `web` because most providers now search on their own
    /// servers; a run using native search supplies a fetcher and no searcher,
    /// and `web_search` is then simply absent rather than present and redundant.
    public var search: (any AgentWebSearching)?
    /// The tools allowed to spend a secret handle — see
    /// `RequestUserSecretTool.consumerTools`. Empty accepts any name.
    public var secretConsumerTools: [String] = []
    public var tasks: AgentTaskList?
    public var plans: AgentPlanRecorder?
    /// Snapshotted for the run by the caller — see `AgentSkillCatalog`.
    public var skills = AgentSkillCatalog()
    public var mcpServers: [(server: MCPServer, bearerToken: String?)] = []
    public var mcpClient = MCPClient()

    public init(
        groups: Set<AgentToolGroup> = .all,
        workspace: AgentScratchWorkspace? = nil,
        web: (any AgentWebFetching)? = nil,
        search: (any AgentWebSearching)? = nil,
        secretConsumerTools: [String] = [],
        tasks: AgentTaskList? = nil,
        plans: AgentPlanRecorder? = nil,
        skills: AgentSkillCatalog = AgentSkillCatalog(),
        mcpServers: [(server: MCPServer, bearerToken: String?)] = [],
        mcpClient: MCPClient = MCPClient()
    ) {
        self.groups = groups
        self.workspace = workspace
        self.web = web
        self.search = search
        self.secretConsumerTools = secretConsumerTools
        self.tasks = tasks
        self.plans = plans
        self.skills = skills
        self.mcpServers = mcpServers
        self.mcpClient = mcpClient
    }

    public func includes(_ group: AgentToolGroup) -> Bool { groups.contains(group) }
}

/// One type's only registration point. It supplies both executable construction
/// and the trusted presenter retained for historical transcript rendering.
///
/// Generic over the environment a host builds its own tools from, so an app can
/// register a tool of its own with its own dependencies without the runtime
/// ever naming them.
public nonisolated struct AgentToolTypeRegistration<Environment>: Sendable {
    public let presenter: AgentToolDetailPresenter
    private let materialize: @Sendable (Environment) -> AnyAgentTool?

    public init<T: AgentToolDefinition>(
        _ type: T.Type,
        make: @escaping @Sendable (Environment) -> T?
    ) {
        presenter = type.presenter
        materialize = { environment in
            guard let tool = make(environment) else { return nil }
            return AnyAgentTool(
                descriptor: tool.registeredDescriptor,
                preflight: tool.preflight,
                execute: tool.execute
            )
        }
    }

    public func tool(in environment: Environment) -> AnyAgentTool? {
        materialize(environment)
    }
}

/// The runtime's own tool catalog.
///
/// Local definitions appear exactly once below, grouped by `AgentToolGroup`.
/// A host's own registrations join the same resolved registry after them, and
/// runtime MCP discovery after that — so neither a host name nor a remote name
/// can ever shadow a built-in.
public nonisolated enum AgentToolCatalog {
    public typealias Registration = AgentToolTypeRegistration<AgentBuiltInToolConfiguration>

    public static func registry(
        builtIn: AgentBuiltInToolConfiguration,
        additional: [AnyAgentTool] = []
    ) -> AgentToolRegistry {
        let local = definitions.compactMap { $0.tool(in: builtIn) }
        let remote =
            builtIn.includes(.mcp)
            ? AgentMCPTools.make(servers: builtIn.mcpServers, client: builtIn.mcpClient)
            : []
        return AgentToolRegistry(local + additional + remote)
    }

    /// Every presenter the built-in catalog owns, for a host composing the
    /// registry that renders historical cards — see `AgentToolPresenterRegistry`.
    public static var builtInPresenters: [AgentToolDetailPresenter] { definitions.map(\.presenter) }

    private static let definitions: [Registration] =
        webTools + userTools + scratchTools + planningTools + taskTools + skillTools

    private static let webTools: [Registration] = [
        .init(FetchTool.self) { configuration in
            guard configuration.includes(.web), let web = configuration.web else { return nil }
            return FetchTool(web: web)
        },
        .init(WebSearchTool.self) { configuration in
            guard configuration.includes(.web), let search = configuration.search else {
                return nil
            }
            return WebSearchTool(web: search)
        },
        .init(ScratchFetchTool.self) { configuration in
            // Both groups, not just a workspace that happens to exist. This tool
            // is a fetch whose result lands in the staging area, so an app that
            // took `.web` without `.scratch` asked for pages in the transcript
            // and would get files it has no other tool to read.
            guard configuration.includes(.web), let web = configuration.web,
                let workspace = configuration.scratch
            else { return nil }
            return ScratchFetchTool(workspace: workspace, web: web)
        },
    ]

    private static let userTools: [Registration] = [
        .init(RequestUserInputTool.self) {
            $0.includes(.userInteraction) ? RequestUserInputTool() : nil
        },
        .init(RequestUserSecretTool.self) { configuration in
            guard configuration.includes(.userInteraction) else { return nil }
            return RequestUserSecretTool(consumerTools: configuration.secretConsumerTools)
        },
    ]

    private static let scratchTools: [Registration] = [
        .init(ScratchListTool.self) { $0.scratch.map(ScratchListTool.init(workspace:)) },
        .init(ScratchReadTool.self) { $0.scratch.map(ScratchReadTool.init(workspace:)) },
        .init(ScratchSearchTool.self) { $0.scratch.map(ScratchSearchTool.init(workspace:)) },
        .init(ScratchWriteTool.self) { $0.scratch.map(ScratchWriteTool.init(workspace:)) },
        .init(ScratchEditTool.self) { $0.scratch.map(ScratchEditTool.init(workspace:)) },
        .init(ScratchDiffTool.self) { $0.scratch.map(ScratchDiffTool.init(workspace:)) },
        .init(ScratchDeleteTool.self) { $0.scratch.map(ScratchDeleteTool.init(workspace:)) },
    ]

    private static let planningTools: [Registration] = [
        .init(PresentPlanTool.self) { configuration in
            guard configuration.includes(.planning), let workspace = configuration.workspace,
                let plans = configuration.plans
            else { return nil }
            return PresentPlanTool(workspace: workspace, plans: plans)
        }
    ]

    private static let taskTools: [Registration] = [
        .init(ManageTasksTool.self) { configuration in
            guard configuration.includes(.tasks) else { return nil }
            return configuration.tasks.map(ManageTasksTool.init(tasks:))
        }
    ]

    private static let skillTools: [Registration] = [
        .init(LoadSkillTool.self) { configuration in
            guard configuration.includes(.skills), !configuration.skills.isEmpty else {
                return nil
            }
            return LoadSkillTool(skills: configuration.skills)
        }
    ]
}
nonisolated

    extension AgentBuiltInToolConfiguration
{
    /// The workspace, but only when the scratch group asked for it.
    fileprivate var scratch: AgentScratchWorkspace? {
        includes(.scratch) ? workspace : nil
    }
}

/// Resolves a persisted card's `presenterID` back to the code that draws it.
///
/// Composed by the host from the runtime's presenters and its own, because a
/// transcript outlives the run that wrote it: a card recorded by a tool the app
/// added must still open years later, and the only thing the record carries is
/// the ID. Executable projection code is never accepted from an MCP server, so
/// nothing here can come from a remote.
public nonisolated struct AgentToolPresenterRegistry: Sendable {
    private let byID: [String: AgentToolDetailPresenter]

    public init(_ presenters: [AgentToolDetailPresenter]) {
        byID = Dictionary(
            presenters.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
    }

    public var ids: [String] { byID.keys.sorted() }

    public func presenter(id: String) -> AgentToolDetailPresenter? { byID[id] }
}
