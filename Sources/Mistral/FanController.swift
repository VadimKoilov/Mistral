//
//  FanController.swift — центральный контроллер: опрос датчиков, авто-регулятор,
//  ручное управление, состояния хелпера.
//

import Foundation
import AppKit
import ServiceManagement
import SMCCore
import os

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
        // mach_host_self() выдаёт send-right: не dealloc'нуть — утечка порта каждый тик
        let host = mach_host_self()
        defer { mach_port_deallocate(mach_task_self_, host) }
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(host, HOST_CPU_LOAD_INFO, $0, &count)
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
    /// Время последней записи цели по каждому вентилятору (для retry потерянных записей)
    private var lastWriteAt: [Int: TimeInterval] = [:]
    private var lastDropLog = Date.distantPast
    /// Режим, который нужно включить, но сейчас не получилось (хелпер не ответил).
    /// Тик повторяет попытку, пока не включится — см. retryPending().
    private var pendingMode: Mode?
    /// Вентиляторы, которые мы перевели в ручной режим и за которые отвечаем.
    /// Нужен для самолечения (SMC иногда сбрасывает F#Md) и чтобы не трогать
    /// вентиляторы, которые пользователь вернул системе точечно.
    private var engagedFans: Set<Int> = []
    private var lastControlErrorLog = Date.distantPast
    private var lastRetryLog = Date.distantPast
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
            let desired = mode
            if engageMode(desired) {
                setPending(nil)
                warning = nil
            } else {
                setPending(desired)
                mode = .system
                warning = "Хелпер не ответил — повторю включение автоматически"
            }
            logEvent("старт: сохранённый режим \(desired.rawValue), хелпер доступен")
        } else if mode != .system {
            // Хелпера сейчас нет (или вентиляторы не прочитались): не теряем
            // сохранённый режим, а откладываем — включится, как только
            // помощник ответит. В дефолтах режим не трогаем.
            let desired = mode
            setPending(desired)
            mode = .system
            warning = "Помощник недоступен — «\(desired.title)» включится автоматически"
            logEvent("старт: хелпер недоступен, режим \(desired.rawValue) отложен")
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

    private func saveProfile() {
        UserDefaults.standard.set(profile.rawValue, forKey: Keys.profile)
    }

    private func startTimer() {
        timer?.invalidate()
        currentInterval = (mode == .system && pendingMode == nil) ? idleTickInterval : tickInterval
        let t = Timer.scheduledTimer(withTimeInterval: currentInterval, repeats: true) { [weak self] _ in
            self?.tick()
        }
        // допуск по времени экономит пробуждения CPU, точность 2 с не критична
        t.tolerance = currentInterval * 0.1
        timer = t
    }

    /// Сменить интервал опроса, если режим это требует (системный — редко)
    private func adjustPollingInterval() {
        let wanted = (mode == .system && pendingMode == nil) ? idleTickInterval : tickInterval
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

        // Отложенный режим: хелпер не отвечал, когда его включали —
        // пробуем снова, как только он появится
        if let pending = pendingMode, mode == .system {
            retryPending(pending)
        }

        if mode == .auto {
            regulate()
        }

        // Самолечение: SMC может сбросить ручной режим (сон, термическое событие,
        // рестарт демона, собственные записи системного агента). Пока F#Md = 0,
        // наши записи целей молча отбрасываются — снаружи это выглядит как
        // «профиль включён, а обороты не меняются». Проверяем раз в 5 тиков.
        if mode != .system, tickCount % 5 == 0 {
            let dropped = fans.map(\.id).filter { engagedFans.contains($0) && fanModeByte($0) == 0 }
            if !dropped.isEmpty {
                logEvent("SMC сбросил ручной режим вентиляторов \(dropped) — восстанавливаю")
                for i in dropped {
                    do { try control.setMode(fan: i, manual: true) }
                    catch { handleControlError(error, context: "REMD f\(i)") }
                }
            }
            // Ручной режим: убеждаемся, что назначенные обороты реально применились
            // (Tg мог быть потерян при конфликте с циклом SMC)
            if mode == .manual {
                let now = Date().timeIntervalSince1970
                for f in fans where engagedFans.contains(f.id) {
                    guard let want = manualValues[f.id], lastWritten[f.id] == want,
                          now - (lastWriteAt[f.id] ?? 0) > 3 else { continue }
                    if abs(f.target - want) >= 50 {
                        logEvent("ручная цель f\(f.id) не применилась (Tg=\(Int(f.target)), ждали \(Int(want))) — повторяю")
                        applyManual(fan: f.id, rpm: want)
                    }
                }
            }
        }

        appendHistory()

        // Хартбит для хелпера: он возвращает вентиляторы системе, если приложение
        // умерло и 20 с тишины (см. watchdog в mistrald). Ошибки не считаем —
        // живость хелпера здесь оценивают ошибки записи в regulate().
        if mode != .system, !PrivilegedControl.demoMode {
            control.heartbeat()
        }

        // Живость хелпера проверяем не чаще раза в helperCheckInterval:
        // каждый PING — это connect/disconnect по unix-сокету.
        // При активном управлении недоступность и так поймаем по ошибкам записи.
        if mode == .system {
            checkHelper()
        } else if !PrivilegedControl.demoMode,
                  Date().timeIntervalSince(lastHelperCheck) >= helperCheckInterval {
            lastHelperCheck = Date()
            if !control.installed { handleControlError(nil, context: "PING") }
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

        writeTargets { f in
            let rpm = ((f.min + frac * (f.max - f.min)) / 50).rounded(.down) * 50
            return rpm
        }
    }

    /// Записать цели вентиляторам. Две причины для записи:
    /// 1) кривая ушла от последней записанной цели на >= 30 об/мин;
    /// 2) SMC молча потерял предыдущую запись: он коммитит изменения пакетно
    ///    своим внутренним циклом, и SETT, попавший в окно до коммита ручного
    ///    режима, отбрасывается без ошибки. Поэтому сверяем Tg обратно:
    ///    не совпадает с последней записью — повторяем.
    private func writeTargets(_ rpmFor: (FanUI) -> Double) {
        let now = Date().timeIntervalSince1970
        for f in fans {
            let rpm = rpmFor(f)
            let idx = f.id
            let last = lastWritten.indices.contains(idx) ? lastWritten[idx] : -1
            let readback = f.target
            let dropped = last > 0 && abs(readback - last) >= 50
                && now - (lastWriteAt[idx] ?? 0) > 3
            if abs(rpm - last) >= 30 || dropped {
                do {
                    try control.setTarget(fan: idx, rpm: rpm)
                    if lastWritten.indices.contains(idx) { lastWritten[idx] = rpm }
                    lastWriteAt[idx] = now
                    if dropped, Date().timeIntervalSince(lastDropLog) >= helperCheckInterval {
                        lastDropLog = Date()
                        logEvent("SMC не применил цель f\(idx) (Tg=\(Int(readback)), ждали \(Int(last))) — повторяю запись")
                    }
                    errorCount = 0
                } catch {
                    handleControlError(error, context: "SETT f\(idx)")
                    return
                }
            }
        }
    }

    private func handleControlError(_ error: Error?, context: String) {
        errorCount += 1
        // Неудачи записи при мёртвом хелпере идут каждый тик — логируем
        // первую и далее не чаще раза в helperCheckInterval
        if Date().timeIntervalSince(lastControlErrorLog) >= helperCheckInterval {
            lastControlErrorLog = Date()
            logEvent("ошибка управления [\(context)]: " +
                     (error.map { String(describing: $0) } ?? "нет ответа") +
                     " (подряд: \(errorCount))")
        }
        guard errorCount >= 3 else { return }
        errorCount = 0
        warning = "Хелпер недоступен — управление возвращено системе, восстановлю автоматически"
        if mode != .system {
            logEvent("возврат в системный режим из \(mode.rawValue)")
            setPending(mode)
            mode = .system
        }
        restoreSystemQuiet()
        checkHelper(force: true)
    }

    // MARK: Режимы

    func setMode(_ newMode: Mode) {
        switch newMode {
        case .system:
            restoreSystemQuiet()
            mode = .system
            setPending(nil)
            warning = nil
            saveSettings()
        case .auto, .manual:
            guard helperInstalled else {
                warning = "Сначала установите помощника"
                return
            }
            if engageMode(newMode) {
                setPending(nil)
                warning = nil
            } else {
                // хелпер не ответил: оставляем систему у руля и повторяем в тике;
                // сохранённый режим в дефолтах не трогаем
                setPending(newMode)
                if mode != .system { mode = .system }
                warning = "Хелпер не ответил — повторю включение автоматически"
            }
        }
    }

    /// Выбрать профиль и включить наш авто-режим
    func setProfile(_ newProfile: Profile) {
        profile = newProfile
        if mode != .auto {
            setMode(.auto)
        }
        // профиль сохраняем всегда: он применится и после отложенного включения
        saveProfile()
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
            engagedFans.remove(fan)
            errorCount = 0
        } catch {
            handleControlError(error, context: "MODE f\(fan)=0")
        }
        if mode == .manual, fans.allSatisfy({ fanModeByte($0.id) == 0 }) {
            mode = .system
            engagedFans.removeAll()
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

    /// Байт режима вентилятора из SMC (0 = системный авто, 1 = ручной).
    /// Ключ режима зависит от прошивки (F0Md / F0md) — детектим, а не хардкодим.
    func fanModeByte(_ fan: Int) -> UInt8 {
        guard let key = smc.fanModeKey(fan) else { return 0 }
        return smc.readRawByte(key) ?? 0
    }

    func toggleLaunchAtLogin() {
        setLaunchAtLogin(!launchAtLogin)
    }

    func toggleLoadBoost() {
        loadBoostEnabled.toggle()
        saveSettings()
    }

    /// Включить ручное управление всеми вентиляторами и войти в режим.
    /// Возвращает false, если хелпер не смог переключить вентиляторы:
    /// тогда режим НЕ включаем — иначе приложение будет писать цели,
    /// которые система молча перезапишет своей кривой (та самая «жара,
    /// а вентиляторы стоят»).
    @discardableResult
    private func engageMode(_ newMode: Mode) -> Bool {
        guard !fans.isEmpty else {
            logEvent("engageMode \(newMode.rawValue): список вентиляторов пуст")
            return false
        }
        var engaged: [Int] = []
        for f in fans {
            do {
                try control.setMode(fan: f.id, manual: true)
                engaged.append(f.id)
            } catch {
                logEvent("ручной режим вентилятора \(f.id) не включился: \(error)")
                // откат, чтобы не оставлять часть вентиляторов в ручном режиме
                for i in engaged {
                    try? control.setMode(fan: i, manual: false)
                }
                return false
            }
        }
        engagedFans = Set(engaged)
        lastWritten = Array(repeating: -1, count: max(fans.count, 1))
        lastWriteAt.removeAll()
        lastFrac = 0
        errorCount = 0
        prevTemp = nil
        highLoadTicks = 0

        // Сначала режим: applyManual() пишет цели только в ручном режиме,
        // так что раньше переключения этот цикл молча ничего не записывал
        mode = newMode
        saveSettings()

        if newMode == .manual {
            for f in fans {
                let v = manualValues[f.id] ?? f.target
                applyManual(fan: f.id, rpm: v)
            }
        } else {
            // Авто: пишем цели сразу, не дожидаясь тика (до 2 с). Ручной
            // вентилятор без записанной цели держит старые обороты — снаружи
            // это выглядит как «режим включился, а ничего не происходит».
            // Стартуем с текущих оборотов: без прыжка, кривую профиля
            // подставит ближайший тик. Пишем MODE и SETT одной связкой —
            // SMC коммитит их вместе (проверено на живой машине).
            let now = Date().timeIntervalSince1970
            for f in fans {
                let start = f.target > 0 ? f.target : f.current
                guard start > 0 else { continue }
                do {
                    try control.setTarget(fan: f.id, rpm: start)
                    if lastWritten.indices.contains(f.id) { lastWritten[f.id] = start }
                    lastWriteAt[f.id] = now
                } catch {
                    // не срываем включение режима: цели допишет ближайший тик
                    logEvent("стартовая цель вентилятора \(f.id) не записалась: \(error)")
                }
            }
        }
        return true
    }

    func applyManual(fan: Int, rpm: Double) {
        manualValues[fan] = rpm
        guard mode == .manual else { return }
        do {
            try control.setMode(fan: fan, manual: true)
            try control.setTarget(fan: fan, rpm: rpm)
            engagedFans.insert(fan)
            lastWritten[fan] = rpm
            lastWriteAt[fan] = Date().timeIntervalSince1970
            errorCount = 0
        } catch {
            handleControlError(error, context: "applyManual f\(fan)")
        }
    }

    private func restoreSystemQuiet() {
        if PrivilegedControl.demoMode { return }
        try? control.reset()
        engagedFans.removeAll()
        lastWritten = Array(repeating: -1, count: max(fans.count, 1))
        lastWriteAt.removeAll()
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
        setPending(nil)
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
            // Запоминаем режим как отложенный: после пробуждения включим
            // (а если включить сразу не выйдет — тик будет повторять).
            self.setPending(self.mode)
            self.restoreSystemQuiet()
            self.mode = .system
            self.logEvent("сон: вернул вентиляторы системе, режим \(self.pendingMode?.rawValue ?? "—") отложен")
        }
        nc.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self, let m = self.pendingMode else { return }
            if self.helperInstalled && self.engageMode(m) {
                self.setPending(nil)
                self.warning = nil
            }
            // Не включился — тик повторит попытку через retryPending()
        }
    }

    // MARK: Отложенный режим и журнал

    /// Запомнить/снять отложенный режим. Пока он есть — тик работает чаще.
    private func setPending(_ m: Mode?) {
        guard pendingMode != m else { return }
        pendingMode = m
        if started { adjustPollingInterval() }
    }

    /// Повторить включение отложенного режима. Хелпера ждём без ограничений:
    /// PING к отсутствующему сокету мгновенно отклоняется, попытка ничего не стоит.
    private func retryPending(_ pending: Mode) {
        guard helperInstalled else {
            checkHelper(force: true)
            return
        }
        if engageMode(pending) {
            setPending(nil)
            warning = nil
            logEvent("режим \(pending.rawValue) включён после недоступности хелпера")
        } else if Date().timeIntervalSince(lastRetryLog) >= helperCheckInterval {
            lastRetryLog = Date()
            logEvent("повторное включение \(pending.rawValue) не удалось — продолжаю попытки")
        }
    }

    /// Диагностика в unified log: Console.app или
    /// `log show --last 1h --predicate 'subsystem == "app.mistral.Mistral"'`.
    private func logEvent(_ message: String) {
        Self.eventLog.info("\(message, privacy: .public)")
    }

    private static let eventLog = Logger(subsystem: "app.mistral.Mistral", category: "fan-control")
}
