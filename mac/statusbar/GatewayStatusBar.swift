import Cocoa
import Darwin

struct GatewayConfiguration: Decodable {
    let projectDirectory: String
    let pythonExecutable: String
    let logDirectory: String
    let launchAgent: String
}

final class GatewayDelegate: NSObject, NSApplicationDelegate {
    private var configuration: GatewayConfiguration!
    private var statusItem: NSStatusItem!
    private let stateItem = NSMenuItem(title: "网关启动中…", action: nil, keyEquivalent: "")
    private let startupItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private var child: Process?
    private var timer: Timer?
    private var logHandle: FileHandle?
    private var instanceLock: Int32 = -1
    private var nextAttempt = Date.distantPast
    private var quitting = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            let resource = Bundle.main.url(forResource: "gateway", withExtension: "json")!
            configuration = try JSONDecoder().decode(GatewayConfiguration.self, from: Data(contentsOf: resource))
            try FileManager.default.createDirectory(atPath: configuration.logDirectory,
                                                    withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            let lockPath = configuration.logDirectory + "/statusbar.lock"
            instanceLock = Darwin.open(lockPath, O_CREAT | O_RDWR | O_CLOEXEC, mode_t(0o600))
            guard instanceLock >= 0, flock(instanceLock, LOCK_EX | LOCK_NB) == 0 else {
                NSApp.terminate(nil)
                return
            }
            let logPath = configuration.logDirectory + "/gateway.log"
            if !FileManager.default.fileExists(atPath: logPath) {
                FileManager.default.createFile(atPath: logPath, contents: nil,
                                               attributes: [.posixPermissions: 0o600])
            }
            logHandle = try FileHandle(forWritingTo: URL(fileURLWithPath: logPath))
            try logHandle?.seekToEnd()
        } catch {
            let alert = NSAlert()
            alert.messageText = "无法启动 Mac 网关"
            alert.informativeText = error.localizedDescription
            alert.runModal()
            NSApp.terminate(nil)
            return
        }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let menu = NSMenu()
        stateItem.isEnabled = false
        startupItem.isEnabled = false
        menu.addItem(stateItem)
        menu.addItem(NSMenuItem(title: "HTTPS 端口：18443", action: nil, keyEquivalent: ""))
        menu.addItem(startupItem)
        menu.addItem(.separator())
        let logs = NSMenuItem(title: "查看日志…", action: #selector(showLogs), keyEquivalent: "")
        logs.target = self
        menu.addItem(logs)
        let quit = NSMenuItem(title: "退出网关…", action: #selector(quitGateway), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        statusItem.menu = menu
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    private func gatewayLockHeld() -> Bool {
        let path = configuration.projectDirectory + "/.local/run.lock"
        let descriptor = Darwin.open(path, O_RDONLY)
        guard descriptor >= 0 else { return false }
        defer { Darwin.close(descriptor) }
        if flock(descriptor, LOCK_EX | LOCK_NB) == 0 {
            flock(descriptor, LOCK_UN)
            return false
        }
        return errno == EWOULDBLOCK || errno == EAGAIN
    }

    private func listenerAvailable() -> Bool {
        let descriptor = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return false }
        defer { Darwin.close(descriptor) }
        guard fcntl(descriptor, F_SETFL, O_NONBLOCK) != -1 else { return false }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = UInt16(18443).bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if result == 0 { return true }
        guard errno == EINPROGRESS else { return false }
        var readiness = pollfd(fd: descriptor, events: Int16(POLLOUT), revents: 0)
        guard Darwin.poll(&readiness, 1, 50) > 0 else { return false }
        var socketError: Int32 = 0
        var size = socklen_t(MemoryLayout<Int32>.size)
        return getsockopt(descriptor, SOL_SOCKET, SO_ERROR, &socketError, &size) == 0 && socketError == 0
    }

    private func refresh() {
        guard !quitting else { return }
        let locked = gatewayLockHeld()
        let listening = locked && listenerAvailable()
        if listening {
            stateItem.title = child == nil ? "网关运行中 · 现有进程" : "网关运行中"
        } else if locked || child?.isRunning == true {
            stateItem.title = "网关启动中…"
        } else if Date() >= nextAttempt {
            launchGateway()
            stateItem.title = "网关启动中…"
        } else {
            stateItem.title = "网关启动失败 · 稍后重试"
        }
        startupItem.title = FileManager.default.fileExists(atPath: configuration.launchAgent)
            ? "登录自启：已开启" : "登录自启：未开启"
        let image = NSImage(systemSymbolName: listening ? "network" : "exclamationmark.circle",
                            accessibilityDescription: stateItem.title)
        image?.isTemplate = true
        statusItem.button?.image = image
        statusItem.button?.toolTip = "Mac 网关 · " + stateItem.title
    }

    private func launchGateway() {
        nextAttempt = Date().addingTimeInterval(10)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: configuration.pythonExecutable)
        process.arguments = ["-u", configuration.projectDirectory + "/run-mac.py"]
        process.currentDirectoryURL = URL(fileURLWithPath: configuration.projectDirectory)
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = "/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        environment["PYTHONUNBUFFERED"] = "1"
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = logHandle
        process.standardError = logHandle
        process.terminationHandler = { [weak self] finished in
            DispatchQueue.main.async {
                guard let self = self, self.child === finished else { return }
                self.record("网关退出，状态码 \(finished.terminationStatus)，将自动重试。")
                self.child = nil
                self.nextAttempt = Date().addingTimeInterval(5)
            }
        }
        do {
            try process.run()
            child = process
            record("后台网关已启动，PID \(process.processIdentifier)。")
        } catch {
            record("启动失败：\(error.localizedDescription)")
        }
    }

    private func record(_ message: String) {
        guard let bytes = "[\(ISO8601DateFormatter().string(from: Date()))] \(message)\n".data(using: .utf8) else { return }
        do { try logHandle?.write(contentsOf: bytes) } catch {
            NSLog("写入网关日志失败：%@", error.localizedDescription)
        }
    }

    @objc private func showLogs() {
        NSWorkspace.shared.open(URL(fileURLWithPath: configuration.logDirectory + "/gateway.log"))
    }

    @objc private func quitGateway() {
        let alert = NSAlert()
        alert.messageText = "退出 Mac 网关？"
        alert.informativeText = "手机助手会断开连接，下次登录 Mac 时会自动启动。"
        alert.addButton(withTitle: "退出网关")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        quitting = true
        timer?.invalidate()
        if let child = child, child.isRunning {
            child.terminationHandler = { _ in DispatchQueue.main.async { NSApp.terminate(nil) } }
            child.terminate()
            DispatchQueue.main.asyncAfter(deadline: .now() + 8) {
                if child.isRunning { Darwin.kill(child.processIdentifier, SIGKILL) }
                NSApp.terminate(nil)
            }
        } else {
            NSApp.terminate(nil)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let child = child, child.isRunning { child.terminate() }
        if instanceLock >= 0 { Darwin.close(instanceLock) }
    }
}

let application = NSApplication.shared
application.setActivationPolicy(.accessory)
let delegate = GatewayDelegate()
application.delegate = delegate
application.run()
