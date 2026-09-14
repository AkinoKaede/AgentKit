import Foundation
import Testing

@testable import AgentKit

@Suite
struct AgentTextPageTests {
    @Test
    func bytesSplitInsideChineseCharactersAndCRLFDoNotLoseLines() throws {
        let text = "中文一\r\n中文二\r\n中文三\r\n"
        var first = try AgentTextPageReader(limit: 2)
        for byte in text.utf8 { try first.append(Data([byte])) }
        let page = try first.finish()
        #expect(page.content == "中文一\n中文二")
        #expect(page.returnedLines == 2)
        #expect(page.nextOffset == 3)
        var second = try AgentTextPageReader(offset: 3, limit: 2)
        try second.append(Data(text.utf8))
        let end = try second.finish()
        #expect(end.content == "中文三")
        #expect(end.nextOffset == nil)
    }

    @Test
    func byteLimitCountsOnlyActuallyReturnedWholeLines() throws {
        var reader = try AgentTextPageReader(maximumBytes: 8)
        try reader.append(Data("abcd\nefgh\nlast".utf8))
        let page = try reader.finish()
        #expect(page.content == "abcd")
        #expect(page.returnedLines == 1)
        #expect(page.nextOffset == 2)
    }

    @Test
    func emptyEOFInvalidOffsetsLongLinesAndInvalidUTF8AreExplicit() throws {
        var empty = try AgentTextPageReader()
        #expect(try empty.finish().returnedLines == 0)
        #expect(throws: (any Error).self) { _ = try AgentTextPageReader(offset: 0) }
        var beyond = try AgentTextPageReader(offset: 2)
        try beyond.append(Data("one\n".utf8))
        #expect(throws: (any Error).self) { _ = try beyond.finish() }
        var long = try AgentTextPageReader(maximumBytes: 3)
        #expect(throws: (any Error).self) { try long.append(Data("abcdef".utf8)) }
        var invalid = try AgentTextPageReader()
        #expect(throws: (any Error).self) { try invalid.append(Data([0xFF, 10])) }
    }
}
