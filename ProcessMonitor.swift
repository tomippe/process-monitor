import Cocoa
import Darwin
import ServiceManagement
import Sparkle

private let processMonitorIntroURL = URL(string: "https://apps.tomippe.jp/process-monitor/")!

private struct CPUSample {
    let date: Date
    let usageByProcess: [String: Double]
}

private struct ProcessRow {
    let pid: pid_t
    let name: String
    let currentCPU: Double
    let cpuTimeSeconds: TimeInterval
}

private struct ProcessGroup {
    let name: String
    let averageCPU: Double
    let currentCPU: Double
    let cpuTimeSeconds: TimeInterval
    let pids: [pid_t]
}

class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private var timer: Timer?
    private var launchAtLoginMenuItem: NSMenuItem?
    private let updaterController = SPUStandardUpdaterController(
        startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil
    )
    private let sampleInterval: TimeInterval = 10
    private let averagingWindow: TimeInterval = 300
    private let menuNameWidth = 19
    private let cpuColumnTabStop: CGFloat = 185
    private static let processMenuIconSide: CGFloat = 18
    private var samples: [CPUSample] = []
    private var latestRows: [ProcessRow] = []
    private var latestGroups: [ProcessGroup] = []
    private var allProcessesSubmenu: NSMenu?
    private var allProcessesIconGeneration = 0
    private var currentSummary = NSLocalizedString("status.loading", comment: "")
    private let gracefulStopTimeout: TimeInterval = 8

    func applicationWillFinishLaunching(_: Notification) {
        MoveToApplicationsFolder.moveIfNecessary()
    }

    func applicationDidFinishLaunching(_: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let img = NSImage(systemSymbolName: "cpu", accessibilityDescription: NSLocalizedString("a11y.cpu", comment: "")) {
            img.isTemplate = true
            statusItem.button?.image = img
            statusItem.button?.imagePosition = .imageLeading
        }
        statusItem.button?.title = " \(currentSummary)"

        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        rebuildMenu()

        sampleCPUUsage()
        timer = Timer.scheduledTimer(withTimeInterval: sampleInterval, repeats: true) { [weak self] _ in
            self?.sampleCPUUsage()
        }
        timer?.tolerance = 1
    }

    func menuWillOpen(_ menu: NSMenu) {
        if menu === statusItem.menu {
            rebuildMenu()
            syncLaunchAtLoginItem()
        } else if menu === allProcessesSubmenu {
            rebuildAllProcessesSubmenu(menu)
        }
    }

    private func syncLaunchAtLoginItem() {
        guard #available(macOS 13.0, *) else { return }
        guard let item = launchAtLoginMenuItem else { return }
        switch SMAppService.mainApp.status {
        case .enabled:
            item.state = .on
        case .requiresApproval:
            item.state = .mixed
        default:
            item.state = .off
        }
    }

    @objc private func toggleLaunchAtLogin() {
        guard #available(macOS 13.0, *) else { return }
        Task {
            do {
                let service = SMAppService.mainApp
                if service.status == .enabled {
                    try await service.unregister()
                } else {
                    try service.register()
                }
                await MainActor.run {
                    self.syncLaunchAtLoginItem()
                }
            } catch {
                await MainActor.run {
                    let alert = NSAlert()
                    alert.messageText = NSLocalizedString("alert.loginitem_failed_title", comment: "")
                    alert.informativeText = error.localizedDescription
                    alert.alertStyle = .warning
                    alert.runModal()
                }
            }
        }
    }

    private func sampleCPUUsage() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let rows = Self.readCurrentProcesses()
            DispatchQueue.main.async {
                self?.recordSample(rows)
            }
        }
    }

    private static func readCurrentProcesses() -> [ProcessRow] {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-wwaxo", "pid=,pcpu=,time=,command="]
        process.standardOutput = pipe
        process.standardError = Pipe()

        do {
            try process.run()
        } catch {
            return []
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard let output = String(data: data, encoding: .utf8) else { return [] }

        var rows: [ProcessRow] = []
        for line in output.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            let pattern = #"^(\d+)\s+([\d.]+)\s+([0-9:.]+)\s+(.+?)$"#
            guard let match = trimmed.range(of: pattern, options: .regularExpression) else { continue }
            let matched = String(trimmed[match])
            let fields = matched.split(maxSplits: 3, whereSeparator: { $0 == " " || $0 == "\t" })
            guard fields.count == 4,
                  let pid = pid_t(String(fields[0])),
                  pid != ProcessInfo.processInfo.processIdentifier else { continue }
            let cpuText = String(fields[1])
            guard let cpu = Double(cpuText), cpu.isFinite else { continue }
            let cpuTime = parseCPUTime(String(fields[2]))
            let command = String(fields[3]).trimmingCharacters(in: .whitespacesAndNewlines)
            let name = appName(for: pid, command: command)
            rows.append(ProcessRow(pid: pid, name: name, currentCPU: max(cpu, 0), cpuTimeSeconds: cpuTime))
        }
        return rows
    }

    private static func parseCPUTime(_ value: String) -> TimeInterval {
        let parts = value.split(separator: ":").map(String.init)
        guard parts.count >= 2 else { return 0 }
        let seconds = Double(parts.last ?? "0") ?? 0
        let minutes = Double(parts.dropLast().last ?? "0") ?? 0
        let hours = parts.count >= 3 ? (Double(parts[parts.count - 3]) ?? 0) : 0
        return (hours * 3600) + (minutes * 60) + seconds
    }

    private static func executablePath(for pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 4096)
        let ret = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard ret > 0 else { return nil }
        return String(cString: buffer)
    }

    /// パスを `/` まで辿り、見つかった `.app` のうち**最も外側**（パスが最短）のバンドルを返す。
    /// Electron は `App.app/Contents/.../Helper.app/.../binary` となるため、最初の `.app` だけだとヘルパーの汎用アイコンになる。
    private static func outermostApplicationBundleURL(containingPath startPath: String) -> URL? {
        var url = URL(fileURLWithPath: startPath).resolvingSymlinksInPath()
        var candidates: [URL] = []
        var safety = 0
        while url.path != "/" && safety < 100 {
            safety += 1
            if url.pathExtension == "app" {
                candidates.append(url)
            }
            let parent = url.deletingLastPathComponent()
            if parent.path == url.path { break }
            url = parent
        }
        return candidates.min { $0.path.count < $1.path.count }
    }

    /// WindowServer 等: 実行ファイルだけのワークスペースアイコンは端末っぽい汎用アイコンになりがちなので CPU シンボルに任せる。
    private static func isSystemDaemonExecutablePath(_ path: String) -> Bool {
        let prefixes = [
            "/System/", "/usr/libexec/", "/usr/sbin/", "/sbin/", "/bin/",
            "/Library/Apple/", "/Library/System/",
        ]
        return prefixes.contains { path.hasPrefix($0) }
    }

    private static func applicationIcon(forPID pid: pid_t) -> NSImage? {
        func workspaceIcon(forPath path: String) -> NSImage? {
            guard FileManager.default.fileExists(atPath: path) else { return nil }
            let icon = NSWorkspace.shared.icon(forFile: path)
            icon.isTemplate = false
            return icon
        }

        if let exec = executablePath(for: pid),
           let bundleURL = outermostApplicationBundleURL(containingPath: exec),
           let icon = workspaceIcon(forPath: bundleURL.path) {
            return icon
        }

        if let running = NSRunningApplication(processIdentifier: pid),
           let bundleURL = running.bundleURL, bundleURL.pathExtension == "app",
           let outer = outermostApplicationBundleURL(containingPath: bundleURL.path),
           let icon = workspaceIcon(forPath: outer.path) {
            return icon
        }

        if let running = NSRunningApplication(processIdentifier: pid), let img = running.icon {
            let exec = executablePath(for: pid)
            if let exec, isSystemDaemonExecutablePath(exec), running.bundleURL == nil {
                // バンドルなしのシステムプロセスは .icon も汎用になりやすい
            } else {
                img.isTemplate = false
                return img
            }
        }

        if let exec = executablePath(for: pid),
           !isSystemDaemonExecutablePath(exec),
           let icon = workspaceIcon(forPath: exec) {
            return icon
        }

        return nil
    }

    private static func appName(for pid: pid_t, command: String) -> String {
        if let name = appNameFromCommand(command) {
            return name
        }
        guard let app = NSRunningApplication(processIdentifier: pid) else { return executableName(from: command) }
        if let bundleURL = app.bundleURL {
            for component in bundleURL.pathComponents where component.hasSuffix(".app") {
                return String(component.dropLast(4))
            }
        }
        return app.localizedName ?? executableName(from: command)
    }

    private static let activityMonitorBundleID = "com.apple.ActivityMonitor"

    /// ローカライズされたインストール先でも解決できるよう Bundle ID を優先する。
    private static func activityMonitorAppURL() -> URL? {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: activityMonitorBundleID) {
            return url
        }
        let paths = [
            "/System/Applications/Utilities/Activity Monitor.app",
            "/Applications/Utilities/Activity Monitor.app",
        ]
        for path in paths where FileManager.default.fileExists(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        return nil
    }

    private static func appNameFromCommand(_ command: String) -> String? {
        guard let appRange = command.range(of: ".app") else { return nil }
        let beforeApp = command[..<appRange.lowerBound]
        guard let slash = beforeApp.lastIndex(of: "/") else { return nil }
        let name = beforeApp[beforeApp.index(after: slash)...]
        return name.isEmpty ? nil : String(name)
    }

    private static func executableName(from command: String) -> String {
        let executable = command.split(separator: " ").first.map(String.init) ?? command
        return URL(fileURLWithPath: executable).lastPathComponent
    }

    private func recordSample(_ rows: [ProcessRow]) {
        let now = Date()
        let cutoff = now.addingTimeInterval(-averagingWindow)
        var usage: [String: Double] = [:]
        for row in rows {
            usage[row.name, default: 0] += row.currentCPU
        }
        latestRows = rows
        samples.append(CPUSample(date: now, usageByProcess: usage))
        samples.removeAll { $0.date < cutoff }
        updateStatusTitle()
        rebuildMenu()
    }

    private func updateStatusTitle() {
        latestGroups = rankedProcessGroups(limit: 20)
        guard let top = latestGroups.first else {
            currentSummary = NSLocalizedString("status.unavailable", comment: "")
            statusItem.button?.title = " \(currentSummary)"
            return
        }
        let processName = shortDisplayName(top.name)
        currentSummary = String(format: NSLocalizedString("status.format", comment: ""), processName, top.averageCPU)
        statusItem.button?.title = " \(currentSummary)"
        if let image = icon(for: top) {
            image.size = NSSize(width: 18, height: 18)
            statusItem.button?.image = image
            statusItem.button?.imagePosition = .imageLeading
        }
        statusItem.button?.toolTip = String(
            format: NSLocalizedString("status.tooltip", comment: ""),
            processName,
            top.averageCPU,
            Int(averagingWindow / 60),
            samples.count
        )
    }

    private func rankedProcessGroups(limit: Int) -> [ProcessGroup] {
        guard !samples.isEmpty else { return [] }

        var totals: [String: Double] = [:]
        for sample in samples {
            for (name, cpu) in sample.usageByProcess {
                totals[name, default: 0] += cpu
            }
        }

        var latestCPU: [String: Double] = [:]
        var latestCPUTime: [String: TimeInterval] = [:]
        var pidsByName: [String: [pid_t]] = [:]
        for row in latestRows {
            latestCPU[row.name, default: 0] += row.currentCPU
            latestCPUTime[row.name, default: 0] += row.cpuTimeSeconds
            pidsByName[row.name, default: []].append(row.pid)
        }

        return totals
            .map { name, total in
                (
                    name: name,
                    averageCPU: total / Double(samples.count),
                    currentCPU: latestCPU[name] ?? 0,
                    cpuTimeSeconds: latestCPUTime[name] ?? 0,
                    pids: pidsByName[name] ?? []
                )
            }
            .sorted { lhs, rhs in
                if lhs.averageCPU == rhs.averageCPU { return lhs.name < rhs.name }
                return lhs.averageCPU > rhs.averageCPU
            }
            .prefix(limit)
            .map { item in
                ProcessGroup(
                    name: item.name,
                    averageCPU: item.averageCPU,
                    currentCPU: item.currentCPU,
                    cpuTimeSeconds: item.cpuTimeSeconds,
                    pids: item.pids.sorted()
                )
            }
    }

    private func rebuildMenu() {
        guard let menu = statusItem.menu else { return }
        menu.removeAllItems()

        let groups = latestGroups.isEmpty ? rankedProcessGroups(limit: 20) : latestGroups
        if groups.isEmpty {
            let item = NSMenuItem(title: NSLocalizedString("menu.no_processes", comment: ""), action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        } else {
            for group in groups {
                menu.addItem(rankedMenuItem(for: group))
            }
        }
        menu.addItem(allProcessesMenuItem())

        menu.addItem(.separator())
        menu.addItem(sectionMenuItem(NSLocalizedString("menu.copy_status", comment: ""), #selector(copyStatus), "c", symbolName: "doc.on.doc"))
        menu.addItem(sectionMenuItem(NSLocalizedString("menu.refresh", comment: ""), #selector(refreshNow), "r", symbolName: "arrow.clockwise"))
        menu.addItem(activityMonitorMenuItem())
        menu.addItem(.separator())
        launchAtLoginMenuItem = nil
        if #available(macOS 13.0, *) {
            let loginItem = NSMenuItem(
                title: NSLocalizedString("menu.login_item", comment: ""),
                action: #selector(toggleLaunchAtLogin),
                keyEquivalent: ""
            )
            loginItem.target = self
            menu.addItem(loginItem)
            launchAtLoginMenuItem = loginItem
            syncLaunchAtLoginItem()
            menu.addItem(.separator())
        }
        menu.addItem(sectionMenuItem(
            NSLocalizedString("menu.about", comment: ""),
            #selector(showAboutPanel),
            "",
            symbolName: "info.circle"
        ))
        menu.addItem(sectionMenuItem(
            NSLocalizedString("menu.send_feedback", comment: ""),
            #selector(openFeedbackForm),
            "",
            symbolName: "star.bubble"
        ))
        menu.addItem(sparkleCheckForUpdatesMenuItem())
        menu.addItem(.separator())
        menu.addItem(TomippeRelaunch.restartMenuItem(
            appDisplayName: "Process Monitor",
            target: self,
            action: #selector(restartApp)
        ))
        menu.addItem(TomippeRelaunch.quitMenuItem(
            appDisplayName: "Process Monitor",
            target: self,
            action: #selector(quit),
            keyEquivalent: "q"
        ))
    }

    private func allProcessesMenuItem() -> NSMenuItem {
        let item = NSMenuItem(title: NSLocalizedString("menu.all_processes", comment: ""), action: nil, keyEquivalent: "")
        if let image = NSImage(systemSymbolName: "list.bullet", accessibilityDescription: nil) {
            image.isTemplate = true
            image.size = NSSize(width: 18, height: 18)
            item.image = image
        }
        let submenu = NSMenu()
        submenu.delegate = self
        allProcessesSubmenu = submenu
        item.submenu = submenu
        return item
    }

    private func rebuildAllProcessesSubmenu(_ menu: NSMenu) {
        menu.removeAllItems()
        allProcessesIconGeneration += 1
        let generation = allProcessesIconGeneration

        // 現時点の ps 全件を個別 PID・A-Z で出す。アイコンは後から非同期で埋める
        let rows = Self.readCurrentProcesses().sorted { lhs, rhs in
            let nameOrder = lhs.name.localizedStandardCompare(rhs.name)
            if nameOrder != .orderedSame {
                return nameOrder == .orderedAscending
            }
            return lhs.pid < rhs.pid
        }
        if rows.isEmpty {
            let item = NSMenuItem(title: NSLocalizedString("menu.no_processes", comment: ""), action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
            return
        }

        let placeholder: NSImage? = {
            guard let image = NSImage(systemSymbolName: "cpu", accessibilityDescription: NSLocalizedString("a11y.cpu", comment: "")) else {
                return nil
            }
            image.isTemplate = true
            return Self.menuSizedIcon(image)
        }()

        var pids: [pid_t] = []
        pids.reserveCapacity(rows.count)
        for row in rows {
            let group = ProcessGroup(
                name: row.name,
                averageCPU: row.currentCPU,
                currentCPU: row.currentCPU,
                cpuTimeSeconds: row.cpuTimeSeconds,
                pids: [row.pid]
            )
            let item = rankedMenuItem(for: group, includeIcon: false, showPID: true)
            item.tag = Int(row.pid)
            item.image = placeholder
            menu.addItem(item)
            pids.append(row.pid)
        }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var icons: [pid_t: NSImage] = [:]
            icons.reserveCapacity(pids.count)
            for pid in pids {
                guard let icon = Self.applicationIcon(forPID: pid) else { continue }
                icons[pid] = Self.menuSizedIcon(icon)
            }
            guard !icons.isEmpty else { return }
            DispatchQueue.main.async {
                guard let self,
                      generation == self.allProcessesIconGeneration,
                      menu === self.allProcessesSubmenu else { return }
                for item in menu.items {
                    let pid = pid_t(item.tag)
                    guard pid > 0, let icon = icons[pid] else { continue }
                    item.image = icon
                }
            }
        }
    }

    private func rankedMenuItem(for group: ProcessGroup, includeIcon: Bool = true, showPID: Bool = false) -> NSMenuItem {
        let title = menuTitle(for: group)
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        if includeIcon, let image = icon(for: group) {
            item.image = image
        }
        item.attributedTitle = NSAttributedString(
            string: title,
            attributes: [
                .font: NSFont.menuFont(ofSize: 0),
                .paragraphStyle: menuItemParagraphStyle()
            ]
        )
        let submenu = NSMenu()

        let stop = NSMenuItem(title: NSLocalizedString("menu.stop_process", comment: ""), action: #selector(stopProcessGroup(_:)), keyEquivalent: "")
        stop.target = self
        stop.representedObject = group
        stop.isEnabled = !group.pids.isEmpty
        submenu.addItem(stop)

        submenu.addItem(.separator())

        if showPID, let pid = group.pids.first {
            let pidItem = NSMenuItem(
                title: String(format: NSLocalizedString("menu.pid", comment: ""), pid),
                action: nil,
                keyEquivalent: ""
            )
            pidItem.isEnabled = false
            submenu.addItem(pidItem)
        }

        let cpuTime = NSMenuItem(
            title: String(format: NSLocalizedString("menu.cpu_time", comment: ""), formatDuration(group.cpuTimeSeconds)),
            action: nil,
            keyEquivalent: ""
        )
        cpuTime.isEnabled = false
        submenu.addItem(cpuTime)

        item.submenu = submenu
        return item
    }

    private func menuTitle(for group: ProcessGroup) -> String {
        let name = ellipsized(group.name, maxLength: menuNameWidth)
        let cpu = String(format: "%.0f%%", group.averageCPU)
        return "\(name)\t\(cpu)"
    }

    private func menuItemParagraphStyle() -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.tabStops = [
            NSTextTab(textAlignment: .right, location: cpuColumnTabStop, options: [:])
        ]
        style.defaultTabInterval = cpuColumnTabStop
        return style
    }

    private func icon(for group: ProcessGroup) -> NSImage? {
        for pid in group.pids {
            if let icon = Self.applicationIcon(forPID: pid) {
                return Self.menuSizedIcon(icon)
            }
        }
        guard let image = NSImage(systemSymbolName: "cpu", accessibilityDescription: NSLocalizedString("a11y.cpu", comment: "")) else {
            return nil
        }
        image.isTemplate = true
        return Self.menuSizedIcon(image)
    }

    /// メニュー用に固定正方形へ描き直し、アイコン幅の差でタイトル／CPU列がずれないようにする。
    private static func menuSizedIcon(_ source: NSImage, side: CGFloat = processMenuIconSide) -> NSImage {
        let size = NSSize(width: side, height: side)
        let output = NSImage(size: size, flipped: false) { bounds in
            let srcSize = source.size
            guard srcSize.width > 0, srcSize.height > 0 else { return false }
            let scale = min(bounds.width / srcSize.width, bounds.height / srcSize.height)
            let drawSize = NSSize(width: srcSize.width * scale, height: srcSize.height * scale)
            let drawRect = NSRect(
                x: bounds.midX - drawSize.width * 0.5,
                y: bounds.midY - drawSize.height * 0.5,
                width: drawSize.width,
                height: drawSize.height
            )
            NSGraphicsContext.current?.imageInterpolation = .high
            source.draw(
                in: drawRect,
                from: .zero,
                operation: .sourceOver,
                fraction: 1,
                respectFlipped: true,
                hints: [.interpolation: NSImageInterpolation.high]
            )
            return true
        }
        output.isTemplate = source.isTemplate
        return output
    }

    private func formatDuration(_ seconds: TimeInterval) -> String {
        let total = max(Int(seconds.rounded()), 0)
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        }
        return String(format: "%d:%02d", minutes, secs)
    }

    private func shortDisplayName(_ name: String) -> String {
        ellipsized(name, maxLength: 18)
    }

    private func ellipsized(_ name: String, maxLength: Int) -> String {
        if name.count <= maxLength { return name }
        let prefixLength = max(maxLength - 3, 1)
        return "\(name.prefix(prefixLength))..."
    }

    @objc private func copyStatus() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(currentSummary, forType: .string)
    }

    private func activityMonitorMenuItem() -> NSMenuItem {
        let item = NSMenuItem(
            title: NSLocalizedString("menu.open_activity_monitor", comment: ""),
            action: #selector(openActivityMonitor),
            keyEquivalent: ""
        )
        item.target = self
        if let url = Self.activityMonitorAppURL() {
            let icon = NSWorkspace.shared.icon(forFile: url.path)
            icon.isTemplate = false
            icon.size = NSSize(width: 16, height: 16)
            item.image = icon
            item.isEnabled = true
        } else if let sym = NSImage(systemSymbolName: "chart.xyaxis.line", accessibilityDescription: nil) {
            sym.isTemplate = true
            sym.size = NSSize(width: 16, height: 16)
            item.image = sym
            item.isEnabled = true
        } else {
            item.isEnabled = true
        }
        return item
    }

    @objc private func openActivityMonitor() {
        if let url = Self.activityMonitorAppURL() {
            _ = NSWorkspace.shared.open(url)
            return
        }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        task.arguments = ["-b", Self.activityMonitorBundleID]
        try? task.run()
    }

    @objc private func stopProcessGroup(_ sender: NSMenuItem) {
        guard let group = sender.representedObject as? ProcessGroup, !group.pids.isEmpty else { return }

        let alert = NSAlert()
        alert.messageText = String(format: NSLocalizedString("alert.stop_title", comment: ""), group.name)
        alert.informativeText = String(format: NSLocalizedString("alert.stop_message", comment: ""), group.pids.count)
        alert.alertStyle = .warning
        alert.addButton(withTitle: NSLocalizedString("alert.stop_button", comment: ""))
        alert.addButton(withTitle: NSLocalizedString("alert.cancel_button", comment: ""))
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        requestGracefulStop(pids: group.pids)
        refreshNow()
    }

    private func requestGracefulStop(pids: [pid_t]) {
        for pid in pids {
            if let app = NSRunningApplication(processIdentifier: pid) {
                _ = app.terminate()
            } else {
                kill(pid, SIGTERM)
            }
        }

        let timeout = gracefulStopTimeout
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) { [weak self] in
            var forcedAny = false
            for pid in pids where Self.isProcessAlive(pid) {
                forcedAny = true
                if let app = NSRunningApplication(processIdentifier: pid) {
                    _ = app.forceTerminate()
                } else {
                    kill(pid, SIGKILL)
                }
            }
            guard forcedAny else { return }
            DispatchQueue.main.async {
                self?.refreshNow()
            }
        }
    }

    private static func isProcessAlive(_ pid: pid_t) -> Bool {
        guard pid > 0 else { return false }
        if kill(pid, 0) == 0 { return true }
        return errno == EPERM
    }

    @objc private func refreshNow() {
        currentSummary = NSLocalizedString("status.loading", comment: "")
        statusItem.button?.title = " \(currentSummary)"
        sampleCPUUsage()
    }

    @objc private func showAboutPanel() {
        TomippeAppAbout.show(
            appName: "Process Monitor",
            introURL: processMonitorIntroURL,
            checkForUpdates: { [weak self] in self?.updaterController.checkForUpdates(nil) }
        )
    }

    @objc private func openFeedbackForm() {
        TomippeFeedbackForm.open(appName: "Process Monitor")
    }

    @objc private func restartApp() {
        TomippeRelaunch.relaunchCurrentApp()
    }

    @objc private func quit() {
        NSApplication.shared.terminate(nil)
    }

    private func mi(_ title: String, _ action: Selector, _ key: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    private func sectionMenuItem(_ title: String, _ action: Selector, _ key: String, symbolName: String) -> NSMenuItem {
        let item = mi(title, action, key)
        if let icon = NSImage(systemSymbolName: symbolName, accessibilityDescription: title) {
            icon.isTemplate = true
            icon.size = NSSize(width: 16, height: 16)
            item.image = icon
        }
        return item
    }

    private func sparkleCheckForUpdatesMenuItem() -> NSMenuItem {
        let title = NSLocalizedString("menu.check_for_updates", comment: "")
        let item = NSMenuItem(
            title: title,
            action: #selector(SPUStandardUpdaterController.checkForUpdates(_:)),
            keyEquivalent: ""
        )
        item.target = updaterController
        if let icon = NSImage(systemSymbolName: "arrow.down.circle", accessibilityDescription: title) {
            icon.isTemplate = true
            icon.size = NSSize(width: 16, height: 16)
            item.image = icon
        }
        return item
    }
}

@main
struct ProcessMonitorApp {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }
}
