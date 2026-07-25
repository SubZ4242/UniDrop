import AppKit
import Foundation

private struct ScriptResult {
    let exitCode: Int32
    let output: String
}

private final class UniDropMenuBarApp: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let launchdLabel = "com.windrop.gateway.menubar"
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private var window: NSWindow?
    private var statusLabel = NSTextField(labelWithString: "Status: pruefe...")
    private var macIpLabel = NSTextField(labelWithString: "Mac-IP: suche...")
    private var hostField = NSTextField(string: "")
    private var portField = NSTextField(string: "8873")
    private var autostartCheck = NSButton(checkboxWithTitle: "Mit macOS starten", target: nil, action: nil)
    private var toggleButton: NSButton?
    private var saveButton: NSButton?
    private var isDiscoveryRunning = false
    private var timer: Timer?
    private var projectRoot: String = FileManager.default.currentDirectoryPath

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        projectRoot = parseProjectRoot()
        configureStatusItem()
        buildWindow()
        refreshNetworkInfo()
        ensureDiscoveryStartsOnLaunch()
        timer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            self?.refreshStatus()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        timer?.invalidate()
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.orderOut(nil)
        return false
    }

    private func parseProjectRoot() -> String {
        let args = CommandLine.arguments
        if let index = args.firstIndex(of: "--project-root"), index + 1 < args.count {
            return args[index + 1]
        }
        if let bundledRoot = Bundle.main.object(forInfoDictionaryKey: "UniDropProjectRoot") as? String,
           !bundledRoot.isEmpty {
            return bundledRoot
        }
        return FileManager.default.currentDirectoryPath
    }

    private func configureStatusItem() {
        guard let button = statusItem.button else {
            return
        }
        button.image = dropletImage(color: .labelColor)
        button.image?.isTemplate = true
        button.toolTip = "UniDrop"
        button.target = self
        button.action = #selector(toggleWindow)
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }

    private func buildWindow() {
        let panel = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 430, height: 292),
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

        let hostRow = labeledField(label: "Ziel", field: hostField)
        let portRow = labeledField(label: "Port", field: portField)
        let toggle = button("Stoppen", #selector(toggleDiscovery))
        let save = button("Speichern", #selector(saveForwarding))
        let quitButton = button("Beenden", #selector(quit))
        let buttonRow = row([save, toggle, quitButton])
        toggleButton = toggle
        saveButton = save

        autostartCheck.target = self
        autostartCheck.action = #selector(toggleAutostart)
        autostartCheck.translatesAutoresizingMaskIntoConstraints = false

        hostField.placeholderString = "auto"
        portField.placeholderString = "8873"
        loadForwardingConfig()
        loadAutostartState()

        [icon, title, statusLabel, macIpLabel, hostRow, portRow, autostartCheck, buttonRow].forEach(content.addSubview)

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

            hostRow.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 22),
            hostRow.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -22),
            hostRow.topAnchor.constraint(equalTo: icon.bottomAnchor, constant: 38),

            portRow.leadingAnchor.constraint(equalTo: hostRow.leadingAnchor),
            portRow.trailingAnchor.constraint(equalTo: hostRow.trailingAnchor),
            portRow.topAnchor.constraint(equalTo: hostRow.bottomAnchor, constant: 10),

            autostartCheck.leadingAnchor.constraint(equalTo: hostRow.leadingAnchor, constant: 88),
            autostartCheck.trailingAnchor.constraint(equalTo: hostRow.trailingAnchor),
            autostartCheck.topAnchor.constraint(equalTo: portRow.bottomAnchor, constant: 16),

            buttonRow.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 22),
            buttonRow.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -22),
            buttonRow.topAnchor.constraint(equalTo: autostartCheck.bottomAnchor, constant: 18),
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

    private func startDiscoveryAndPoll() {
        DispatchQueue.global(qos: .utility).async {
            let startResult = self.runScript("start-discovery-test.sh")
            let statusResult = self.waitForRunningStatus(fallback: startResult)
            DispatchQueue.main.async {
                self.applyStatus(statusResult)
                self.setControlsEnabled(true)
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
        statusItem.button?.contentTintColor = running ? .systemBlue : .secondaryLabelColor
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

    @objc private func saveForwarding() {
        var host = hostField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let port = portField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        var detectedName: String?
        if Int(port) == nil {
            statusLabel.stringValue = "Port pruefen"
            return
        }
        if host.isEmpty || host.lowercased() == "auto" {
            let detectedReceiver = discoverReceiver(port: port)
            if detectedReceiver.receiverIp != nil {
                host = ""
                hostField.stringValue = "auto"
                detectedName = detectedReceiver.receiverName
            } else {
                statusLabel.stringValue = "Kein Empfänger auf Port \(port) gefunden"
                return
            }
        }
        setControlsEnabled(false)
        statusLabel.stringValue = "Speichere Konfiguration..."
        DispatchQueue.global(qos: .utility).async {
            var arguments = [
                    "--windows-host", host,
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
                    self.statusLabel.stringValue = "Speichern fehlgeschlagen"
                    self.setControlsEnabled(true)
                    return
                }
                self.restartDiscoveryAfterConfigChange()
            }
        }
    }

    private func restartDiscoveryAfterConfigChange() {
        DispatchQueue.global(qos: .utility).async {
            _ = self.runScript("stop-discovery-test.sh")
            let startResult = self.runScript("start-discovery-test.sh")
            let statusResult = self.waitForRunningStatus(fallback: startResult)
            DispatchQueue.main.async {
                self.applyStatus(statusResult)
                self.setControlsEnabled(true)
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
        hostField.isEnabled = enabled
        portField.isEnabled = enabled
        autostartCheck.isEnabled = enabled
        saveButton?.isEnabled = enabled
        toggleButton?.isEnabled = enabled
    }

    private func runScript(_ name: String) -> ScriptResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: projectRoot)
            .appendingPathComponent("scripts")
            .appendingPathComponent(name)
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

    private func runPythonScript(_ name: String, arguments: [String]) -> ScriptResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
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

    private func refreshNetworkInfo() {
        let port = portField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        DispatchQueue.global(qos: .utility).async {
            let effectivePort = port.isEmpty ? "8873" : port
            let discovered = self.discoverReceiver(port: effectivePort)
            if discovered.receiverIp != nil {
                var arguments = [
                    "--windows-host", "",
                    "--windows-port", effectivePort,
                    "--gateway-port", effectivePort,
                    "--enabled", "true",
                ]
                if let receiverName = discovered.receiverName {
                    arguments += [
                        "--display-name", receiverName,
                        "--model-name", self.modelName(for: receiverName),
                    ]
                }
                _ = self.runPythonScript("configure-forwarding.py", arguments: arguments)
            }
            DispatchQueue.main.async {
                if let localIp = discovered.localIp {
                    self.macIpLabel.stringValue = "Mac-IP: \(localIp)"
                } else {
                    self.macIpLabel.stringValue = "Mac-IP: nicht gefunden"
                }
                if let receiverIp = discovered.receiverIp {
                    self.hostField.stringValue = "auto"
                    let receiverText = discovered.receiverName ?? receiverIp
                    self.statusLabel.stringValue = "Empfänger: \(receiverText)"
                    self.restartDiscoveryAfterConfigChange()
                }
            }
        }
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
        if let host = match(text, #"(?m)^windows_host\s*=\s*"([^"]*)""#) {
            hostField.stringValue = host.isEmpty ? "auto" : host
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
