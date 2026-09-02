import Foundation
import Testing

@testable import AgentKit

/// Covers what `scratch_replace`, `scratch_copy` and `scratch_move` add on top of the
/// containment, quota and matching rules the workspace already had.
@Suite
struct AgentScratchWorkspaceTests {

    // MARK: - Replacing: how many

    /// The careful default. An entry that says nothing about how many regions it
    /// means still has to name exactly one, so widening the tool did not quietly
    /// widen every call that predates the widening.
    @Test
    func anEntryWithoutACountStillHasToNameExactlyOneRegion() async throws {
        let workspace = Fixture.workspace()
        _ = try await workspace.write("n.conf", data: Data("listen 80;\nx\nlisten 80;\n".utf8))
        let before = try await workspace.data(at: "n.conf").sha256

        await #expect(throws: (any Error).self) {
            try await workspace.replace(
                [ScratchReplacement(oldText: "listen 80;", newText: "listen 8080;")], in: "n.conf"
            )
        }
        #expect(try await workspace.data(at: "n.conf").sha256 == before)
    }

    @Test
    func countZeroReplacesEveryOccurrence() async throws {
        let workspace = Fixture.workspace()
        _ = try await workspace.write(
            "n.conf", data: Data("listen 80;\nkeep\nlisten 80;\nlisten 80;\n".utf8)
        )

        let outcome = try await workspace.replace(
            [ScratchReplacement(oldText: "listen 80;", newText: "listen 8080;", count: 0)],
            in: "n.conf"
        )
        #expect(outcome.entriesApplied == 1)
        #expect(outcome.replacementsApplied == 3)
        #expect(
            try await workspace.read("n.conf").content
                == "listen 8080;\nkeep\nlisten 8080;\nlisten 8080;"
        )
    }

    @Test
    func aCountTakesThatManyInDocumentOrderAndRefusesToTakeFewer() async throws {
        let workspace = Fixture.workspace()
        let body = (1...4).map { "port \($0): open" }.joined(separator: "\n") + "\n"
        _ = try await workspace.write("p.txt", data: Data(body.utf8))

        let outcome = try await workspace.replace(
            [ScratchReplacement(oldText: "open", newText: "closed", count: 2)], in: "p.txt"
        )
        #expect(outcome.replacementsApplied == 2)
        #expect(
            try await workspace.read("p.txt").content
                == "port 1: closed\nport 2: closed\nport 3: open\nport 4: open"
        )

        // Asking for more than exist fails whole rather than doing what it can.
        let before = try await workspace.data(at: "p.txt").sha256
        await #expect(throws: (any Error).self) {
            try await workspace.replace(
                [ScratchReplacement(oldText: "open", newText: "closed", count: 5)], in: "p.txt"
            )
        }
        #expect(try await workspace.data(at: "p.txt").sha256 == before)
    }

    @Test
    func aCountOutsideItsBoundsIsRefused() async throws {
        let workspace = Fixture.workspace()
        _ = try await workspace.write("a.txt", data: Data("a\n".utf8))
        for count in [-1, AgentScratchWorkspace.Limits.matchesPerReplacement + 1] {
            await #expect(throws: (any Error).self) {
                try await workspace.replace(
                    [ScratchReplacement(oldText: "a", newText: "b", count: count)], in: "a.txt"
                )
            }
        }
    }

    // MARK: - Replacing: patterns

    @Test
    func aPatternSubstitutesItsCaptureGroupsPerMatch() async throws {
        let workspace = Fixture.workspace()
        _ = try await workspace.write(
            "hosts.txt", data: Data("alpha=1\nbeta=2\ngamma=3\n".utf8)
        )

        let outcome = try await workspace.replace(
            [
                ScratchReplacement(
                    oldText: #"^(\w+)=(\d+)$"#, newText: "$1 -> $2",
                    isRegularExpression: true, count: 0
                )
            ], in: "hosts.txt"
        )
        #expect(outcome.replacementsApplied == 3)
        #expect(
            try await workspace.read("hosts.txt").content
                == "alpha -> 1\nbeta -> 2\ngamma -> 3"
        )
    }

    /// `^` and `$` bind to lines, which is how a change to a config is described.
    /// Anchored to the whole file they would match once and the test above would
    /// report one replacement rather than three — so this pins the option rather
    /// than trusting the default.
    @Test
    func anchorsBindToLinesAndAPatternMaySpanThem() async throws {
        let workspace = Fixture.workspace()
        _ = try await workspace.write("s.conf", data: Data("[a]\nkey = 1\n[b]\n".utf8))

        let outcome = try await workspace.replace(
            [
                ScratchReplacement(
                    oldText: #"\[a\]\nkey = 1"#, newText: "[a]\nkey = 2",
                    isRegularExpression: true
                )
            ], in: "s.conf"
        )
        #expect(outcome.replacementsApplied == 1)
        #expect(try await workspace.read("s.conf").content == "[a]\nkey = 2\n[b]")
    }

    @Test
    func anInvalidOrEmptyMatchingPatternIsRefusedBeforeAnythingIsWritten() async throws {
        let workspace = Fixture.workspace()
        _ = try await workspace.write("t.txt", data: Data("text\n".utf8))
        let before = try await workspace.data(at: "t.txt").sha256

        for pattern in ["[", "x*", #"(?:)"#] {
            await #expect(throws: (any Error).self, "\(pattern) was allowed") {
                try await workspace.replace(
                    [
                        ScratchReplacement(
                            oldText: pattern, newText: "y", isRegularExpression: true, count: 0
                        )
                    ], in: "t.txt"
                )
            }
        }
        #expect(try await workspace.data(at: "t.txt").sha256 == before)
    }

    /// A pattern is exact by construction, so the punctuation-forgiving fallback
    /// that literal matching uses would mean matching something other than what the
    /// pattern says.
    @Test
    func theNormalizedFallbackDoesNotApplyToPatterns() async throws {
        let workspace = Fixture.workspace()
        _ = try await workspace.write("q.txt", data: Data("say \u{201C}hello\u{201D}\n".utf8))

        // Literally, with straight quotes: forgiven.
        _ = try await workspace.replace(
            [ScratchReplacement(oldText: "say \"hello\"", newText: "say goodbye")], in: "q.txt"
        )
        #expect(try await workspace.read("q.txt").content == "say goodbye")

        _ = try await workspace.write("r.txt", data: Data("say \u{201C}hello\u{201D}\n".utf8))
        await #expect(throws: (any Error).self) {
            try await workspace.replace(
                [
                    ScratchReplacement(
                        oldText: #"say "hello""#, newText: "say goodbye", isRegularExpression: true
                    )
                ], in: "r.txt"
            )
        }
    }

    @Test
    func literalAndPatternEntriesMixButStillMayNotOverlap() async throws {
        let workspace = Fixture.workspace()
        _ = try await workspace.write(
            "m.conf", data: Data("name = old\nport = 80\n".utf8)
        )

        let outcome = try await workspace.replace(
            [
                ScratchReplacement(oldText: "name = old", newText: "name = new"),
                ScratchReplacement(
                    oldText: #"port = \d+"#, newText: "port = 8080", isRegularExpression: true
                ),
            ], in: "m.conf"
        )
        #expect(outcome.entriesApplied == 2)
        #expect(outcome.replacementsApplied == 2)
        #expect(try await workspace.read("m.conf").content == "name = new\nport = 8080")

        _ = try await workspace.write("o.conf", data: Data("alpha beta gamma\n".utf8))
        let before = try await workspace.data(at: "o.conf").sha256
        await #expect(throws: (any Error).self) {
            try await workspace.replace(
                [
                    ScratchReplacement(oldText: "alpha beta", newText: "x"),
                    ScratchReplacement(
                        oldText: #"beta \w+"#, newText: "y", isRegularExpression: true
                    ),
                ], in: "o.conf"
            )
        }
        #expect(try await workspace.data(at: "o.conf").sha256 == before)
    }

    // MARK: - Copying and moving

    @Test
    func copyDuplicatesAFileAndAWholeSubtree() async throws {
        let workspace = Fixture.workspace()
        _ = try await workspace.write("app.conf", data: Data("body".utf8))
        _ = try await workspace.write("tree/a.txt", data: Data("a".utf8))
        _ = try await workspace.write("tree/deep/b.txt", data: Data("bb".utf8))

        let file = try await workspace.copy("app.conf", to: "backup/app.conf")
        #expect(file.kind == .file)
        #expect(file.files == 1)
        #expect(file.bytes == 4)
        #expect(!file.didOverwrite)
        #expect(try await workspace.read("backup/app.conf").content == "body")
        // The original is untouched.
        #expect(try await workspace.read("app.conf").content == "body")

        let directory = try await workspace.copy("tree", to: "tree-backup")
        #expect(directory.kind == .directory)
        #expect(directory.files == 2)
        #expect(directory.bytes == 3)
        #expect(try await workspace.read("tree-backup/deep/b.txt").content == "bb")
        // Three originals plus three copies, and the copies count against the quota
        // like anything else the workspace holds.
        #expect(directory.usage.entries == 6)
        #expect(directory.usage.bytes == 14)
    }

    @Test
    func moveRenamesWithoutChangingWhatTheWorkspaceHolds() async throws {
        let workspace = Fixture.workspace()
        _ = try await workspace.write("draft.md", data: Data("plan".utf8))
        _ = try await workspace.write("tree/a.txt", data: Data("a".utf8))
        let before = try await workspace.usage()

        let file = try await workspace.move("draft.md", to: "plans/final.md")
        #expect(file.kind == .file)
        #expect(try await workspace.read("plans/final.md").content == "plan")
        await #expect(throws: (any Error).self) { try await workspace.read("draft.md") }

        _ = try await workspace.move("tree", to: "moved")
        #expect(try await workspace.read("moved/a.txt").content == "a")
        let after = try await workspace.usage()
        #expect(after.bytes == before.bytes)
        #expect(after.entries == before.entries)
        #expect(
            try await workspace.list(nil, recursive: true).map(\.path).sorted() == [
                "moved", "moved/a.txt", "plans", "plans/final.md",
            ])
    }

    @Test
    func anOccupiedDestinationNeedsOverwriteAndADirectoryIsNeverReplaced() async throws {
        let workspace = Fixture.workspace()
        _ = try await workspace.write("a.txt", data: Data("a".utf8))
        _ = try await workspace.write("b.txt", data: Data("b".utf8))
        _ = try await workspace.write("dir/keep.txt", data: Data("keep".utf8))

        await #expect(throws: (any Error).self) { try await workspace.copy("a.txt", to: "b.txt") }
        #expect(try await workspace.read("b.txt").content == "b")

        let replaced = try await workspace.copy("a.txt", to: "b.txt", overwrite: true)
        #expect(replaced.didOverwrite)
        #expect(try await workspace.read("b.txt").content == "a")

        // A directory destination is refused whatever overwrite says: replacing one
        // is a recursive delete, and no scratch tool does that.
        for overwrite in [false, true] {
            await #expect(throws: (any Error).self) {
                try await workspace.copy("a.txt", to: "dir", overwrite: overwrite)
            }
            await #expect(throws: (any Error).self) {
                try await workspace.move("a.txt", to: "dir", overwrite: overwrite)
            }
        }
        #expect(try await workspace.read("dir/keep.txt").content == "keep")
    }

    @Test
    func aTransferIntoItsOwnSourceOrOntoItselfIsRefused() async throws {
        let workspace = Fixture.workspace()
        _ = try await workspace.write("tree/a.txt", data: Data("a".utf8))

        for (from, to) in [("tree", "tree/inner"), ("tree", "tree"), ("tree/a.txt", "tree/a.txt")] {
            await #expect(throws: (any Error).self, "\(from) → \(to) was allowed") {
                try await workspace.copy(from, to: to)
            }
            await #expect(throws: (any Error).self, "\(from) → \(to) was allowed") {
                try await workspace.move(from, to: to)
            }
        }
        #expect(try await workspace.list(nil, recursive: true).map(\.path) == ["tree", "tree/a.txt"])
    }

    /// Both arguments can be inside the limits while the result is not: re-rooting a
    /// shallow subtree under a deep destination is what pushes it over.
    @Test
    func aSubtreeThatWouldLandPastTheDepthLimitIsRefused() async throws {
        let workspace = Fixture.workspace()
        _ = try await workspace.write("src/one/two.txt", data: Data("x".utf8))
        let deep = (1...7).map { "d\($0)" }.joined(separator: "/")
        _ = try await workspace.write("\(deep)/anchor.txt", data: Data("x".utf8))

        // `deep/src` is depth 8, and `deep/src/one/two.txt` would be depth 10.
        await #expect(throws: (any Error).self) {
            try await workspace.copy("src", to: "\(deep)/src")
        }
        #expect(try await workspace.usage().entries == 2)
    }

    @Test
    func aCopyPastTheQuotaIsRefusedAndWritesNothing() async throws {
        let workspace = Fixture.workspace()
        for index in 0..<(AgentScratchWorkspace.Limits.entries - 2) {
            _ = try await workspace.write("filler/f\(index).txt", data: Data("x".utf8))
        }
        _ = try await workspace.write("tree/a.txt", data: Data("a".utf8))
        _ = try await workspace.write("tree/b.txt", data: Data("b".utf8))
        let before = try await workspace.usage()
        #expect(before.entries == AgentScratchWorkspace.Limits.entries)

        await #expect(throws: (any Error).self) {
            try await workspace.copy("tree", to: "tree-copy")
        }
        #expect(try await workspace.usage() == before)
        await #expect(throws: (any Error).self) {
            try await workspace.list("tree-copy", recursive: true)
        }

        // A move adds no entries, so it is still allowed at the ceiling — otherwise
        // a full workspace could not even be reorganized.
        _ = try await workspace.move("tree", to: "tree-moved")
        #expect(try await workspace.read("tree-moved/a.txt").content == "a")
    }

    /// The same rule `resolve(_:in:)` enforces on a path, enforced on a subtree:
    /// `copyItem` would otherwise recreate the link, and an alias inside the
    /// workspace makes two paths the same file.
    @Test
    func aSymlinkInsideTheSourceMakesBothTransfersRefuse() async throws {
        let base = Fixture.base()
        let id = UUID()
        let workspace = AgentScratchWorkspace(conversationID: id, base: base)
        _ = try await workspace.write("tree/a.txt", data: Data("a".utf8))
        _ = try await workspace.write("anchor.txt", data: Data("anchor".utf8))

        let scope = base.appending(path: id.uuidString)
        try FileManager.default.createSymbolicLink(
            at: scope.appending(path: "tree/link.txt"),
            withDestinationURL: scope.appending(path: "anchor.txt")
        )

        await #expect(throws: (any Error).self) { try await workspace.copy("tree", to: "copy") }
        await #expect(throws: (any Error).self) { try await workspace.move("tree", to: "moved") }
        #expect(try await workspace.list("tree", recursive: true).map(\.path) == ["tree/a.txt"])
    }

    // MARK: - Registry

    @Test
    func theScratchGroupOffersTheThreeToolsUnderTheirCurrentNames() {
        let workspace = AgentScratchWorkspace(
            conversationID: UUID(), base: FileManager.default.temporaryDirectory
        )
        let descriptors = AgentToolCatalog.registry(
            builtIn: .init(groups: [.scratch], workspace: workspace)
        ).descriptors

        #expect(
            descriptors.map(\.name).sorted() == [
                "scratch_copy", "scratch_delete", "scratch_diff", "scratch_list", "scratch_move",
                "scratch_read", "scratch_replace", "scratch_search", "scratch_write",
            ])
        // Copying and moving change something, and both stay contained — so both are
        // available while planning, on the same terms as scratch_write.
        for name in ["scratch_copy", "scratch_move", "scratch_replace"] {
            let descriptor = descriptors.first { $0.name == name }
            #expect(descriptor?.safety == .locallyContained, "\(name)")
            #expect(descriptor?.safety.isAllowedWhilePlanning == true, "\(name)")
            #expect(descriptor?.concurrency == .parallel, "\(name)")
        }
    }

    /// A card records the presenter ID it was written with, so renaming the tool
    /// must not orphan a transcript written before the rename.
    @Test
    func theRenamedToolKeepsItsOldPresenterIDResolvable() {
        let ids = AgentToolCatalog.builtInPresenters.map(\.id)
        #expect(ids.contains("builtin.scratch_replace"))
        #expect(ids.contains("builtin.scratch_edit"))
        #expect(Set(ids).count == ids.count)
    }
}

// MARK: - Fixtures

private enum Fixture {
    static func base() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "agentkit-scratch-tests/\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func workspace() -> AgentScratchWorkspace {
        AgentScratchWorkspace(conversationID: UUID(), base: base())
    }
}
