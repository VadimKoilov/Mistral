//
//  FanController.swift — центральный контроллер: опрос датчиков, авто-регулятор,
//  ручное управление, состояния хелпера.
//

import Foundation
import AppKit
import ServiceManagement
import SMCCore

// MARK: - Датчики температуры (Apple M1/M1 Pro/M1 Max, по smctemp)

enum Thermals {
    /// P-ядра (8) и E-ядра (2)
    static let cpuKeys = ["Tp01", "Tp05", "Tp0D", "Tp0H", "Tp0L", "Tp0P", "Tp0X", "Tp0b",
                          "Tp09", "Tp0T"]
    static let gpuKeys = ["Tg05", "Tg0D", "Tg0L", "Tg0P", "Tg0T", "Tg0U", "Tg0X", "Tg0b",
                          "Tg0d", "Tg0f", "Tg0g", "Tg0j", "Tg0v"]
}

// MARK: - Нагрузка CPU

final class CPULoad {
    private var prev: [Double] = []

    func current() -> Double {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return 0 }
        let t = info.cpu_ticks
        let ticks = [Double(t.0), Double(t.1), Double(t.2), Double(t.3)]
        guard prev.count == 4 else { prev = ticks; return 0 }
        let dt = zip(ticks, prev).map { max(0, $0 - $1) }
        prev = ticks
        let total = dt.reduce(0, +)
        guard total > 0 else { return 0 }
        // user + sys + nice (индексы: 0=user, 1=system, 2=idle, 3=nice)
        return min(1.0, (dt[0] + dt[1] + dt[3]) / total)
    }
}

// MARK: - Контроллер

final class FanController: ObservableObject {

    static let shared = FanController()

    enum Mode: String {
        case system   // системное автоуправление
        case auto     // наш авто-регулятор
        case manual   // ручные обороты

        var title: String {
            switch self {
            case .system: return "Система"
            case .auto: return "Авто"
            case .manual: return "Ручной"
            }
        }
    }

    enum Profile: String, CaseIterable, Identifiable {
        case quiet, balanced, performance, turbo
        var id: String { rawValue }

        var title: String {
            switch self {
            case .quiet: return "Тихо"
            case .balanced: return "Стандарт"
            case .performance: return "Производительность"
            case .turbo: return "Турбо"
            }
        }

        /// Кривая: (температура °C, доля оборотов 0…1)
        var points: [(Double, Double)] {
            switch self {
            case .quiet:
                return [(40, 0.20), (50, 0.24), (65, 0.45), (78, 0.75), (88, 1.0)]
            case .balanced:
                return [(40, 0.25), (48, 0.30), (62, 0.55), (75, 0.85), (85, 1.0)]
            case .performance:
                return [(40, 0.32), (45, 0.36), (58, 0.65), (70, 0.92), (80, 1.0)]
            case .turbo:
                return [(35, 0.45), (40, 0.50), (50, 0.75), (60, 1.0)]
            }
        }

        func fraction(_ temp: Double) -> Double {
            let pts = points
            guard let first = pts.first else { return 0 }
            if temp <= first.0 { return first.1 }
            for (a, b) in zip(pts, pts.dropFirst()) where temp < b.0 {
                let t = (temp - a.0) / (b.0 - a.0)
                return a.1 + t * (b.1 - a.1)
            }
            return 1.0
        }
    }

    struct FanUI: Identifiable {
        let id: Int
        let name: String
        let min: Double
        let max: Double
        var current: Double = 0
        var target: Double = 0
    }

    struct Sample {
        let t: Double
        let temp: Double
        let frac: Double
    }

    // MARK: Published state

    @Published var cpuTemp: Double = 0
    @Published var gpuTemp: Double = 0
    @Published var fans: [FanUI] = []
    @Published var mode: Mode = .system {
        didSet {
            guard oldValue != mode else { return }
            adjustPollingInterval()
        }
    }
    @Published var profile: Profile = .performance
    @Published var loadBoostEnabled: Bool = true
    @Published var helperInstalled: Bool = false
    @Published var helperBusy: Bool = false
    @Published var helperMessage: String?
    @Published var warning: String?
    @Published var history: [Sample] = []
    @Published var cpuLoad: Double = 0
    @Published var launchAtLogin: Bool = false
    @Published var manualValues: [Int: Double] = [:]
    @Published var smcAvailable: Bool = true

    // MARK: Private

    private let smc = SMC.shared
    private let control = PrivilegedControl()
    private let loadCalc = CPULoad()
    private var timer: Timer?
    private var lastFrac: Double = 0
    private var lastWritten: [Double] = []
    private var prevTemp: Double?
    private var highLoadTicks = 0
    private var errorCount = 0
    private var suspendedMode: Mode?
    private var started = false
    /// Активный режим (авто/ручной) — частый опрос; системный — редкий
    private let tickInterval: Double = 2.0
    private let idleTickInterval: Double = 5.0
    private var currentInterval: Double = 2.0
    private var tickCount = 0
    private var lastHelperCheck = Date.distantPast
    private let helperCheckInterval: TimeInterval = 30
    private var lastCpuTemp: Double = -1
    private var lastGpuTemp: Double = -1
    private var lastCpuLoad: Double = -1
    /// Панель/окно открыты: тогда GPU читаем каждый тик, а не каждый третий
    var panelVisible: Bool = false

    private enum Keys {
        static let mode = "mode"
        static let profile = "profile"
        static let loadBoost = "loadBoost"
    }

    // MARK: Запуск

    func start() {
        guard !started else { return }
        started = true

        do {
            try smc.open()
            smcAvailable = true
        } catch {
            smcAvailable = false
            warning = "Нет доступа к SMC: \(error)"
        }

        loadFans()
        loadSettings()
        launchAtLogin = Self.isLaunchAtLoginEnabled()

        checkHelper()
        if helperInstalled && mode != .system && !fans.isEmpty {
            // Возвращаем сохранённый режим (обычно .auto)
            engageMode(mode)
        } else if mode != .system {
            mode = .system
        }

        startTimer()
        observeSleep()
    }

    private func loadFans() {
        let count = (try? smc.fanCount()) ?? 0
        var arr: [FanUI] = []
        for i in 0..<count {
            if let info = try? smc.fanInfo(i) {
                let name = info.name.isEmpty ? "Вентилятор \(i + 1)" : info.name
                arr.append(FanUI(id: i, name: name, min: info.min, max: info.max))
            }
        }
        fans = arr
        lastWritten = Array(repeating: -1, count: max(count, 1))
    }

    private func loadSettings() {
        let d = UserDefaults.standard
        if let m = Mode(rawValue: d.string(forKey: Keys.mode) ?? "") { mode = m }
        if let p = Profile(rawValue: d.string(forKey: Keys.profile) ?? "") { profile = p }
        if d.object(forKey: Keys.loadBoost) != nil {
            loadBoostEnabled = d.bool(forKey: Keys.loadBoost)
        }
    }

    private func saveSettings() {
        let d = UserDefaults.standard
        d.set(mode.rawValue, forKey: Keys.mode)
        d.set(profile.rawValue, forKey: Keys.profile)
        d.set(loadBoostEnabled, forKey: Keys.loadBoost)
    }

    private func startTimer() {
        timer?.invalidate()
        currentInterval = mode == .system ? idleTickInterval : tickInterval
        let t = Timer.scheduledTimer(withTimeInterval: currentInterval, repeats: true) { [weak self] _ in
            self?.tick()
        }
        // допуск по времени экономит пробуждения CPU, точность 2 с не критична
        t.tolerance = currentInterval * 0.1
        timer = t
    }

    /// Сменить интервал опроса, если режим это требует (системный — редко)
    private func adjustPollingInterval() {
        let wanted = mode == .system ? idleTickInterval : tickInterval
        guard started, wanted != currentInterval else { return }
        startTimer()
    }

    // MARK: Тик опроса и регулирования

    func tick() {
        tickCount += 1

        // температуры (CPU — каждый тик, GPU — каждый третий: нужен только в панели)
        var cpu: [Double] = []
        for k in Thermals.cpuKeys {
            if let v = smc.readValueOpt(k), v > 5 && v < 120 { cpu.append(v) }
        }
        let cpuMax = cpu.max() ?? 0
        if abs(cpuMax - lastCpuTemp) >= 0.1 {
            lastCpuTemp = cpuMax
            cpuTemp = cpuMax
        }

        if panelVisible || tickCount % 3 == 0 {
            var gpu: [Double] = []
            for k in Thermals.gpuKeys {
                if let v = smc.readValueOpt(k), v > 5 && v < 120 { gpu.append(v) }
            }
            let gpuMax = gpu.max() ?? 0
            if abs(gpuMax - lastGpuTemp) >= 0.1 {
                lastGpuTemp = gpuMax
                gpuTemp = gpuMax
            }
        }

        // вентиляторы: читаем каждый тик (быстро), публикуем только при изменении
        var updated = fans
        var changed = false
        for i in updated.indices {
            let cur = smc.fanCurrent(updated[i].id)
            let tgt = smc.fanTarget(updated[i].id)
            if Int(cur) != Int(updated[i].current) || Int(tgt) != Int(updated[i].target) {
                updated[i].current = cur
                updated[i].target = tgt
                changed = true
            }
        }
        if changed { fans = updated }

        let load = loadCalc.current()
        if abs(load - lastCpuLoad) > 0.01 {
            lastCpuLoad = load
            cpuLoad = load
        }

        if mode == .auto {
            regulate()
        }

        appendHistory()

        // Живость хелпера проверяем не чаще раза в helperCheckInterval:
        // каждый PING — это connect/disconnect по unix-сокету.
        // При активном управлении недоступность и так поймаем по ошибкам записи.
        if mode == .system {
            checkHelper()
        } else if !PrivilegedControl.demoMode,
                  Date().timeIntervalSince(lastHelperCheck) >= helperCheckInterval {
            lastHelperCheck = Date()
            if !control.installed { handleControlError() }
        }
    }

    private func appendHistory() {
        guard cpuTemp > 0 else { return }
        let frac = mode == .auto ? lastFrac : (fans.first.map { ($0.target - $0.min) / max(1, $0.max - $0.min) } ?? 0)
        let now = Date().timeIntervalSince1970
        history.append(Sample(t: now, temp: cpuTemp, frac: min(1, max(0, frac))))
        if history.count > 120 {
            history.removeFirst(history.count - 120)
        }
    }

    // MARK: Авто-регулятор

    private func regulate() {
        guard !fans.isEmpty else { return }
        let t = cpuTemp

        // скорость роста температуры (°C/сек)
        let rate = prevTemp.map { (t - $0) / tickInterval } ?? 0
        prevTemp = t

        var frac = profile.fraction(t)

        // предиктивный буст: температура быстро растёт — раскрутить заранее
        if rate > 0.25 { frac += 0.12 }

        // буст по нагрузке CPU (сборка проекта, генерация файлов и т.п.)
        if loadBoostEnabled && cpuLoad > 0.6 {
            highLoadTicks += 1
            if highLoadTicks >= 2 { frac += 0.10 }
        } else {
            highLoadTicks = 0
        }

        // защита: жара — на максимум
        if t >= 92 { frac = 1.0 }

        frac = min(frac, 1.0)
        // медленный спуск (быстрый подъём, медленное снижение — без "пилы")
        frac = max(frac, lastFrac - 0.06)
        lastFrac = frac

        for f in fans {
            let rpm = ((f.min + frac * (f.max - f.min)) / 50).rounded(.down) * 50
            let idx = f.id
            if abs(rpm - (lastWritten.indices.contains(idx) ? lastWritten[idx] : -1)) >= 30 {
                do {
                    try control.setTarget(fan: idx, rpm: rpm)
                    if lastWritten.indices.contains(idx) { lastWritten[idx] = rpm }
                    errorCount = 0
                } catch {
                    handleControlError()
                    return
                }
            }
        }
    }

    private func handleControlError() {
        errorCount += 1
        if errorCount >= 3 {
            errorCount = 0
            warning = "Хелпер недоступен — управление возвращено системе"
            restoreSystemQuiet()
            mode = .system
            checkHelper(force: true)
        }
    }

    // MARK: Режимы

    func setMode(_ newMode: Mode) {
        switch newMode {
        case .system:
            restoreSystemQuiet()
            mode = .system
            warning = nil
        case .auto, .manual:
            guard helperInstalled else {
                warning = "Сначала установите помощник"
                return
            }
            engageMode(newMode)
        }
        saveSettings()
    }

    /// Выбрать профиль и включить наш авто-режим
    func setProfile(_ newProfile: Profile) {
        profile = newProfile
        if mode != .auto {
            setMode(.auto)
        } else {
            saveSettings()
        }
        // сбрасываем плавность, чтобы новая кривая применилась сразу
        lastFrac = 0
    }

    /// Ручные обороты для одного вентилятора (из меню)
    func setFanManualRPM(_ fan: Int, rpm: Double) {
        if mode != .manual {
            setMode(.manual)
        }
        applyManual(fan: fan, rpm: rpm)
    }

    /// Вернуть один вентилятор под системное управление (из меню)
    func setFanSystem(_ fan: Int) {
        do {
            try control.setMode(fan: fan, manual: false)
            errorCount = 0
        } catch {
            handleControlError()
        }
        if mode == .manual, fans.allSatisfy({ fanModeByte($0.id) == 0 }) {
            mode = .system
            saveSettings()
        }
    }

    /// Оба вентилятора на максимум (из меню)
    func setAllMax() {
        if mode != .manual {
            setMode(.manual)
        }
        for f in fans {
            applyManual(fan: f.id, rpm: f.max)
        }
    }

    /// Байт режима вентилятора из SMC (0 = системный авто, 1 = ручной)
    func fanModeByte(_ fan: Int) -> UInt8 {
        smc.readRawByte("F\(fan)Md") ?? 0
    }

    func toggleLaunchAtLogin() {
        setLaunchAtLogin(!launchAtLogin)
    }

    func toggleLoadBoost() {
        loadBoostEnabled.toggle()
        saveSettings()
    }

    private func engageMode(_ newMode: Mode) {
        for f in fans {
            _ = try? control.setMode(fan: f.id, manual: true)
        }
        lastWritten = Array(repeating: -1, count: max(fans.count, 1))
        lastFrac = 0
        errorCount = 0
        prevTemp = nil
        highLoadTicks = 0

        if newMode == .manual {
            for f in fans {
                let v = manualValues[f.id] ?? f.target
                manualValues[f.id] = v
                applyManual(fan: f.id, rpm: v)
            }
        }
        mode = newMode
    }

    func applyManual(fan: Int, rpm: Double) {
        manualValues[fan] = rpm
        guard mode == .manual else { return }
        do {
            try control.setMode(fan: fan, manual: true)
            try control.setTarget(fan: fan, rpm: rpm)
            errorCount = 0
        } catch {
            handleControlError()
        }
    }

    private func restoreSystemQuiet() {
        if PrivilegedControl.demoMode { return }
        try? control.reset()
        lastWritten = Array(repeating: -1, count: max(fans.count, 1))
    }

    /// Перед выходом из приложения: вернуть вентиляторы системе
    func shutdownRestore() {
        guard mode != .system else { return }
        restoreSystemQuiet()
    }

    // MARK: Хелпер

    func checkHelper(force: Bool = false) {
        // PING — это connect/disconnect по unix-сокету; чаще раза в 30 с не нужно
        guard force || Date().timeIntervalSince(lastHelperCheck) >= helperCheckInterval else { return }
        lastHelperCheck = Date()
        helperInstalled = control.installed
    }

    func installHelper() {
        guard PrivilegedControl.helperSourceURL() != nil else {
            helperMessage = "Не найден файл помощника (mistrald)"
            return
        }
        helperBusy = true
        helperMessage = nil
        PrivilegedControl.install { [weak self] result in
            guard let self else { return }
            self.helperBusy = false
            switch result {
            case .success:
                // даём launchd секунду поднять демон
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                    guard let self else { return }
                    self.checkHelper(force: true)
                    self.helperMessage = self.helperInstalled
                        ? "Помощник установлен — можно управлять вентиляторами"
                        : "Помощник установлен, но не отвечает — перезапустите Mistral"
                }
            case .failure(let msg):
                self.helperMessage = "Установка отменена: \(msg)"
            }
        }
    }

    func uninstallHelper() {
        helperBusy = true
        helperMessage = nil
        restoreSystemQuiet()
        mode = .system
        saveSettings()
        PrivilegedControl.uninstall { [weak self] result in
            guard let self else { return }
            self.helperBusy = false
            self.checkHelper(force: true)
            switch result {
            case .success:
                self.helperMessage = "Помощник удалён"
            case .failure(let msg):
                self.helperMessage = "Удаление отменено: \(msg)"
            }
        }
    }

    // MARK: Автозапуск

    static func isLaunchAtLoginEnabled() -> Bool {
        if #available(macOS 13.0, *) {
            return SMAppService.mainApp.status == .enabled
        }
        return false
    }

    func setLaunchAtLogin(_ on: Bool) {
        if #available(macOS 13.0, *) {
            do {
                if on { try SMAppService.mainApp.register() }
                else { try SMAppService.mainApp.unregister() }
                launchAtLogin = on
                return
            } catch {
                warning = "Не удалось изменить автозапуск: \(error.localizedDescription)"
            }
        }
        // запасной вариант — login item через System Events
        let appPath = Bundle.main.bundleURL.path
        let cmd = on
            ? "tell application \"System Events\" to make login item at end with properties {path:\"\(appPath)\", hidden:false}"
            : "tell application \"System Events\" to delete login items whose path is \"\(appPath)\""
        DispatchQueue.global().async { [weak self] in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            p.arguments = ["-e", cmd]
            p.standardOutput = Pipe()
            p.standardError = Pipe()
            let ok = (try? p.run()) != nil
            if ok { p.waitUntilExit() }
            let success = ok && p.terminationStatus == 0
            DispatchQueue.main.async {
                self?.launchAtLogin = on && success
            }
        }
    }

    // MARK: Сон и пробуждение

    private func observeSleep() {
        let nc = NSWorkspace.shared.notificationCenter
        nc.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self, self.mode != .system else { return }
            self.suspendedMode = self.mode
            self.restoreSystemQuiet()
            self.mode = .system
        }
        nc.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self, let m = self.suspendedMode else { return }
            self.suspendedMode = nil
            if self.helperInstalled {
                self.engageMode(m)
            }
        }
    }
}
