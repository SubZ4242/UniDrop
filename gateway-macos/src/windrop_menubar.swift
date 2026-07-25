import AppKit
import Foundation

private struct ScriptResult {
    let exitCode: Int32
    let output: String
}

private let safeProcessPath = "/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"

private final class UniDropMenuBarApp: NSObject, NSApplicationDelegate, NSWindowDelegate, NSTextFieldDelegate {
    private let launchdLabel = "com.windrop.gateway.menubar"
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let defaults = UserDefaults.standard
    private let hideMenuBarKey = "hideMenuBarIcon"
    private var window: NSWindow?
    private var statusLabel = NSTextField(labelWithString: "Status: pruefe...")
    private var macIpLabel = NSTextField(labelWithString: "Mac-IP: suche...")
    private var portField = NSTextField(string: "8873")
    private var autostartCheck = NSButton(checkboxWithTitle: "Mit macOS starten", target: nil, action: nil)
    private var hideMenuBarCheck = NSButton(checkboxWithTitle: "Symbol oben ausblenden", target: nil, action: nil)
    private var toggleButton: NSButton?
    private var isDiscoveryRunning = false
    private var discoveryOperationInProgress = false
    private var timer: Timer?
    private var configSaveTimer: Timer?
    private var projectRoot: String = FileManager.default.currentDirectoryPath

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        projectRoot = prepareProjectRoot()
        appLog("applicationDidFinishLaunching projectRoot=\(projectRoot)")
        configureStatusItem()
        buildWindow()
        configureReceiverAndStartOnLaunch()
        timer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            self?.refreshStatus()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        timer?.invalidate()
        configSaveTimer?.invalidate()
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.orderOut(nil)
        return false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showWindow()
        return false
    }

    private func parseProjectRoot() -> String {
        let args = CommandLine.arguments
        if let index = args.firstIndex(of: "--project-root"), index + 1 < args.count {
            return args[index + 1]
        }
        if let bundledRoot = Bundle.main.object(forInfoDictionaryKey: "UniDropProjectRoot") as? String,
           !bundledRoot.isEmpty {
            return NSString(string: bundledRoot).expandingTildeInPath
        }
        return FileManager.default.currentDirectoryPath
    }

    private func prepareProjectRoot() -> String {
        let root = parseProjectRoot()
        installBundledSupportIfNeeded(to: root)
        return root
    }

    private func installBundledSupportIfNeeded(to root: String) {
        guard let supportURL = Bundle.main.resourceURL?.appendingPathComponent("Support"),
              FileManager.default.fileExists(atPath: supportURL.path) else {
            appLog("bundled support not found")
            return
        }
        let targetURL = URL(fileURLWithPath: root)
        do {
            try FileManager.default.createDirectory(at: targetURL, withIntermediateDirectories: true)
            try copySupportItem(
                from: supportURL.appendingPathComponent("scripts"),
                to: targetURL.appendingPathComponent("scripts")
            )
            try copySupportItem(
                from: supportURL.appendingPathComponent("gateway-macos/src"),
                to: targetURL.appendingPathComponent("gateway-macos/src")
            )
            try copyConfigDefaults(
                from: supportURL.appendingPathComponent("gateway-macos/config"),
                to: targetURL.appendingPathComponent("gateway-macos/config")
            )
            appLog("bundled support installed/updated")
        } catch {
            statusLabel.stringValue = "Support-Installation fehlgeschlagen"
            appLog("support install failed: \(error.localizedDescription)")
        }
    }

    private func copySupportItem(from source: URL, to target: URL) throws {
        guard FileManager.default.fileExists(atPath: source.path) else {
            return
        }
        if FileManager.default.fileExists(atPath: target.path) {
            try FileManager.default.removeItem(at: target)
        }
        try FileManager.default.copyItem(at: source, to: target)
    }

    private func copyConfigDefaults(from source: URL, to target: URL) throws {
        guard FileManager.default.fileExists(atPath: source.path) else {
            return
        }
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let files = try FileManager.default.contentsOfDirectory(
            at: source,
            includingPropertiesForKeys: nil
        )
        for file in files {
            let destination = target.appendingPathComponent(file.lastPathComponent)
            if !FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.copyItem(at: file, to: destination)
            }
        }
    }

    private func configureStatusItem() {
        guard let button = statusItem.button else {
            return
        }
        button.image = dropletImage(color: .white)
        button.image?.isTemplate = false
        button.toolTip = "UniDrop"
        button.target = self
        button.action = #selector(toggleWindow)
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        applyMenuBarVisibility()
    }

    private func buildWindow() {
        let panel = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 430, height: 276),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        panel.title = "UniDrop"
        panel.isReleasedWhenClosed = false
        panel.level = .floating
        panel.delegate = self

        let content = NSView()
        content.translatesAutoresizingMaskIntoConstraints = false
        panel.contentView = content

        let icon = NSImageView(image: dropletImage(color: .controlAccentColor, size: 42))
        icon.translatesAutoresizingMaskIntoConstraints = false

        let title = NSTextField(labelWithString: "UniDrop")
        title.font = .boldSystemFont(ofSize: 17)
        title.translatesAutoresizingMaskIntoConstraints = false

        statusLabel.font = .systemFont(ofSize: 13)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        macIpLabel.font = .systemFont(ofSize: 12)
        macIpLabel.textColor = .secondaryLabelColor
        macIpLabel.translatesAutoresizingMaskIntoConstraints = false

        let portRow = labeledField(label: "Port", field: portField)
        let toggle = button("Stoppen", #selector(toggleDiscovery))
        let quitButton = button("Beenden", #selector(quit))
        let buttonRow = row([toggle, quitButton])
        toggleButton = toggle

        autostartCheck.target = self
        autostartCheck.action = #selector(toggleAutostart)
        autostartCheck.translatesAutoresizingMaskIntoConstraints = false

        hideMenuBarCheck.target = self
        hideMenuBarCheck.action = #selector(toggleMenuBarVisibility)
        hideMenuBarCheck.translatesAutoresizingMaskIntoConstraints = false

        portField.placeholderString = "8873"
        portField.delegate = self
        loadForwardingConfig()
        loadAutostartState()
        loadMenuBarVisibilityState()

        [icon, title, statusLabel, macIpLabel, portRow, autostartCheck, hideMenuBarCheck, buttonRow].forEach(content.addSubview)

        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 22),
            icon.topAnchor.constraint(equalTo: content.topAnchor, constant: 28),
            icon.widthAnchor.constraint(equalToConstant: 42),
            icon.heightAnchor.constraint(equalToConstant: 42),

            title.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 12),
            title.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -22),
            title.topAnchor.constraint(equalTo: icon.topAnchor, constant: 2),

            statusLabel.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            statusLabel.trailingAnchor.constraint(equalTo: title.trailingAnchor),
            statusLabel.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 5),

            macIpLabel.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            macIpLabel.trailingAnchor.constraint(equalTo: title.trailingAnchor),
            macIpLabel.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 4),

            portRow.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 22),
            portRow.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -22),
            portRow.topAnchor.constraint(equalTo: icon.bottomAnchor, constant: 38),

            autostartCheck.leadingAnchor.constraint(equalTo: portRow.leadingAnchor, constant: 88),
            autostartCheck.trailingAnchor.constraint(equalTo: portRow.trailingAnchor),
            autostartCheck.topAnchor.constraint(equalTo: portRow.bottomAnchor, constant: 16),

            buttonRow.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 22),
            buttonRow.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -22),
            hideMenuBarCheck.leadingAnchor.constraint(equalTo: autostartCheck.leadingAnchor),
            hideMenuBarCheck.trailingAnchor.constraint(equalTo: autostartCheck.trailingAnchor),
            hideMenuBarCheck.topAnchor.constraint(equalTo: autostartCheck.bottomAnchor, constant: 8),

            buttonRow.topAnchor.constraint(equalTo: hideMenuBarCheck.bottomAnchor, constant: 18),
        ])

        self.window = panel
    }

    private func button(_ title: String, _ action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .rounded
        button.controlSize = .regular
        button.translatesAutoresizingMaskIntoConstraints = false
        button.heightAnchor.constraint(equalToConstant: 30).isActive = true
        return button
    }

    private func row(_ buttons: [NSButton]) -> NSStackView {
        let stack = NSStackView(views: buttons)
        stack.orientation = .horizontal
        stack.spacing = 8
        stack.distribution = .fillEqually
        stack.translatesAutoresizingMaskIntoConstraints = false
        return stack
    }

    private func labeledField(label: String, field: NSTextField) -> NSStackView {
        let labelView = NSTextField(labelWithString: label)
        labelView.alignment = .right
        labelView.widthAnchor.constraint(equalToConstant: 80).isActive = true
        field.translatesAutoresizingMaskIntoConstraints = false
        let stack = NSStackView(views: [labelView, field])
        stack.orientation = .horizontal
        stack.spacing = 8
        stack.distribution = .fill
        stack.translatesAutoresizingMaskIntoConstraints = false
        return stack
    }

    private func dropletImage(color: NSColor, size: CGFloat = 18) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size))
        image.lockFocus()
        color.setFill()
        let path = NSBezierPath()
        path.move(to: NSPoint(x: size * 0.5, y: size * 0.95))
        path.curve(
            to: NSPoint(x: size * 0.18, y: size * 0.35),
            controlPoint1: NSPoint(x: size * 0.42, y: size * 0.78),
            controlPoint2: NSPoint(x: size * 0.18, y: size * 0.55)
        )
        path.curve(
            to: NSPoint(x: size * 0.5, y: size * 0.06),
            controlPoint1: NSPoint(x: size * 0.18, y: size * 0.16),
            controlPoint2: NSPoint(x: size * 0.33, y: size * 0.06)
        )
        path.curve(
            to: NSPoint(x: size * 0.82, y: size * 0.35),
            controlPoint1: NSPoint(x: size * 0.67, y: size * 0.06),
            controlPoint2: NSPoint(x: size * 0.82, y: size * 0.16)
        )
        path.curve(
            to: NSPoint(x: size * 0.5, y: size * 0.95),
            controlPoint1: NSPoint(x: size * 0.82, y: size * 0.55),
            controlPoint2: NSPoint(x: size * 0.58, y: size * 0.78)
        )
        path.close()
        path.fill()
        image.unlockFocus()
        return image
    }

    @objc private func toggleWindow() {
        guard let window else {
            return
        }
        if window.isVisible {
            window.orderOut(nil)
            return
        }
        showWindow()
    }

    private func showWindow() {
        guard let window else {
            return
        }
        if let button = statusItem.button, let screen = button.window?.screen {
            let buttonFrame = button.window?.convertToScreen(button.frame) ?? .zero
            let x = min(max(buttonFrame.midX - window.frame.width / 2, screen.visibleFrame.minX + 8), screen.visibleFrame.maxX - window.frame.width - 8)
            let y = buttonFrame.minY - window.frame.height - 8
            window.setFrameOrigin(NSPoint(x: x, y: max(y, screen.visibleFrame.minY + 8)))
        }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        refreshStatus()
    }

    private func ensureDiscoveryStartsOnLaunch() {
        statusLabel.stringValue = "Status: startet..."
        setControlsEnabled(false)
        startDiscoveryAndPoll()
    }

    private func configureReceiverAndStartOnLaunch() {
        statusLabel.stringValue = "Status: startet..."
        setControlsEnabled(false)
        let port = portField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        appLog("configureReceiverAndStartOnLaunch port=\(port)")
        DispatchQueue.global(qos: .utility).async {
            let effectivePort = port.isEmpty ? "8873" : port
            let discovered = self.discoverReceiver(port: effectivePort)
            self.appLog("initial receiver discovery local=\(discovered.localIp ?? "-") receiver=\(discovered.receiverIp ?? "-") name=\(discovered.receiverName ?? "-")")
            _ = self.configureForwarding(port: effectivePort, discovered: discovered)
            DispatchQueue.main.async {
                if let localIp = discovered.localIp {
                    self.macIpLabel.stringValue = "Mac-IP: \(localIp)"
                }
                self.startDiscoveryAndPoll()
            }
        }
    }

    private func startDiscoveryAndPoll() {
        guard !discoveryOperationInProgress else {
            appLog("startDiscoveryAndPoll skipped because operation is in progress")
            return
        }
        discoveryOperationInProgress = true
        appLog("startDiscoveryAndPoll started")
        DispatchQueue.global(qos: .utility).async {
            let startResult = self.runScript("start-discovery-test.sh")
            self.appLog("start script exit=\(startResult.exitCode) output=\(self.oneLine(startResult.output))")
            var statusResult = self.waitForRunningStatus(fallback: startResult)
            if !statusResult.output.contains("Status: running") {
                self.appLog("start status not running; retrying")
                _ = self.runScript("stop-discovery-test.sh")
                let retryStart = self.runScript("start-discovery-test.sh")
                self.appLog("retry start exit=\(retryStart.exitCode) output=\(self.oneLine(retryStart.output))")
                statusResult = self.waitForRunningStatus(fallback: retryStart)
            }
            self.appLog("final start status exit=\(statusResult.exitCode) output=\(self.oneLine(statusResult.output))")
            DispatchQueue.main.async {
                self.applyStatus(statusResult)
                self.setControlsEnabled(true)
                self.discoveryOperationInProgress = false
            }
        }
    }

    private func refreshStatus() {
        DispatchQueue.global(qos: .utility).async {
            let result = self.runScript("status-discovery-test.sh")
            DispatchQueue.main.async {
                self.applyStatus(result)
            }
        }
    }

    private func waitForRunningStatus(fallback: ScriptResult) -> ScriptResult {
        var latest = fallback
        for _ in 0..<16 {
            let status = runScript("status-discovery-test.sh")
            latest = status
            if status.output.contains("Status: running") {
                return status
            }
            Thread.sleep(forTimeInterval: 0.5)
        }
        return latest
    }

    private func applyStatus(_ result: ScriptResult) {
        let running = result.output.contains("Status: running")
        isDiscoveryRunning = running
        if running {
            statusLabel.stringValue = "Status: running"
        } else if result.output.contains("service not ready") || result.output.contains("nicht bereit") {
            statusLabel.stringValue = "Status: startet..."
        } else if result.output.contains("failed") || result.output.contains("fehlgeschlagen") || result.exitCode != 0 {
            statusLabel.stringValue = "Status: stopped"
        } else {
            statusLabel.stringValue = "Status: stopped"
        }
        toggleButton?.title = running ? "Stoppen" : "Starten"
        statusItem.button?.contentTintColor = nil
    }

    @objc private func toggleDiscovery() {
        NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
        if !isDiscoveryRunning {
            statusLabel.stringValue = "Status: startet..."
            setControlsEnabled(false)
            startDiscoveryAndPoll()
            return
        }
        setControlsEnabled(false)
        DispatchQueue.global(qos: .utility).async {
            _ = self.runScript("stop-discovery-test.sh")
            let statusResult = self.runScript("status-discovery-test.sh")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                self.applyStatus(statusResult)
                self.setControlsEnabled(true)
            }
        }
    }

    @objc private func toggleAutostart() {
        let script = autostartCheck.state == .on ? "install-macos-autostart.sh" : "uninstall-macos-autostart.sh"
        setControlsEnabled(false)
        DispatchQueue.global(qos: .utility).async {
            _ = self.runScript(script)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                self.setControlsEnabled(true)
                self.loadAutostartState()
            }
        }
    }

    @objc private func toggleMenuBarVisibility() {
        defaults.set(hideMenuBarCheck.state == .on, forKey: hideMenuBarKey)
        applyMenuBarVisibility()
    }

    func controlTextDidChange(_ notification: Notification) {
        guard let field = notification.object as? NSTextField, field === portField else {
            return
        }
        scheduleAutoSaveForwarding()
    }

    private func scheduleAutoSaveForwarding() {
        configSaveTimer?.invalidate()
        configSaveTimer = Timer.scheduledTimer(withTimeInterval: 0.7, repeats: false) { [weak self] _ in
            self?.saveForwardingAutomatically()
        }
    }

    private func saveForwardingAutomatically() {
        let port = portField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        var detectedName: String?
        if Int(port) == nil {
            statusLabel.stringValue = "Port pruefen"
            return
        }
        let detectedReceiver = discoverReceiver(port: port)
        if detectedReceiver.receiverIp != nil {
            detectedName = detectedReceiver.receiverName
        }
        setControlsEnabled(false)
        statusLabel.stringValue = "Speichere automatisch..."
        DispatchQueue.global(qos: .utility).async {
            var arguments = [
                "--windows-host", "",
                "--windows-port", port,
                "--gateway-port", port,
                "--enabled", "true"
            ]
            if let receiverName = detectedName {
                arguments += [
                    "--display-name", receiverName,
                    "--model-name", self.modelName(for: receiverName),
                ]
            }
            let result = self.runPythonScript(
                "configure-forwarding.py",
                arguments: arguments
            )
            DispatchQueue.main.async {
                if result.exitCode != 0 {
                    self.statusLabel.stringValue = "Auto-Speichern fehlgeschlagen"
                    self.setControlsEnabled(true)
                    return
                }
                self.restartDiscoveryAfterConfigChange()
            }
        }
    }

    private func restartDiscoveryAfterConfigChange() {
        guard !discoveryOperationInProgress else {
            return
        }
        discoveryOperationInProgress = true
        setControlsEnabled(false)
        DispatchQueue.global(qos: .utility).async {
            _ = self.runScript("stop-discovery-test.sh")
            let startResult = self.runScript("start-discovery-test.sh")
            let statusResult = self.waitForRunningStatus(fallback: startResult)
            DispatchQueue.main.async {
                self.applyStatus(statusResult)
                self.setControlsEnabled(true)
                self.discoveryOperationInProgress = false
            }
        }
    }

    @objc private func quit() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = ["remove", launchdLabel]
        try? process.run()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            NSApp.terminate(nil)
        }
    }

    private func setControlsEnabled(_ enabled: Bool) {
        portField.isEnabled = enabled
        autostartCheck.isEnabled = enabled
        hideMenuBarCheck.isEnabled = enabled
        toggleButton?.isEnabled = enabled
    }

    private func runScript(_ name: String) -> ScriptResult {
        let process = Process()
        let scriptURL = URL(fileURLWithPath: projectRoot)
            .appendingPathComponent("scripts")
            .appendingPathComponent(name)
        process.executableURL = scriptURL
        process.environment = environmentWithSafePath()
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8) ?? ""
            return ScriptResult(exitCode: process.terminationStatus, output: output)
        } catch {
            appLog("runScript failed script=\(scriptURL.path) error=\(error.localizedDescription)")
            return ScriptResult(exitCode: 127, output: "Konnte \(name) nicht starten: \(error.localizedDescription)")
        }
    }

    private func runPythonScript(_ name: String, arguments: [String]) -> ScriptResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.environment = environmentWithSafePath()
        process.arguments = [
            "python3",
            URL(fileURLWithPath: projectRoot).appendingPathComponent("scripts").appendingPathComponent(name).path,
            "--config",
            URL(fileURLWithPath: projectRoot).appendingPathComponent("gateway-macos/config/discovery-test.toml").path
        ] + arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8) ?? ""
            return ScriptResult(exitCode: process.terminationStatus, output: output)
        } catch {
            return ScriptResult(exitCode: 127, output: "Konnte \(name) nicht starten: \(error.localizedDescription)")
        }
    }

    private func appLog(_ message: String) {
        let root = projectRoot.isEmpty ? NSString(string: "~/Library/Application Support/UniDrop").expandingTildeInPath : projectRoot
        let logDir = URL(fileURLWithPath: root).appendingPathComponent(".runtime/menubar")
        do {
            try FileManager.default.createDirectory(at: logDir, withIntermediateDirectories: true)
            let formatter = ISO8601DateFormatter()
            let line = "\(formatter.string(from: Date())) \(message)\n"
            let logURL = logDir.appendingPathComponent("app.log")
            if let data = line.data(using: .utf8) {
                if FileManager.default.fileExists(atPath: logURL.path),
                   let handle = try? FileHandle(forWritingTo: logURL) {
                    try handle.seekToEnd()
                    try handle.write(contentsOf: data)
                    try handle.close()
                } else {
                    try data.write(to: logURL, options: .atomic)
                }
            }
        } catch {
            // Keep the GUI silent if diagnostic logging is unavailable.
        }
    }

    private func oneLine(_ text: String) -> String {
        let compact = text.replacingOccurrences(of: "\n", with: " | ")
        if compact.count <= 1200 {
            return compact
        }
        return String(compact.prefix(1200)) + "..."
    }

    private func environmentWithSafePath() -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = safeProcessPath
        return environment
    }

    private func refreshNetworkInfo() {
        guard !discoveryOperationInProgress else {
            return
        }
        let port = portField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        DispatchQueue.global(qos: .utility).async {
            let effectivePort = port.isEmpty ? "8873" : port
            let discovered = self.discoverReceiver(port: effectivePort)
            _ = self.configureForwarding(port: effectivePort, discovered: discovered)
            DispatchQueue.main.async {
                if let localIp = discovered.localIp {
                    self.macIpLabel.stringValue = "Mac-IP: \(localIp)"
                } else {
                    self.macIpLabel.stringValue = "Mac-IP: nicht gefunden"
                }
                if let receiverIp = discovered.receiverIp {
                    let receiverText = discovered.receiverName ?? receiverIp
                    self.statusLabel.stringValue = "Empfänger: \(receiverText)"
                }
            }
        }
    }

    private func configureForwarding(
        port: String,
        discovered: (localIp: String?, receiverIp: String?, receiverName: String?)
    ) -> ScriptResult {
        var arguments = [
            "--windows-host", "",
            "--windows-port", port,
            "--gateway-port", port,
            "--enabled", "true",
        ]
        if let receiverName = discovered.receiverName {
            arguments += [
                "--display-name", receiverName,
                "--model-name", self.modelName(for: receiverName),
            ]
        }
        return runPythonScript("configure-forwarding.py", arguments: arguments)
    }

    private func discoverReceiver(port: String) -> (localIp: String?, receiverIp: String?, receiverName: String?) {
        let result = runPythonScript("discover-receiver.py", arguments: ["--port", port])
        let localIp = match(result.output, #"(?m)^local_ip=(.+)$"#)
        let receiverIp = match(result.output, #"(?m)^receiver_ip=(.+)$"#)
        let receiverName = match(result.output, #"(?m)^receiver_name=(.+)$"#)
        return (
            localIp: localIp?.trimmingCharacters(in: .whitespacesAndNewlines),
            receiverIp: receiverIp?.trimmingCharacters(in: .whitespacesAndNewlines),
            receiverName: receiverName?.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    private func modelName(for receiverName: String) -> String {
        let lower = receiverName.lowercased()
        if lower.contains("galaxy") || lower.contains("android") || lower.contains("s10") {
            return "Android Phone"
        }
        if lower.contains("windows") {
            return "Windows PC"
        }
        return "UniDrop Receiver"
    }

    private func loadForwardingConfig() {
        let configURL = URL(fileURLWithPath: projectRoot).appendingPathComponent("gateway-macos/config/discovery-test.toml")
        guard let text = try? String(contentsOf: configURL, encoding: .utf8) else {
            return
        }
        if let port = match(text, #"(?m)^windows_port\s*=\s*([0-9]+)"#) {
            portField.stringValue = port
        }
    }

    private func loadAutostartState() {
        let result = runScript("status-macos-autostart.sh")
        let installed = result.output.contains("installed/running") || result.output.contains("installed/not-loaded")
        autostartCheck.state = installed ? .on : .off
    }

    private func loadMenuBarVisibilityState() {
        hideMenuBarCheck.state = defaults.bool(forKey: hideMenuBarKey) ? .on : .off
        applyMenuBarVisibility()
    }

    private func applyMenuBarVisibility() {
        statusItem.isVisible = !defaults.bool(forKey: hideMenuBarKey)
    }

    private func match(_ text: String, _ pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let result = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(result.range(at: 1), in: text) else {
            return nil
        }
        return String(text[range])
    }
}

private let app = NSApplication.shared
private let delegate = UniDropMenuBarApp()
app.delegate = delegate
app.run()
