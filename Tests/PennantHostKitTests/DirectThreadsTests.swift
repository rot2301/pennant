import PennantCore
@testable import PennantHostKit
import Foundation
import XCTest

/// This fork's default: no Pennant chat. You start threads and write in them yourself, as before 0.2.0, and a chat
/// left from 0.2.0 becomes an ordinary thread.
final class DirectThreadsTests: XCTestCase {
    var paths: HostPaths!

    override func setUp() async throws {
        paths = HostPaths.temporary()
        try paths.ensureDirectories()
    }

    override func tearDown() async throws { try? FileManager.default.removeItem(at: paths.root) }

    private func service(_ provider: ScriptedProvider) async throws -> HostService {
        var config = HostConfig()
        config.workingDirectory = paths.root.path
        config.desktop.pauseOnHumanInput = false
        let s = try HostService(paths: paths, config: config, desktop: FakeDesktop(), humanInput: NullHumanInput(), provider: provider)
        try await s.start(startAPI: false)
        return s
    }

    private func pennant(_ s: HostService) async throws -> AgentProfile {
        let agents = try await s.store.listAgents(includeRetired: false)
        return try XCTUnwrap(agents.first { $0.kind == .persistent })
    }

    private func wait(_ s: HostService, _ id: TaskID, _ state: TaskState, file: StaticString = #filePath, line: UInt = #line) async throws {
        let deadline = Date().addingTimeInterval(8)
        while Date() < deadline {
            if try await s.store.task(id)?.state == state { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        let now = try await s.store.task(id)?.state
        XCTFail("task never reached \(state) (it's \(String(describing: now)))", file: file, line: line)
    }

    func testThereIsNoPennantChatByDefault() async throws {
        let s = try await service(ScriptedProvider([]))
        XCTAssertFalse(HostConfig().pennantChat)
        let agent = try await pennant(s)
        let conversations = try await s.store.listConversations(agentID: agent.id)
        XCTAssertFalse(conversations.contains(where: \.isMain), "the host made a Pennant chat")
        do {
            _ = try await s.runtime.ensureMainChat()
            XCTFail("ensureMainChat made a chat with the chat off")
        } catch {}
        await s.stop()
    }

    /// A thread is written in directly: a follow-up goes into the same thread, the thread keeps its own tools
    /// (helpers, the screen) rather than the chat's, and nothing reports to a chat.
    func testAThreadIsWrittenInDirectlyAndKeepsItsOwnTools() async throws {
        let provider = ScriptedProvider([.init(text: "Here's a plan for Lisbon."), .init(text: "Added a day in Porto.")])
        let s = try await service(provider)
        let agent = try await pennant(s)

        let (_, thread, first) = try await s.runtime.submitUserMessage(agentID: agent.id, conversationID: nil, text: "Plan a long weekend in Lisbon", attachments: [])
        try await wait(s, first, .completed)
        let (_, same, second) = try await s.runtime.submitUserMessage(agentID: agent.id, conversationID: thread, text: "Add a day in Porto", attachments: [])
        XCTAssertEqual(same, thread, "the follow-up started somewhere else")
        try await wait(s, second, .completed)

        let messages = try await s.store.messagesAfter(conversationID: thread, after: nil, limit: 100)
        XCTAssertEqual(messages.filter { $0.role == .user }.map(\.text), ["Plan a long weekend in Lisbon", "Add a day in Porto"])
        XCTAssertTrue(messages.contains { $0.role == .assistant && $0.taskID == second && $0.text.trimmingCharacters(in: .whitespacesAndNewlines) == "Added a day in Porto." })

        let stored = try await s.store.task(second)
        let task = try XCTUnwrap(stored)
        let tools = Set(try await s.runtime.turnSpecs(task: task, agent: agent).map(\.name))
        XCTAssertTrue(tools.contains("delegate_task"))
        XCTAssertTrue(tools.isDisjoint(with: ThreadTools.names), "a thread got the chat's thread tools")

        let conversations = try await s.store.listConversations(agentID: agent.id)
        XCTAssertFalse(conversations.contains(where: \.isMain))
        let updates = try await s.store.messagesAfter(conversationID: thread, after: nil, limit: 100).flatMap(\.parts).filter { if case .update = $0 { return true }; return false }
        XCTAssertTrue(updates.isEmpty)
        await s.stop()
    }

    /// A host that ran 0.2.0 has a chat with threads under it. With the chat off, the chat is an ordinary thread again
    /// (its history stays), the threads it started are back in the list to be written in, and its coding runs stay
    /// under it.
    func testAChatLeftFromBeforeBecomesAThreadAndItsThreadsComeBack() async throws {
        let s = try await service(ScriptedProvider([]))
        let agent = try await pennant(s)
        var chat = Conversation(agentID: agent.id, title: agent.name)
        chat.isMain = true
        try await s.store.upsertConversation(chat)
        try await s.store.appendMessage(Message(conversationID: chat.id, agentID: agent.id, role: .user, parts: [.text("Find a place for the offsite")]))
        var started = Conversation(agentID: agent.id, title: "Team offsite in Lisbon")
        started.parentID = chat.id
        try await s.store.upsertConversation(started)
        var coding = Conversation(agentID: agent.id, title: "Fix the pay button")
        coding.parentID = chat.id
        coding.engine = .pennant
        try await s.store.upsertConversation(coding)

        await s.runtime.applyChatSetting()

        let demoted = try await s.store.conversation(chat.id)
        let thread = try XCTUnwrap(demoted)
        XCTAssertFalse(thread.isMain)
        XCTAssertEqual(thread.title, "\(agent.name) chat")
        let history = try await s.store.messagesAfter(conversationID: chat.id, after: nil, limit: 10)
        XCTAssertEqual(history.map(\.text), ["Find a place for the offsite"])
        let startedNow = try await s.store.conversation(started.id)
        let back = try XCTUnwrap(startedNow)
        XCTAssertNil(back.parentID, "a thread the chat started is still hidden under it")
        let codingNow = try await s.store.conversation(coding.id)
        let run = try XCTUnwrap(codingNow)
        XCTAssertEqual(run.parentID, chat.id, "a coding run stays under the thread that asked for it")
        await s.stop()
    }
}
