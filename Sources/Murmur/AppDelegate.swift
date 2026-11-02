import AppKit
import UniformTypeIdentifiers

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var config = Config()
    private var configError: String?
    private var hotkeyError: String?
    private var controller: DictationController!
    private var monitor: HotkeyMonitor?
    private var retryTimer: Timer?
    private var configWatcher: FileWatcher?
    private var statusItem: NSStatusItem!

    private let history = HistoryStore()
    private let personalization = PersonalizationStore()
    private let notes = NotesStore()
    private let meeting = MeetingRecorder()
    private let transforms = TransformRunner()
    private let learner = WordLearner()
    private let status = AppStatus()
    private var mainWindow: MainWindow!

    private var enabled: Bool {
        get { UserDefaults.standard.object(forKey: "enabled") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "enabled") }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let id = Bundle.main.bundleIdentifier,
           NSRunningApplication.runningApplications(withBundleIdentifier: id).count > 1 {
            Log.info("Murmur is already running")
            NSApp.terminate(nil)
            return
        }

        DirectRoute.start()
        loadConfig()
        controller = DictationController(config: effectiveConfig())
        controller.onActivityChange = { [weak self] in self?.updateIcon() }
        wireFeatures()
        NSApp.mainMenu = MainWindow.makeMainMenu()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        Permissions.requestMissing()
        applyEnabled()
        // First load compiles Metal shaders; do it now rather than on the first dictation.
        Transcriber.warmUp(config: config)
        configWatcher = FileWatcher(url: Paths.configFile) { [weak self] in self?.reloadConfig() }

        // Opened by hand (Finder, Dock, Spotlight): show the window. Started at login: stay in the menu bar.
        if !launchedAtLogin { mainWindow.show() }
    }

    /// Double-clicking Murmur (or its Dock icon) while it's already running.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        mainWindow.show()
        return false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard meeting.isActive else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = L("A meeting is being recorded", "Se está grabando una reunión")
        alert.informativeText = L("If you quit now, it's lost. Finish it first to keep the notes.",
                                  "Si salís ahora, se pierde. Terminala primero para guardar las notas.")
        alert.addButton(withTitle: L("Keep recording", "Seguir grabando"))
        alert.addButton(withTitle: L("Quit anyway", "Salir igual"))
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertSecondButtonReturn ? .terminateNow : .terminateCancel
    }

    func applicationWillTerminate(_ notification: Notification) {
        stopMonitor()
        meeting.cancel()
        controller?.shutdown() // aborts a running whisper_full so the shutdown below doesn't wait on it
        LocalWhisper.shared.shutdown()
        notes.flush()
        PrivateFile.flush()
    }

    private var launchedAtLogin: Bool {
        guard let event = NSAppleEventManager.shared().currentAppleEvent else { return false }
        return event.eventID == kAEOpenApplication
            && event.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
    }

    // MARK: Features

    private func wireFeatures() {
        mainWindow = MainWindow(models: AppModels(history: history, personalization: personalization, notes: notes,
                                                  meeting: meeting, transforms: transforms, status: status))
        mainWindow.onFocus = { [weak self] in self?.refreshStatus() }

        controller.postProcess = { [weak self] text in
            guard let self else { return text }
            let replaced = self.personalization.applyReplacements(text)
            let front = AppContext.front()
            return Style.apply(self.personalization.tone(for: front.kind), to: replaced,
                               keep: self.controller.config.vocabulary)
        }
        controller.onTranscript = { [weak self] text, raw, seconds in
            guard let self, self.config.saveHistory else { return }
            let app = NSApp.isActive ? "Murmur" : NSWorkspace.shared.frontmostApplication?.localizedName
            self.history.add(text: text, raw: raw, seconds: seconds, app: app)
        }
        controller.onRecordingStart = { [weak self] in self?.learner.finish() }
        controller.onPasted = { [weak self] text in
            guard let self, self.personalization.learnWords else { return }
            self.learner.pasted(text)
        }

        learner.isKnown = { [weak self] word in
            guard let self else { return true }
            return self.personalization.knows(word) || self.config.vocabulary.contains { $0.caseInsensitiveCompare(word) == .orderedSame }
        }
        learner.onLearn = { [weak self] words in
            guard let self, self.personalization.learnWords else { return }
            let added = words.filter { self.personalization.addWord($0, learned: true) }
            guard !added.isEmpty else { return }
            Log.info("Learned \(added.count) word(s) from a correction")
            self.controller.notify("✨ " + L("Added to dictionary: ", "Agregado al diccionario: ") + added.joined(separator: ", "))
        }

        personalization.onChange = { [weak self] in
            guard let self else { return }
            self.controller.config = self.effectiveConfig()
            self.transforms.updateShortcuts(self.personalization)
        }
        transforms.config = config
        transforms.onBusy = { [weak self] busy in self?.controller.externalWork = busy }
        transforms.onMessage = { [weak self] text, isError in self?.controller.notify(text, isError: isError) }
        transforms.updateShortcuts(personalization)

        meeting.config = config
        meeting.onSaved = { [weak self] note in self?.notes.add(note) }
        meeting.onActivityChange = { [weak self] in self?.updateIcon() }
        refreshStatus()
    }

    /// config.json plus what was taught in the window (the dictionary's words go to Whisper and the cleanup).
    private func effectiveConfig() -> Config {
        var c = config
        c.vocabulary = personalization.vocabulary(base: config.vocabulary)
        return c
    }

    private func refreshStatus() {
        var missing: [Permissions.Pane] = []
        if !Permissions.microphone { missing.append(.microphone) }
        if !Permissions.inputMonitoring { missing.append(.inputMonitoring) }
        if !Permissions.accessibility { missing.append(.accessibility) }
        func set<T: Equatable>(_ path: ReferenceWritableKeyPath<AppStatus, T>, _ value: T) {
            if status[keyPath: path] != value { status[keyPath: path] = value }
        }
        set(\.missing, missing)
        set(\.enabled, enabled)
        set(\.listening, monitor != nil)
        set(\.hotkey, monitor?.spec.display ?? ((try? HotkeySpec.parse(config.hotkey))?.display ?? "fn"))
        set(\.configVocabulary, config.vocabulary)
        set(\.aiName, LLM.provider(config).map(\.name))
    }

    // MARK: Config

    private func loadConfig() {
        do {
            config = try ConfigStore.load()
            HTTP.bypassVPN = config.bypassVPN
            configError = nil
        } catch {
            configError = error.localizedDescription
            Log.error("Config: \(error.localizedDescription)")
        }
    }

    private func reloadConfig(showErrors: Bool = false) {
        let oldHotkey = config.hotkey
        loadConfig()
        controller.config = effectiveConfig()
        transforms.config = config
        meeting.config = config
        if config.hotkey != oldHotkey, enabled {
            controller.cancelActiveRecording()
            startMonitor()
        }
        if showErrors, let configError {
            let alert = NSAlert()
            alert.messageText = L("Settings not applied", "No se aplicaron los ajustes")
            alert.informativeText = "\(configError)\n\n" + L("Murmur keeps using the last valid settings.", "Murmur sigue usando los últimos ajustes válidos.")
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
        }
        updateIcon()
    }

    // MARK: Hotkey

    private func applyEnabled() {
        if enabled {
            startMonitor()
        } else {
            stopMonitor()
            controller.shutdown()
        }
        updateIcon()
    }

    private func startMonitor() {
        stopMonitor()
        let spec: HotkeySpec
        do {
            spec = try HotkeySpec.parse(config.hotkey)
            hotkeyError = nil
        } catch {
            hotkeyError = "\(error.localizedDescription), using fn"
            spec = try! HotkeySpec.parse("fn")
        }
        let monitor = HotkeyMonitor(spec: spec) { [weak self] event in self?.controller.handle(event) }
        if monitor.start() {
            self.monitor = monitor
            Log.info("Listening for \(spec.display)")
        } else {
            // Not permitted yet. Keep retrying so it starts working as soon as the permission is granted.
            retryTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
                guard let self, self.enabled, self.monitor == nil else { return }
                self.startMonitor()
            }
        }
        updateIcon()
    }

    private func stopMonitor() {
        retryTimer?.invalidate()
        retryTimer = nil
        monitor?.stop()
        monitor = nil
    }

    // MARK: Menu bar

    private func updateIcon() {
        refreshStatus()
        let symbol: String
        if meeting.isRecording {
            symbol = "record.circle"
        } else if !enabled {
            symbol = "mic.slash"
        } else if monitor == nil {
            symbol = "exclamationmark.triangle"
        } else if controller.isRecording {
            symbol = "mic.fill"
        } else if controller.isProcessing {
            symbol = "ellipsis.circle"
        } else {
            symbol = "mic"
        }
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Murmur")
        image?.isTemplate = true
        statusItem.button?.image = image
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let status: String
        if !enabled {
            status = L("Murmur is off", "Murmur está apagado")
        } else if monitor == nil {
            status = L("Murmur needs permissions", "Murmur necesita permisos")
        } else if controller.isRecording {
            status = L("Recording…", "Grabando…")
        } else if controller.isProcessing {
            status = L("Transcribing…", "Transcribiendo…")
        } else {
            status = L("Murmur is ready", "Murmur está listo")
        }
        menu.addItem(info(status))
        if enabled, let monitor {
            menu.addItem(info(L("Hold \(monitor.spec.display) to talk · double-tap for hands-free · Esc cancels",
                                "Mantené \(monitor.spec.display) para hablar · doble toque: manos libres · Esc cancela")))
        }

        menu.addItem(.separator())
        let open = item(L("Open Murmur", "Abrir Murmur"), #selector(openWindow))
        menu.addItem(open)
        switch meeting.phase {
        case .idle:
            menu.addItem(item(L("Record a Meeting", "Grabar una reunión"), #selector(toggleMeeting)))
        case .recording:
            menu.addItem(item(L("Finish Meeting (\(Format.duration(meeting.elapsed)))", "Terminar reunión (\(Format.duration(meeting.elapsed)))"),
                              #selector(toggleMeeting)))
        case .finishing:
            menu.addItem(info(L("Writing the meeting notes…", "Armando las notas de la reunión…")))
        }

        menu.addItem(.separator())
        menu.addItem(item(L("Enabled", "Activado"), #selector(toggleEnabled), checked: enabled))
        menu.addItem(item(L("Launch at Login", "Abrir al iniciar sesión"), #selector(toggleLogin), checked: LoginItem.isEnabled))

        menu.addItem(.separator())
        menu.addItem(info(L("Transcription: ", "Transcripción: ") + transcriptionSummary()))
        menu.addItem(info(L("Cleanup: ", "Limpieza: ") + cleanupSummary()))
        if let configError { menu.addItem(info("⚠︎ \(configError)")) }
        if let hotkeyError { menu.addItem(info("⚠︎ \(hotkeyError)")) }

        menu.addItem(.separator())
        let copy = item(L("Copy Last Transcript", "Copiar último dictado"), #selector(copyLast))
        copy.isEnabled = controller.lastTranscript != nil
        menu.addItem(copy)
        menu.addItem(item(L("Open Settings File", "Abrir archivo de ajustes"), #selector(openConfig)))
        menu.addItem(item(L("Edit API Keys (.env)", "Editar claves de API (.env)"), #selector(openEnv)))
        menu.addItem(item(L("Show Config Folder", "Mostrar carpeta de ajustes"), #selector(showFolder)))
        menu.addItem(item(L("Reload Settings", "Recargar ajustes"), #selector(reloadSettings)))

        var missing: [NSMenuItem] = []
        if !Permissions.accessibility { missing.append(item(L("Grant Accessibility…", "Dar permiso de Accesibilidad…"), #selector(grantAccessibility))) }
        if !Permissions.inputMonitoring { missing.append(item(L("Grant Input Monitoring…", "Dar permiso de Monitorización de entrada…"), #selector(grantInputMonitoring))) }
        if !Permissions.microphone { missing.append(item(L("Grant Microphone…", "Dar permiso de Micrófono…"), #selector(grantMicrophone))) }
        if !missing.isEmpty {
            menu.addItem(.separator())
            missing.forEach(menu.addItem)
        }

        menu.addItem(.separator())
        menu.addItem(item(L("Quit Murmur", "Salir de Murmur"), #selector(quit), key: "q"))
    }

    private func transcriptionSummary() -> String {
        var t = config.transcription
        t.provider = Transcriber.resolvedProvider(t)
        switch t.provider {
        case "local":
            let url = Paths.modelURL(for: t.localModel)
            let found = FileManager.default.fileExists(atPath: url.path)
            return "whisper.cpp · \(t.localModel)" + (found ? L(" (offline)", " (sin internet)") : L(" — model missing, run: make model", " — falta el modelo, ejecutá: make model"))
        case "groq", "openai":
            let key = t.provider == "groq" ? "GROQ_API_KEY" : "OPENAI_API_KEY"
            let model = t.provider == "groq" ? t.groqModel : t.openaiModel
            return "\(t.provider) · \(model)" + (Secrets.value(key) == nil ? L(" — \(key) missing", " — falta \(key)") : "")
        default:
            return "unknown provider \"\(t.provider)\""
        }
    }

    private func cleanupSummary() -> String {
        let c = config.cleanup
        guard c.enabled else { return L("off", "apagada") }
        if let p = Cleanup.resolveProvider(c) { return "\(p.name) · \(p.model)" }
        return c.provider == "auto" ? L("off (no API key in .env)", "apagada (no hay clave en .env)")
            : L("\(c.provider) unavailable (key or baseURL missing)", "\(c.provider) no disponible (falta la clave o baseURL)")
    }

    private func info(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func item(_ title: String, _ action: Selector, checked: Bool = false, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        item.state = checked ? .on : .off
        return item
    }

    // MARK: Actions

    @objc private func toggleEnabled() {
        enabled.toggle()
        applyEnabled()
    }

    @objc private func toggleLogin() { LoginItem.toggle() }

    @objc private func openWindow() { mainWindow.show() }

    @objc private func toggleMeeting() {
        if meeting.isRecording {
            meeting.stop()
        } else {
            meeting.start()
        }
        mainWindow.show(.notetaker)
    }

    @objc private func copyLast() {
        guard let text = controller.lastTranscript else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    @objc private func openConfig() { openInEditor(Paths.configFile) }
    @objc private func openEnv() { openInEditor(Paths.envFile) }
    @objc private func showFolder() { NSWorkspace.shared.activateFileViewerSelecting([Paths.configFile]) }
    @objc private func reloadSettings() { reloadConfig(showErrors: true) }
    @objc private func grantAccessibility() { Permissions.open(.accessibility) }
    @objc private func grantInputMonitoring() { Permissions.open(.inputMonitoring) }
    @objc private func grantMicrophone() { Permissions.open(.microphone) }
    @objc private func quit() { NSApp.terminate(nil) }

    private func openInEditor(_ url: URL) {
        try? ConfigStore.ensureFiles()
        let ws = NSWorkspace.shared
        guard let app = ws.urlForApplication(toOpen: url) ?? ws.urlForApplication(toOpen: .plainText) else {
            ws.activateFileViewerSelecting([url])
            return
        }
        ws.open([url], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
    }
}
