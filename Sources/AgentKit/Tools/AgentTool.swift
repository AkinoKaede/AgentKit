import Foundation

public nonisolated struct AgentToolExecutionContext: Sendable {
    public init(
        runID: UUID,
        userIntent: String,
        secretBroker: SecretBroker,
        userInteraction: any AgentUserInteractionHandling,
        services: AgentToolServices = AgentToolServices(),
        preflightMetadata: [String: AgentJSONValue],
        authorize: @escaping @Sendable (AgentApprovalRequest) async -> AgentApprovalDecision,
        report: (@Sendable (AgentToolResult) -> Void)? = nil,
        whenUserInterjects: (@Sendable () async -> Void)? = nil
    ) {
        self.runID = runID
        self.userIntent = userIntent
        self.secretBroker = secretBroker
        self.userInteraction = userInteraction
        self.services = services
        self.preflightMetadata = preflightMetadata
        self.authorize = authorize
        self.report = report ?? { _ in }
        self.whenUserInterjects = whenUserInterjects ?? {}
    }

    public var runID: UUID
    public var userIntent: String
    public var secretBroker: SecretBroker
    public var userInteraction: any AgentUserInteractionHandling
    /// What the host lends to the tools it registered — see `AgentToolServices`.
    /// Empty for a run that added none, which is every run made of built-ins.
    public var services = AgentToolServices()
    public var preflightMetadata: [String: AgentJSONValue]
    public var authorize: @Sendable (AgentApprovalRequest) async -> AgentApprovalDecision
    /// What the call has produced so far.
    ///
    /// Pi's `onUpdate`, which it passes as a fourth argument to `execute`
    /// because it has no per-call context object to put it in. This is
    /// addressed to the reader and not to the model: the transcript gets the
    /// value the tool finally returns, never a partial one, so a tool may
    /// report as often as it likes without inflating anything the model pays
    /// for. Defaults to discarding, so a caller assembling a context by hand —
    /// a test, a preview — need not care.
    public var report: @Sendable (AgentToolResult) -> Void = { _ in }
    /// Returns once the user has said something that is queued for the next
    /// model boundary — immediately, if something already is.
    ///
    /// For a tool that is deliberately waiting, so a person interjecting does
    /// not have to sit out a fifteen-minute deadline first. A tool opts into
    /// this rather than having it done to it, because whether stopping early is
    /// free depends entirely on what is being stopped: giving up on a tool that
    /// is only watching costs nothing, while giving up on one that dispatched
    /// work elsewhere would strand it.
    public var whenUserInterjects: @Sendable () async -> Void = {}
}

public nonisolated protocol AgentTool: Sendable {
    var descriptor: AgentToolDescriptor { get }
    func preflight(_ invocation: AgentToolInvocation) async throws -> AgentToolPreflight
    func execute(
        _ invocation: AgentToolInvocation,
        context: AgentToolExecutionContext
    ) async throws -> AgentToolResult
}

/// A locally owned tool definition.
///
/// The executable behavior and its trusted transcript projection travel as one
/// value. `AgentToolCatalog` type-erases definitions only after registration,
/// so adding a tool cannot require a second presenter-only registration.
public nonisolated protocol AgentToolDefinition: AgentTool {
    static var presenter: AgentToolDetailPresenter { get }
}
nonisolated

    extension AgentToolDefinition
{
    /// Binds the executable definition to its presenter without asking every
    /// descriptor declaration to repeat a string ID.
    public var registeredDescriptor: AgentToolDescriptor {
        var registered = descriptor
        guard var presentation = registered.presentation else {
            precondition(
                false, "A registered local tool must declare presentation metadata"
            )
            return registered
        }
        presentation.presenterID = Self.presenter.id
        registered.presentation = presentation
        return registered
    }
}
nonisolated

    extension AgentTool
{
    public func preflight(_ invocation: AgentToolInvocation) async throws -> AgentToolPreflight {
        AgentToolPreflight(invocation: invocation, safety: descriptor.safety)
    }
}

public nonisolated struct AnyAgentTool: AgentTool, Sendable {
    public let descriptor: AgentToolDescriptor
    private let executeClosure:
        @Sendable (AgentToolInvocation, AgentToolExecutionContext) async throws -> AgentToolResult
    private let preflightClosure: @Sendable (AgentToolInvocation) async throws -> AgentToolPreflight

    public init<T: AgentToolDefinition>(_ tool: T) {
        descriptor = tool.registeredDescriptor
        preflightClosure = tool.preflight
        executeClosure = tool.execute
    }

    public init<T: AgentTool>(_ tool: T) {
        descriptor = tool.descriptor
        preflightClosure = tool.preflight
        executeClosure = tool.execute
    }

    public init(
        descriptor: AgentToolDescriptor,
        preflight: (@Sendable (AgentToolInvocation) async throws -> AgentToolPreflight)? = nil,
        execute:
            @escaping @Sendable (
                AgentToolInvocation, AgentToolExecutionContext
            ) async throws -> AgentToolResult
    ) {
        self.descriptor = descriptor
        preflightClosure =
            preflight ?? { invocation in
                AgentToolPreflight(invocation: invocation, safety: descriptor.safety)
            }
        executeClosure = execute
    }

    public func preflight(_ invocation: AgentToolInvocation) async throws -> AgentToolPreflight {
        try await preflightClosure(invocation)
    }

    public func execute(
        _ invocation: AgentToolInvocation,
        context: AgentToolExecutionContext
    ) async throws -> AgentToolResult {
        try await executeClosure(invocation, context)
    }
}
