import Foundation
import CryptoKit

struct DraftSendAttempt: Codable {
    let payload: JSONValue
    let id: String
}

/// Local composer state, separate from any server-side message queue.
struct ChatDraft {
    var text = ""
    var attachments: [PendingAttachment] = []
    var workMode = "default"
    var sendMode = UserDefaults.standard.string(forKey: "native.followUpBehavior") ?? "send"
    var skills: [String] = []
    var attempt: DraftSendAttempt?
    var recoveryNotice = ""
}

/// Each pairing and host/thread pair has an independent, atomically written file.
/// Uploaded attachment IDs and automatic-send flags never survive a process restart.
@MainActor
final class DraftStore {
    static let shared = DraftStore(directory: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("ComposerDrafts", isDirectory: true))
    private let directory: URL
    private let files = FileManager.default
    private struct Snapshot: Codable {
        let version: Int
        let text: String
        let workMode: String
        let sendMode: String
        let skills: [String]
        let attempt: DraftSendAttempt?
        let omittedAttachmentNames: [String]
        let uncertainDelivery: Bool
        let previousRecoveryNotice: String?
    }
    init(directory: URL) { self.directory = directory }
    private func digest(_ value: String) -> String { SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined() }
    private func folder(_ scope: String) -> URL { directory.appendingPathComponent(digest(scope), isDirectory: true) }
    private func file(_ scope: String, _ identity: String) -> URL { folder(scope).appendingPathComponent(digest(identity) + ".json") }

    func save(_ draft: ChatDraft, scope: String, identity: String) throws {
        guard !draft.text.isEmpty || !draft.attachments.isEmpty || draft.attempt != nil || !draft.recoveryNotice.isEmpty else {
            let url = file(scope, identity)
            if files.fileExists(atPath: url.path) { try files.removeItem(at: url) }
            return
        }
        let snapshot = Snapshot(version: 1, text: draft.text, workMode: draft.workMode, sendMode: draft.sendMode, skills: draft.skills,
                                attempt: draft.attachments.isEmpty ? draft.attempt : nil,
                                omittedAttachmentNames: draft.attachments.map(\.name), uncertainDelivery: draft.attempt != nil, previousRecoveryNotice: draft.recoveryNotice.isEmpty ? nil : draft.recoveryNotice)
        let data = try JSONEncoder().encode(snapshot)
        guard data.count <= 2 * 1024 * 1024 else { throw LinkError.message("草稿过大，未能保存到此设备") }
        var target = folder(scope)
        try files.createDirectory(at: target, withIntermediateDirectories: true)
        var flags = URLResourceValues(); flags.isExcludedFromBackup = true
        try target.setResourceValues(flags)
        try data.write(to: file(scope, identity), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
    func load(scope: String, identity: String) throws -> ChatDraft? {
        let url = file(scope, identity)
        guard files.fileExists(atPath: url.path) else { return nil }
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= 2 * 1024 * 1024 else { throw LinkError.message("本机草稿文件过大，无法读取") }
        let value = try JSONDecoder().decode(Snapshot.self, from: Data(contentsOf: url))
        guard value.version == 1 else { throw LinkError.message("本机草稿版本暂不支持") }
        var draft = ChatDraft()
        draft.text = value.text; draft.workMode = value.workMode; draft.sendMode = value.sendMode
        draft.skills = value.skills; draft.attempt = value.attempt
        var messages = ["已恢复此设备上的输入草稿。"]
        if !value.omittedAttachmentNames.isEmpty { messages.append("请重新选择附件：" + value.omittedAttachmentNames.joined(separator: "、")) }
        if value.uncertainDelivery { messages.append("上次发送结果未确认，请先核对会话；未自动重发。") }
        draft.recoveryNotice = value.previousRecoveryNotice ?? messages.joined(separator: " ")
        return draft
    }
    func forget(scope: String) throws {
        let target = folder(scope)
        if files.fileExists(atPath: target.path) { try files.removeItem(at: target) }
    }
}
