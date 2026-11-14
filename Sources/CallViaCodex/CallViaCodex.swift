import AppKit
import ApplicationServices
import ServiceManagement
import WebKit

private struct DiscoveredItem: Hashable {
    enum Kind: String { case codex, cli, application }
    let kind: Kind
    let title: String
    var displayName: String?
    let path: String
}

/// Borderless desktop panels are not key windows by default. WKWebView needs a
/// key-capable window to reliably receive mouse tracking and click events.
private final class InteractiveDesktopPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

private final class TrackingSidebarWebView: WKWebView {
    private var pointerTrackingArea: NSTrackingArea?

    override func rightMouseDown(with event: NSEvent) { presentAppMenu(for: event) }
    override func otherMouseDown(with event: NSEvent) {
        if event.buttonNumber == 1 { presentAppMenu(for: event) } else { super.otherMouseDown(with: event) }
    }

    private func presentAppMenu(for event: NSEvent) {
        let menu = NSMenu()
        let refresh = NSMenuItem(title: "刷新", action: #selector(AppDelegate.refreshFromContextMenu), keyEquivalent: "")
        refresh.target = NSApp.delegate
        menu.addItem(refresh)
        let settings = NSMenuItem(title: "设置", action: #selector(AppDelegate.settingsFromContextMenu), keyEquivalent: "")
        settings.target = NSApp.delegate
        menu.addItem(settings)
        let quit = NSMenuItem(title: "退出", action: #selector(AppDelegate.quitFromContextMenu), keyEquivalent: "")
        quit.target = NSApp.delegate
        menu.addItem(quit)
        menu.popUp(positioning: nil, at: convert(event.locationInWindow, from: nil), in: self)
    }

    override func updateTrackingAreas() {
        if let pointerTrackingArea { removeTrackingArea(pointerTrackingArea) }
        super.updateTrackingAreas()
        let area = NSTrackingArea(rect: .zero,
                                  options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                  owner: self,
                                  userInfo: nil)
        addTrackingArea(area)
        pointerTrackingArea = area
    }
}

private final class SettingsContextMenuWebView: WKWebView {
    override func rightMouseDown(with event: NSEvent) { presentAppMenu(for: event) }
    override func otherMouseDown(with event: NSEvent) {
        if event.buttonNumber == 1 { presentAppMenu(for: event) } else { super.otherMouseDown(with: event) }
    }

    private func presentAppMenu(for event: NSEvent) {
        let menu = NSMenu()
        let refresh = NSMenuItem(title: "刷新", action: #selector(AppDelegate.refreshFromContextMenu), keyEquivalent: "")
        refresh.target = NSApp.delegate
        menu.addItem(refresh)
        let settings = NSMenuItem(title: "设置", action: #selector(AppDelegate.settingsFromContextMenu), keyEquivalent: "")
        settings.target = NSApp.delegate
        menu.addItem(settings)
        let quit = NSMenuItem(title: "退出", action: #selector(AppDelegate.quitFromContextMenu), keyEquivalent: "")
        quit.target = NSApp.delegate
        menu.addItem(quit)
        menu.popUp(positioning: nil, at: convert(event.locationInWindow, from: nil), in: self)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var settingsWindow: NSWindow?
    private var aboutWindow: NSWindow?
    private var sidebarPanel: NSPanel?
    private var sidebarWebView: WKWebView?
    private var settingsWebView: WKWebView?
    private var discovered: [DiscoveredItem] = []
    private var selectedPage = 0
    private var quotaText = "额度读取中…"
    private var shadowrocketText = "状态读取中…"
    private var quotaFiveHour: Double?
    private var quotaWeekly: Double?
    private var quotaRefreshTimer: Timer?
    private let paper = NSColor(calibratedRed: 243/255, green: 244/255, blue: 248/255, alpha: 1)
    private let ink = NSColor(calibratedRed: 42/255, green: 63/255, blue: 82/255, alpha: 1)
    private let muted = NSColor(calibratedRed: 85/255, green: 103/255, blue: 117/255, alpha: 1)
    private let gold = NSColor(calibratedRed: 206/255, green: 186/255, blue: 123/255, alpha: 1)

    func applicationDidFinishLaunching(_ notification: Notification) {
        migratePaletteDefaults()
        initializeItemSelections()
        NSApp.setActivationPolicy(.accessory)
        let bar = NSMenu()
        let appMenu = NSMenu(title: "call via codex")
        let about = NSMenuItem(title: "关于 Call via Codex", action: #selector(showAbout), keyEquivalent: "")
        about.target = self; appMenu.addItem(about)
        let settings = NSMenuItem(title: "设置…", action: #selector(showSettings), keyEquivalent: "")
        settings.target = self; appMenu.addItem(settings)
        let appItem = NSMenuItem(title: "call via codex", action: nil, keyEquivalent: ""); appItem.submenu = appMenu; bar.addItem(appItem)
        let helpMenu = NSMenu(title: "帮助")
        let website = NSMenuItem(title: "访问官网", action: #selector(openWebsite), keyEquivalent: "")
        website.target = self; helpMenu.addItem(website)
        let help = NSMenuItem(title: "帮助", action: nil, keyEquivalent: ""); help.submenu = helpMenu; bar.addItem(help)
        NSApp.mainMenu = bar
        scanItems()
        refreshQuota()
        refreshShadowrocket()
        showFloatingSidebar()
        if UserDefaults.standard.object(forKey: "showSettingsOnLaunch") as? Bool ?? true { showSettings() }
    }


    private func migratePaletteDefaults() {
        let defaults = Self.sidebarPaletteDefaults
        let old = ["#f3f4f8", "#556775", "#ceba7b", "#c9c9ad", "#556775"]
        let stored = (0..<5).map { UserDefaults.standard.string(forKey: "color:\($0)") }
        if stored.compactMap({ $0 }) == old {
            let migrated = ["#556775", "#556775", "#c9c9ad", "#273043", "#556775"]
            for (index, color) in migrated.enumerated() { UserDefaults.standard.set(color, forKey: "color:\(index)") }
        }
        for index in 5..<defaults.count where UserDefaults.standard.string(forKey: "color:\(index)") == nil {
            UserDefaults.standard.set(defaults[index], forKey: "color:\(index)")
        }
    }

    private static let sidebarPaletteDefaults = ["#556775", "#556775", "#c9c9ad", "#ceba7b", "#273043", "#556775", "#556775", "#f6f2e7", "#252d3a", "#556775", "#2a3f52", "#2a3f52"]

    private func initializeItemSelections() {
        let key = "didInitializeCallViaCodexItemSelections"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        for setting in UserDefaults.standard.dictionaryRepresentation().keys where setting.hasPrefix("enabled:") {
            UserDefaults.standard.removeObject(forKey: setting)
        }
        UserDefaults.standard.set(true, forKey: key)
    }

    private func showFloatingSidebar() {
        let controller = WKUserContentController()
        controller.add(self, name: "sidebar")
        let config = WKWebViewConfiguration(); config.userContentController = controller
        let web = TrackingSidebarWebView(frame: NSRect(x: 0, y: 0, width: 340, height: 760), configuration: config)
        web.navigationDelegate = self
        web.setValue(false, forKey: "drawsBackground")
        web.wantsLayer = true; web.layer?.backgroundColor = NSColor.clear.cgColor
        let panel = InteractiveDesktopPanel(contentRect: web.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = false
        panel.alphaValue = CGFloat(UserDefaults.standard.object(forKey: "sidebarOpacity") as? Double ?? 0.7)
        panel.ignoresMouseEvents = false; panel.acceptsMouseMovedEvents = true; panel.becomesKeyOnlyIfNeeded = false
        // Sit above Finder's desktop/icon windows so physical pointer input reaches
        // the sidebar, while remaining immediately below ordinary app windows.
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.normalWindow)) - 1)
        panel.collectionBehavior = [.canJoinAllSpaces]
        panel.hidesOnDeactivate = false; panel.contentView = web
        if let page = Bundle.main.url(forResource: "index", withExtension: "html", subdirectory: "Sidebar") {
            web.loadFileURL(page, allowingReadAccessTo: page.deletingLastPathComponent())
        }
        sidebarPanel = panel; sidebarWebView = web
        positionSidebar()
        panel.orderFrontRegardless()
    }

    private func updateSidebar() {
        guard let data = try? JSONSerialization.data(withJSONObject: [quotaFiveHour as Any? ?? NSNull(), quotaWeekly as Any? ?? NSNull(), shadowrocketText == "Shadowrocket 已连接"]), let json = String(data: data, encoding: .utf8) else { return }
        sidebarWebView?.evaluateJavaScript("window.setStatus(...\(json))")
        let side = UserDefaults.standard.string(forKey: "sidebarSide") ?? "左侧"
        sidebarWebView?.evaluateJavaScript("window.setSide('\(side)')")
        updateSidebarColors()
        let base = UserDefaults.standard.string(forKey: "font:default")?.filter(\.isNumber) ?? "9"
        let hover = UserDefaults.standard.string(forKey: "font:hover")?.filter(\.isNumber) ?? "12"
        sidebarWebView?.evaluateJavaScript("window.setFonts(\(base),\(hover))")
    }

    private func updateSidebarItems() {
        let count = max(1, min(30, UserDefaults.standard.object(forKey: "sidebarItemCount") as? Int ?? 8))
        let items = discovered.enumerated().filter { isEnabled($0.element) }.map { item in
            ["title": sidebarName(for: item.element), "displayName": item.element.kind == .codex ? (item.element.displayName ?? "") : "", "index": item.offset] as [String: Any]
        }
        guard let data = try? JSONSerialization.data(withJSONObject: items), let json = String(data: data, encoding: .utf8) else { return }
        sidebarWebView?.evaluateJavaScript("window.setItems(\(json),\(count))")
    }

    private func handleSidebarMessage(_ body: Any) {
        guard let payload = body as? [String: Any] else { return }
        if payload["action"] as? String == "contextMenu" {
            showContextMenu(in: sidebarWebView, payload: payload)
            return
        }
        if payload["action"] as? String == "shadowrocketToggle" {
            openShadowrocket(shadowrocketText == "Shadowrocket 已连接" ? "disconnect" : "connect")
            return
        }
        if let visible = payload["visible"] as? Bool {
            visible ? sidebarPanel?.orderFrontRegardless() : sidebarPanel?.orderOut(nil)
            return
        }
        guard let index = payload["index"] as? Int, discovered.indices.contains(index) else { return }
        callItem(withIndex: index)
    }

    private func updateSettingsPage() {
        let groups: [String: [[String: Any]]] = [
            "codex": discovered.enumerated().filter { $0.element.kind == .codex }.map { itemData($0.element, index: $0.offset) },
            "cli": discovered.enumerated().filter { $0.element.kind == .cli }.map { itemData($0.element, index: $0.offset) },
            "application": discovered.enumerated().filter { $0.element.kind == .application }.map { itemData($0.element, index: $0.offset) }
        ]
        let colors = Self.sidebarPaletteDefaults.indices.map { UserDefaults.standard.string(forKey: "color:\($0)") ?? Self.sidebarPaletteDefaults[$0] }
        let payload: [String: Any] = ["groups": groups, "quota5": quotaFiveHour as Any? ?? NSNull(), "quotaWeek": quotaWeekly as Any? ?? NSNull(), "shadowrocket": shadowrocketText == "Shadowrocket 已连接", "colors": colors,
            "launch": UserDefaults.standard.object(forKey: "showSettingsOnLaunch") as? Bool ?? true,
            "login": UserDefaults.standard.bool(forKey: "launchAtLogin"), "opacity": Int((UserDefaults.standard.object(forKey: "sidebarOpacity") as? Double ?? 0.7) * 100),
            "displayCount": UserDefaults.standard.object(forKey: "sidebarItemCount") as? Int ?? 8,
            "verticalOffset": UserDefaults.standard.object(forKey: "sidebarVerticalOffset") as? Int ?? 0,
            "side": UserDefaults.standard.string(forKey: "sidebarSide") ?? "左侧",
            "defaultFont": UserDefaults.standard.string(forKey: "font:default") ?? "9 pt",
            "hoverFont": UserDefaults.standard.string(forKey: "font:hover") ?? "12 pt",
            "customNames": UserDefaults.standard.object(forKey: "customNames") as? Bool ?? true]
        guard let data = try? JSONSerialization.data(withJSONObject: payload), let json = String(data: data, encoding: .utf8) else { return }
        settingsWebView?.evaluateJavaScript("window.setData(\(json))")
    }

    private func itemData(_ item: DiscoveredItem, index: Int) -> [String: Any] {
        ["title": item.title, "displayName": item.displayName ?? "", "name": visibleName(for: item), "path": item.path, "enabled": isEnabled(item), "index": index]
    }

    private func sidebarName(for item: DiscoveredItem) -> String {
        visibleName(for: item)
    }

    private func handleSettingsMessage(_ body: Any) {
        guard let message = body as? [String: Any], let action = message["action"] as? String else { return }
        switch action {
        case "contextMenu":
            showContextMenu(in: settingsWebView, payload: message)
        case "item":
            if let index = message["index"] as? Int { callItem(withIndex: index) }
        case "enabled":
            guard let path = message["path"] as? String, let value = message["enabled"] as? Bool else { return }
            UserDefaults.standard.set(value, forKey: "enabled:" + path); updateSettingsPage(); updateSidebarItems()
        case "rename":
            guard let path = message["path"] as? String, let value = message["value"] as? String else { return }
            UserDefaults.standard.set(value, forKey: "name:" + path); updateSettingsPage(); updateSidebarItems()
        case "page":
            selectedPage = message["page"] as? Int ?? 0
        case "nameMode":
            if let value = message["custom"] as? Bool { UserDefaults.standard.set(value, forKey: "customNames"); updateSidebarItems() }
        case "refresh": refreshEverything()
        case "quit": NSApp.terminate(nil)
        case "website": openWebsite()
        case "settings": showSettings()
        case "opacity":
            if let value = message["value"] as? Double { let opacity = max(0.2, min(1, value)); UserDefaults.standard.set(opacity, forKey: "sidebarOpacity"); sidebarPanel?.alphaValue = opacity; sidebarWebView?.evaluateJavaScript("window.setOpacity(\(opacity))") }
        case "side":
            if let value = message["value"] as? String {
                UserDefaults.standard.set(value, forKey: "sidebarSide")
                positionSidebar()
                sidebarWebView?.evaluateJavaScript("window.setSide('\(value)')")
            }
        case "displayCount":
            if let value = message["value"] as? Int {
                UserDefaults.standard.set(max(1, min(30, value)), forKey: "sidebarItemCount")
                updateSidebarItems(); updateSettingsPage()
            }
        case "verticalOffset":
            if let value = message["value"] as? Int {
                UserDefaults.standard.set(max(-2000, min(2000, value)), forKey: "sidebarVerticalOffset")
                positionSidebar(); updateSettingsPage()
            }
        case "setting":
            if let key = message["key"] as? String, let value = message["value"] as? Bool {
                if key == "launchAtLogin" {
                    do { if value { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }; UserDefaults.standard.set(value, forKey: key) }
                    catch { UserDefaults.standard.set(false, forKey: key); settingsWebView?.evaluateJavaScript("window.setLogin(false)") }
                } else { UserDefaults.standard.set(value, forKey: key) }
            }
        case "font":
            if let key = message["key"] as? String, let value = message["value"] as? String { UserDefaults.standard.set(value, forKey: "font:" + key); sidebarWebView?.evaluateJavaScript("window.setFonts(\(UserDefaults.standard.string(forKey: "font:default")?.filter(\.isNumber) ?? "9"),\(UserDefaults.standard.string(forKey: "font:hover")?.filter(\.isNumber) ?? "12"))") }
        case "color":
            if let index = message["index"] as? Int, let value = message["value"] as? String, Self.sidebarPaletteDefaults.indices.contains(index) { UserDefaults.standard.set(value, forKey: "color:\(index)"); updateSidebarColors(); updateSettingsPage() }
        case "resetColors":
            for index in Self.sidebarPaletteDefaults.indices { UserDefaults.standard.removeObject(forKey: "color:\(index)") }; updateSettingsPage(); updateSidebarColors()
        case "confirmColors": updateSettingsPage(); updateSidebarColors()
        default: break
        }
    }

    @objc private func showSettings() {
        sidebarPanel?.orderFrontRegardless()
        if settingsWindow == nil || settingsWindow?.isVisible == false {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 580), styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
            window.title = "设置"
            window.center()
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.contentView = makeSettings()
            settingsWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window === settingsWindow else { return }
        settingsWindow = nil
        settingsWebView = nil
    }

    private func positionSidebar() {
        guard let screen = NSScreen.main, let panel = sidebarPanel else { return }
        let visible = screen.visibleFrame
        let side = UserDefaults.standard.string(forKey: "sidebarSide") ?? "左侧"
        let offset = CGFloat(UserDefaults.standard.object(forKey: "sidebarVerticalOffset") as? Int ?? 0)
        let requestedY = visible.midY - panel.frame.height / 2 + offset
        let y = min(max(requestedY, visible.minY), max(visible.minY, visible.maxY - panel.frame.height))
        let x = side == "右侧" ? visible.maxX - panel.frame.width : visible.minX
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }

    @objc private func showAbout() {
        if aboutWindow == nil {
            let window = NSWindow(contentRect: NSRect(x:0,y:0,width:440,height:350),styleMask:[.titled,.closable],backing:.buffered,defer:false)
            window.title = "关于 Call via Codex"
            window.center()
            let content=NSView(frame:NSRect(x:0,y:0,width:440,height:350)); content.wantsLayer=true; content.layer?.backgroundColor=NSColor.white.cgColor
            if let iconURL=Bundle.main.url(forResource:"call-via-codex",withExtension:"svg"),let image=NSImage(contentsOf:iconURL) { let icon=NSImageView(image:image); icon.imageScaling = .scaleProportionallyUpOrDown; icon.frame=NSRect(x:170,y:225,width:100,height:100); content.addSubview(icon) }
            let title=label("call via codex",size:20,weight:.semibold); title.alignment = .center; title.frame=NSRect(x:40,y:185,width:360,height:28); content.addSubview(title)
            let version=label("v1.0.0",size:13,weight:.regular); version.alignment = .center; version.frame=NSRect(x:40,y:150,width:360,height:22); content.addSubview(version)
            let desc=label("在Codex中快速调用技能与工具。",size:13,weight:.regular); desc.alignment = .center; desc.frame=NSRect(x:30,y:100,width:380,height:25); content.addSubview(desc)
            let copyright=label("© 北京正笔正心文化发展有限公司",size:13,weight:.regular); copyright.alignment = .center; copyright.frame=NSRect(x:30,y:68,width:380,height:22); content.addSubview(copyright)
            let website=NSButton(title:"https://www.zhengxinshushe.com/  ↗",target:self,action:#selector(openWebsite)); website.isBordered=false; website.font = .systemFont(ofSize:12); website.contentTintColor=NSColor(calibratedRed:7/255,green:86/255,blue:198/255,alpha:1); website.frame=NSRect(x:60,y:40,width:320,height:22); content.addSubview(website)
            window.contentView=content; aboutWindow=window
        }
        NSApp.activate(ignoringOtherApps:true); aboutWindow?.makeKeyAndOrderFront(nil)
    }
    @objc private func openWebsite() { NSWorkspace.shared.open(URL(string: "https://www.zhengxinshushe.com/")!) }

    private func makeSettings() -> NSView {
        let controller = WKUserContentController(); controller.add(self, name: "settings")
        let config = WKWebViewConfiguration(); config.userContentController = controller
        let web = SettingsContextMenuWebView(frame: NSRect(x: 0, y: 0, width: 760, height: 580), configuration: config)
        web.navigationDelegate = self; web.setValue(false, forKey: "drawsBackground")
        if let url = Bundle.main.url(forResource: "settings", withExtension: "html", subdirectory: "Sidebar") { web.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent().deletingLastPathComponent()) }
        settingsWebView = web
        return web
    }

    private func showContextMenu(in webView: WKWebView?, payload: [String: Any]) {
        guard let webView else { return }
        let x = CGFloat((payload["x"] as? Double) ?? 0)
        let y = CGFloat((payload["y"] as? Double) ?? 0)
        let menu = NSMenu()
        let refresh = NSMenuItem(title: "刷新", action: #selector(refreshEverything), keyEquivalent: "")
        refresh.target = self
        menu.addItem(refresh)
        let settings = NSMenuItem(title: "设置", action: #selector(settingsFromContextMenu), keyEquivalent: "")
        settings.target = self
        menu.addItem(settings)
        let quit = NSMenuItem(title: "退出", action: #selector(quitFromContextMenu), keyEquivalent: "")
        quit.target = self
        menu.addItem(quit)
        let localY = webView.isFlipped ? y : webView.bounds.height - y
        menu.popUp(positioning: nil, at: NSPoint(x: x, y: localY), in: webView)
    }

    @objc func quitFromContextMenu() { NSApp.terminate(nil) }
    @objc func refreshFromContextMenu() { refreshEverything() }
    @objc func settingsFromContextMenu() { showSettings() }
    private func scanItems() {
        let fm = FileManager.default; let home = fm.homeDirectoryForCurrentUser
        let skillRoots = [home.appendingPathComponent(".codex/skills"), home.appendingPathComponent(".agents/skills")]
        for root in skillRoots {
            for url in (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey])) ?? [] where url.hasDirectoryPath && url.lastPathComponent != ".system" {
                discovered.append(DiscoveredItem(kind: .codex, title: url.lastPathComponent, displayName: skillDisplayName(at: url), path: url.path))
            }
        }
        let pluginRoot = home.appendingPathComponent(".codex/plugins/cache")
        for catalog in (try? fm.contentsOfDirectory(at: pluginRoot, includingPropertiesForKeys: [.isDirectoryKey])) ?? [] where catalog.hasDirectoryPath {
            for plugin in (try? fm.contentsOfDirectory(at: catalog, includingPropertiesForKeys: [.isDirectoryKey])) ?? [] where plugin.hasDirectoryPath {
                let versions = ((try? fm.contentsOfDirectory(at: plugin, includingPropertiesForKeys: [.isDirectoryKey])) ?? []).filter(\.hasDirectoryPath)
                let candidates = versions.isEmpty ? [plugin] : versions
                for version in candidates {
                    guard let metadata = pluginMetadata(at: version) ?? pluginMetadata(at: plugin) else { continue }
                    let canonical = (metadata["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? plugin.lastPathComponent
                    let display = pluginDisplayName(metadata)
                    discovered.append(DiscoveredItem(kind: .codex, title: canonical, displayName: display, path: version.path))
                }
            }
        }
        var pathDirectories = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
        pathDirectories += ["/opt/homebrew/bin", "/opt/homebrew/sbin", "/usr/local/bin", "/usr/local/sbin"]
        let systemBins: Set<String> = ["/usr/bin", "/bin", "/usr/sbin", "/sbin", "/System/Library/Apple/usr/bin", "/Library/Apple/usr/bin"]
        let injectedRuntimeRoots = ["/pkg/", "/Applications/ChatGPT.app/", home.appendingPathComponent(".cache/codex-runtimes").path, home.appendingPathComponent(".codex/tmp").path]
        pathDirectories = pathDirectories.map { URL(fileURLWithPath: $0).standardizedFileURL.path }
            .filter { path in !systemBins.contains(path) && !path.hasPrefix("/System/") && !injectedRuntimeRoots.contains(where: { path == $0 || path.hasPrefix($0) }) }
        var seenDirectories = Set<String>()
        pathDirectories = pathDirectories.filter { seenDirectories.insert($0).inserted }
        var seenCommands = Set<String>()
        for directory in pathDirectories {
            let base = URL(fileURLWithPath: directory)
            for name in (try? fm.contentsOfDirectory(atPath: base.path)) ?? [] {
                let path = base.appendingPathComponent(name).path
                var isDirectory: ObjCBool = false
                if fm.fileExists(atPath: path, isDirectory: &isDirectory), !isDirectory.boolValue, fm.isExecutableFile(atPath: path), seenCommands.insert(name.lowercased()).inserted {
                    discovered.append(DiscoveredItem(kind: .cli, title: name, displayName: nil, path: path))
                }
            }
        }
        let appRoots = [URL(fileURLWithPath: "/Applications"), home.appendingPathComponent("Applications")]
        for root in appRoots {
            guard let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else { continue }
            for case let url as URL in enumerator where url.pathExtension == "app" {
                discovered.append(DiscoveredItem(kind: .application, title: url.deletingPathExtension().lastPathComponent, displayName: nil, path: url.path))
                enumerator.skipDescendants()
            }
        }
        let unique = Array(Set(discovered))
        discovered = unique.sorted {
            let rank: (DiscoveredItem.Kind) -> Int = { kind in kind == .codex ? 0 : kind == .cli ? 1 : 2 }
            if rank($0.kind) != rank($1.kind) { return rank($0.kind) < rank($1.kind) }
            return $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
        }
    }

    private func skillDisplayName(at url: URL) -> String? {
        let manifest = url.appendingPathComponent("agents/openai.yaml")
        guard let text = try? String(contentsOf: manifest, encoding: .utf8) else { return nil }
        var inInterface = false
        for line in text.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed == "interface:" { inInterface = true; continue }
            if inInterface, !line.isEmpty, !line.first!.isWhitespace { inInterface = false }
            guard inInterface, trimmed.hasPrefix("display_name:") else { continue }
            let range = line.range(of: "display_name:")!
            let value = line[range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            return value.isEmpty ? nil : value
        }
        return nil
    }

    private func pluginMetadata(at url: URL) -> [String: Any]? {
        let file = url.appendingPathComponent(".codex-plugin/plugin.json")
        guard let data = try? Data(contentsOf: file) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private func pluginDisplayName(_ metadata: [String: Any]) -> String? {
        let interface = metadata["interface"] as? [String: Any]
        return (interface?["display_name"] as? String) ?? (interface?["displayName"] as? String)
    }

    private func itemTag(for item: DiscoveredItem) -> Int { discovered.firstIndex(of: item) ?? 0 }
    private func isEnabled(_ item: DiscoveredItem) -> Bool { UserDefaults.standard.object(forKey: "enabled:" + item.path) as? Bool ?? false }
    private func visibleName(for item: DiscoveredItem) -> String { UserDefaults.standard.string(forKey: "name:" + item.path).flatMap { $0.isEmpty ? nil : $0 } ?? item.displayName ?? item.title }
    @objc private func toggleItem(_ sender: NSButton) {
        guard discovered.indices.contains(sender.tag) else { return }
        UserDefaults.standard.set(sender.state == .on, forKey: "enabled:" + discovered[sender.tag].path)
        sender.superview?.subviews.compactMap { $0 as? NSButton }.first(where: { $0.tag == sender.tag && $0 !== sender })?.isEnabled = sender.state == .on
    }
    @objc private func callItem(_ sender: NSButton) {
        callItem(withIndex: sender.tag)
    }
    private func callItem(withIndex index: Int) {
        guard discovered.indices.contains(index) else { return }
        let item = discovered[index]
        let prompt: String
        switch item.kind {
        case .codex: prompt = "$\(codexInvocationName(for: item)) "
        case .cli: prompt = "请使用终端命令 `\(item.title)` 完成："
        case .application: prompt = "@电脑 打开 \(item.title)，"
        }
        prefillCodex(prompt)
    }
    private func codexInvocationName(for item: DiscoveredItem) -> String {
        let base = URL(fileURLWithPath: item.path)
        let skillManifest = base.appendingPathComponent("SKILL.md")
        if let source = try? String(contentsOf: skillManifest, encoding: .utf8) {
            for line in source.components(separatedBy: .newlines).prefix(20) {
                guard line.hasPrefix("name:") else { continue }
                return line.dropFirst("name:".count).trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            }
        }
        var directory = base
        for _ in 0..<4 {
            let manifest = directory.appendingPathComponent(".codex-plugin/plugin.json")
            if let data = try? Data(contentsOf: manifest),
               let metadata = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let name = metadata["name"] as? String, !name.isEmpty { return name }
            directory.deleteLastPathComponent()
        }
        return item.title
    }
    @objc private func renameItem(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String, let item = discovered.first(where: { $0.path == path }) else { return }
        let alert = NSAlert(); alert.messageText = "自定义名称"; alert.informativeText = item.title
        let field = NSTextField(string: visibleName(for: item)); field.frame = NSRect(x: 0, y: 0, width: 260, height: 24); alert.accessoryView = field
        alert.addButton(withTitle: "保存"); alert.addButton(withTitle: "取消")
        if alert.runModal() == .alertFirstButtonReturn { UserDefaults.standard.set(field.stringValue, forKey: "name:" + path); redrawCurrentPage() }
    }
    @objc private func resetItemName(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String else { return }
        UserDefaults.standard.removeObject(forKey: "name:" + path); redrawCurrentPage()
    }
    private func redrawCurrentPage() {
        updateSettingsPage()
    }

    private func updateSidebarColors() {
        let colors = Self.sidebarPaletteDefaults.indices.map { UserDefaults.standard.string(forKey: "color:\($0)") ?? Self.sidebarPaletteDefaults[$0] }
        guard let data = try? JSONSerialization.data(withJSONObject: colors), let json = String(data: data, encoding: .utf8) else { return }
        sidebarWebView?.evaluateJavaScript("window.setColors(\(json))")
    }
    private func prefillCodex(_ prompt: String) {
        let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.openai.codex")
            ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.openai.chat")
        if let app { NSWorkspace.shared.openApplication(at: app, configuration: NSWorkspace.OpenConfiguration()) }
        else { _ = try? Process.run(URL(fileURLWithPath: "/usr/bin/open"), arguments: ["-a", "Codex"]) }
        guard AXIsProcessTrusted() else {
            let alert = NSAlert(); alert.messageText = "需要设备控制与数据访问权限"; alert.informativeText = "请在“系统设置 → 隐私与安全性 → 设备控制与数据访问”允许当前这份 call-via-codex 控制 Codex 输入框，再点击项目即可预填调用内容。"; alert.runModal(); return
        }
        let pasteboard = NSPasteboard.general
        let oldItems = pasteboard.pasteboardItems?.map { item -> [(NSPasteboard.PasteboardType, Data)] in item.types.compactMap { type in item.data(forType: type).map { (type, $0) } } } ?? []
        pasteboard.clearContents(); pasteboard.setString(prompt, forType: .string)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            let down = CGEvent(keyboardEventSource: nil, virtualKey: 9, keyDown: true)
            let up = CGEvent(keyboardEventSource: nil, virtualKey: 9, keyDown: false)
            down?.flags = .maskCommand; up?.flags = .maskCommand; down?.post(tap: .cghidEventTap); up?.post(tap: .cghidEventTap)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                pasteboard.clearContents()
                let restored = oldItems.map { entries -> NSPasteboardItem in let item = NSPasteboardItem(); for (type,data) in entries { item.setData(data, forType: type) }; return item }
                if !restored.isEmpty { pasteboard.writeObjects(restored) }
            }
        }
    }
    @objc private func pageSelected(_ sender:NSButton) {
        selectedPage = sender.tag
        guard let content=settingsWindow?.contentView else{return}
        for view in content.subviews where view.frame.origin.x >= 200 { view.removeFromSuperview() }
        let names=["项目列表","界面设置","通用设置","关于应用"]
        let head=label(names[sender.tag],size:20,weight:.semibold); head.frame=NSRect(x:210,y:466,width:460,height:30); content.addSubview(head)
        switch sender.tag {
        case 1:
            let size = label("文字默认 9 pt，悬停最大 12 pt。\n侧栏贴合屏幕左侧并保持透明。",size:12,weight:.regular); size.frame=NSRect(x:210,y:408,width:470,height:54); content.addSubview(size)
        case 2:
            let status = label("Codex 额度：\(quotaText)\nShadowrocket：\(shadowrocketText)",size:12,weight:.regular); status.frame=NSRect(x:210,y:400,width:480,height:42); content.addSubview(status)
            let refresh = NSButton(title:"扫描与刷新",target:self,action:#selector(refreshEverything)); refresh.frame=NSRect(x:210,y:350,width:140,height:30); refresh.contentTintColor=ink; content.addSubview(refresh)
            let connect = NSButton(title:"连接 Shadowrocket",target:self,action:#selector(connectShadowrocket)); connect.frame=NSRect(x:210,y:300,width:160,height:30); content.addSubview(connect)
            let disconnect = NSButton(title:"断开 Shadowrocket",target:self,action:#selector(disconnectShadowrocket)); disconnect.frame=NSRect(x:380,y:300,width:160,height:30); content.addSubview(disconnect)
            let q=NSButton(title:"彻底退出",target:NSApp,action:#selector(NSApplication.terminate(_:))); q.frame=NSRect(x:210,y:250,width:110,height:30); q.contentTintColor=gold; content.addSubview(q)
        case 3:
            if let iconURL=Bundle.main.url(forResource:"call-via-codex",withExtension:"svg"),let image=NSImage(contentsOf:iconURL) { let icon=NSImageView(image:image); icon.frame=NSRect(x:390,y:320,width:96,height:96); icon.imageScaling = .scaleProportionallyUpOrDown; content.addSubview(icon) }
            let desc=label("call via codex\nv1.0.0\n在Codex中快速调用技能与工具。\n© 北京正笔正心文化发展有限公司",size:12,weight:.regular); desc.alignment = .center; desc.frame=NSRect(x:250,y:170,width:380,height:130); content.addSubview(desc)
            let site=NSButton(title:"访问官网",target:self,action:#selector(openWebsite)); site.frame=NSRect(x:380,y:125,width:100,height:28); content.addSubview(site)
        default: break
        }
    }
    @objc private func refreshEverything() { discovered.removeAll(); scanItems(); refreshQuota(); refreshShadowrocket(); redrawCurrentPage() }
    private func refreshQuota() {
        quotaText = "Codex 额度读取中…"
        CodexUsageReader.read { [weak self] result in
            guard let self else { return }
            self.quotaFiveHour = result.windows.first(where: { $0.title == "五小时" })?.remainingPercent
            self.quotaWeekly = result.windows.first(where: { $0.title == "本周" })?.remainingPercent
            if result.windows.isEmpty { self.quotaText = result.error ?? "额度不可用" }
            else { self.quotaText = result.windows.map { "\($0.title)剩余 \(Int($0.remainingPercent.rounded()))%" }.joined(separator: "，") }
            self.updateSidebar()
            self.updateSettingsPage()
            self.redrawCurrentPage()
        }
    }
    private func refreshShadowrocket() {
        let task = Process(); task.executableURL = URL(fileURLWithPath: "/usr/sbin/scutil"); task.arguments = ["--nc", "list"]
        let pipe = Pipe(); task.standardOutput = pipe; task.standardError = Pipe()
        do {
            try task.run(); let output = pipe.fileHandleForReading.readDataToEndOfFile(); task.waitUntilExit()
            let listing = String(decoding: output, as: UTF8.self)
            if let line = listing.split(separator: "\n").first(where: { $0.contains("com.liguangming.Shadowrocket") }) {
                let status = String(line)
                shadowrocketText = status.contains("(Connected)") ? "Shadowrocket 已连接" : status.contains("(Disconnected)") ? "Shadowrocket 已断开" : "Shadowrocket 状态不可用"
            } else { shadowrocketText = "Shadowrocket 状态不可用" }
        }
        catch { shadowrocketText = "Shadowrocket 状态不可用" }
        updateSidebar()
    }
    @objc private func connectShadowrocket() { openShadowrocket("connect") }
    @objc private func disconnectShadowrocket() { openShadowrocket("disconnect") }
    private func openShadowrocket(_ action: String) {
        guard let url = URL(string: "shadowrocket://\(action)") else { return }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.hides = true
        NSWorkspace.shared.open(url, configuration: configuration)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { self.refreshShadowrocket(); self.redrawCurrentPage() }
    }
    private func label(_ text:String,size:CGFloat,weight:NSFont.Weight)->NSTextField { let f=NSTextField(labelWithString:text); f.font = .systemFont(ofSize:size,weight:weight); f.textColor=ink; f.lineBreakMode = .byTruncatingTail; return f }
}

extension AppDelegate: WKScriptMessageHandler, WKNavigationDelegate {
    nonisolated func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        Task { @MainActor in
            if message.name == "settings" { self.handleSettingsMessage(message.body) }
            else { self.handleSidebarMessage(message.body) }
        }
    }
    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor in
            if webView === self.settingsWebView { self.updateSettingsPage() }
            else { self.updateSidebarItems(); self.updateSidebar() }
        }
    }
}

@main
@MainActor
enum CallViaCodexMain {
    static func main() {
        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        application.run()
    }
}
private extension Array where Element: Hashable { func uniqued()->[Element] { var s=Set<Element>(); return filter{s.insert($0).inserted} } }
