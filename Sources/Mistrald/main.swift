//
//  mistrald — привилегированный хелпер Mistral.
//
//  Запускается launchd'ом как root-демон (/Library/LaunchDaemons/app.mistral.helper.plist).
//  Слушает UNIX-сокет /var/run/mistralctl.sock и выполняет записи в SMC
//  (установка оборотов и режима вентиляторов). Подключения разрешены только
//  пользователю, который установил хелпер (uid из /usr/local/mistral/owner.uid).
//
//  Протокол (строка + \n):
//    PING            -> OK mistrald <version> <helper-uid>
//    BEAT            -> OK                    (хартбит живого клиента)
//    SETT <fan> <rpm> -> OK | ERR <text>      (записать F<fan>Tg)
//    MODE <fan> <0|1> -> OK | ERR <text>      (0 — авто, 1 — ручной)
//    RESET            -> OK | ERR <text>      (вернуть все вентиляторы системе)
//
//  Watchdog: клиент (приложение) шлёт BEAT раз в тик (2 с). Если ручной режим
//  включён, а BEAT не приходит дольше 20 с — приложение умерло (краш, kill -9),
//  и мы сами возвращаем вентиляторы системе: иначе они остаются замороженными
//  на последних оборотах, и система не может ими управлять.
//
//  Аргумент запуска: путь к сокету (по умолчанию /var/run/mistralctl.sock).
//

import Foundation
import Darwin
import SMCCore

let version = "1.1"
let socketPath = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : "/var/run/mistralctl.sock"
let ownerFile = "/usr/local/mistral/owner.uid"

signal(SIGPIPE, SIG_IGN)

func err(_ msg: String) -> Never {
    FileHandle.standardError.write(Data(("mistrald: " + msg + "\n").utf8))
    exit(1)
}

func logLine(_ msg: String) {
    FileHandle.standardError.write(Data(("mistrald: " + msg + "\n").utf8))
}

func allowedUid() -> uid_t? {
    guard let raw = try? String(contentsOfFile: ownerFile, encoding: .utf8) else {
        return nil
    }
    guard let v = uid_t(raw.trimmingCharacters(in: .whitespacesAndNewlines)) else {
        return nil
    }
    return v
}

let smc = SMC.shared

// MARK: - Watchdog: клиент умер — возвращаем вентиляторы системе

// CLOCK_MONOTONIC не тикает во время сна: заснувший Mac не считается
// «молчащим клиентом», и после пробуждения не будет ложного сброса.
var watchdogLock = NSLock()
var lastBeatNS: UInt64 = 0
var clientEngaged = false

func monotonicNS() -> UInt64 { clock_gettime_nsec_np(CLOCK_MONOTONIC) }

func markBeat() {
    watchdogLock.lock()
    lastBeatNS = monotonicNS()
    watchdogLock.unlock()
}

func markEngaged() {
    watchdogLock.lock()
    clientEngaged = true
    lastBeatNS = monotonicNS()
    watchdogLock.unlock()
}

func markReleased() {
    watchdogLock.lock()
    clientEngaged = false
    watchdogLock.unlock()
}

let beatTimeoutNS: UInt64 = 20_000_000_000  // 20 c; приложение бьётся раз в 2 c

func anyFanManual() -> Bool {
    let count = (try? smc.fanCount()) ?? 0
    for i in 0..<count {
        if let key = smc.fanModeKey(i), (smc.readRawByte(key) ?? 0) != 0 { return true }
    }
    return false
}

func restoreSystemControl(_ reason: String) {
    let count = (try? smc.fanCount()) ?? 0
    guard count > 0 else { return }
    smc.restoreSystemControl(fans: count)
    logLine(reason + " — вентиляторы возвращены системе")
}

/// Ссылку на таймер надо держать глобально: DispatchSourceTimer, оставленный
/// локальной переменной, освобождается при выходе из функции и не тикает
/// (ловили на живой железке — watchdog молчал).
var watchdogTimer: DispatchSourceTimer?

func startWatchdog() {
    let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
    timer.schedule(deadline: .now() + 5, repeating: 5)
    timer.setEventHandler {
        watchdogLock.lock()
        let stale = clientEngaged && monotonicNS() - lastBeatNS > beatTimeoutNS
        watchdogLock.unlock()
        guard stale, anyFanManual() else { return }
        markReleased()
        restoreSystemControl("клиент не отвечает дольше 20 с")
    }
    timer.resume()
    watchdogTimer = timer
}

// MARK: - Выполнение команд

func clampRpm(_ fan: Int, _ rpm: Double) throws -> (Double, Double, Double) {
    let info = try smc.fanInfo(fan)
    let v = Swift.max(Swift.min(rpm, info.max), info.min)
    return (v, info.min, info.max)
}

func handle(_ line: String) -> String {
    let parts = line.split(separator: " ").map(String.init)
    guard let cmd = parts.first else { return "ERR empty" }

    switch cmd {
    case "PING":
        return "OK mistrald \(version) \(getuid())"

    case "BEAT":
        markBeat()
        return "OK"

    case "SETT":
        guard parts.count == 3, let fan = Int(parts[1]), let rpm = Double(parts[2]),
              fan >= 0, fan < 10 else { return "ERR bad args" }
        do {
            let (v, lo, hi) = try clampRpm(fan, rpm)
            try smc.writeValue("F\(fan)Tg", v)
            return "OK \(Int(v)) \(Int(lo)) \(Int(hi))"
        } catch {
            return "ERR \(error)"
        }

    case "MODE":
        guard parts.count == 3, let fan = Int(parts[1]), let mode = Int(parts[2]),
              fan >= 0, fan < 10, mode == 0 || mode == 1 else { return "ERR bad args" }
        do {
            if mode == 1 {
                try smc.setFanManual(fan)
                markEngaged()
            } else {
                try smc.setFanAuto(fan)
                // Ручных вентиляторов не осталось — клиент отпустил управление
                if !anyFanManual() { markReleased() }
            }
            return "OK"
        } catch {
            return "ERR \(error)"
        }

    case "RESET":
        do {
            let count = try smc.fanCount()
            smc.restoreSystemControl(fans: count)
            markReleased()
            return "OK"
        } catch {
            return "ERR \(error)"
        }

    default:
        return "ERR unknown"
    }
}

// MARK: - UNIX-сокет сервер

func unixListen(_ path: String) -> Int32 {
    unlink(path)

    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { err("socket(): errno=\(errno)") }

    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let bytes = Array(path.utf8CString)
    guard bytes.count <= MemoryLayout<sockaddr_un>.size - MemoryLayout<sa_family_t>.size else {
        err("path too long")
    }
    withUnsafeMutableBytes(of: &addr.sun_path) { dst in
        for (i, b) in bytes.enumerated() { dst[i] = UInt8(b) }
    }

    let bindResult = withUnsafePointer(to: &addr) { ptr in
        ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
            bind(fd, sa, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }
    guard bindResult == 0 else { err("bind(\(path)): errno=\(errno)") }
    chmod(path, 0o666)
    guard listen(fd, 8) == 0 else { err("listen(): errno=\(errno)") }
    return fd
}

func serve(_ listenFd: Int32) -> Never {
    let expectUid = allowedUid()

    while true {
        let fd = accept(listenFd, nil, nil)
        guard fd >= 0 else { continue }

        var uid: uid_t = 0
        var gid: gid_t = 0
        if getpeereid(fd, &uid, &gid) == 0, let expect = expectUid, uid != expect {
            FileHandle.standardError.write(Data(("mistrald: rejected uid \(uid)\n").utf8))
            close(fd)
            continue
        }

        var buf = [UInt8](repeating: 0, count: 256)
        let n = read(fd, &buf, buf.count - 1)
        if n > 0 {
            var line = String(decoding: buf[0..<n], as: UTF8.self)
            while line.last == "\n" || line.last == "\r" { line.removeLast() }
            let response = handle(line) + "\n"
            _ = response.withCString { ptr -> Int in
                send(fd, ptr, strlen(ptr), 0)
            }
        }
        close(fd)
    }
}

// MARK: - Main

do {
    try smc.open()
} catch {
    err("smc open failed: \(error)")
}
// После (ре)старта демона ни один клиент управление ещё не запросил: если
// вентиляторы остались в ручном режиме от прошлого запуска (краш приложения
// + рестарт демона), возвращаем их системе.
if anyFanManual() {
    restoreSystemControl("старт демона при включённом ручном режиме")
}
startWatchdog()
let fd = unixListen(socketPath)
logLine("\(version): listening on \(socketPath) (uid=\(getuid()))")
serve(fd)
