//
//  Probe — диагностика SMC: вентиляторы, температуры, тест записи оборотов.
//

import Foundation
import SMCCore

let smc = SMC.shared
let args = CommandLine.arguments

// Ключи температур для Apple M1 (подходит и для M1 Pro/M1 Max) — smctemp
let cpuKeysM1 = ["Tp01", "Tp05", "Tp0D", "Tp0H", "Tp0L", "Tp0P", "Tp0X", "Tp0b",  // P-ядра
                 "Tp09", "Tp0T"]                                                    // E-ядра
let gpuKeysM1 = ["Tg05", "Tg0D", "Tg0L", "Tg0P", "Tg0T", "Tg0U", "Tg0X", "Tg0b", "Tg0d",
                 "Tg0f", "Tg0g", "Tg0j", "Tg0v"]

func fmt(_ v: Double?) -> String {
    guard let v else { return "  n/a " }
    return String(format: "%6.1f", v)
}

func dumpFans() throws {
    let count = try smc.fanCount()
    print("Вентиляторов: \(count)")
    let all = try smc.allKeys()
    for i in 0..<count {
        let info = try smc.fanInfo(i)
        print("--- Вентилятор \(i): \(info.name)  min=\(Int(info.min))  max=\(Int(info.max))")
        let now = smc.fanCurrent(i)
        let tgt = smc.fanTarget(i)
        print("    F\(i)Ac=\(Int(now)) об/мин   F\(i)Tg=\(Int(tgt)) об/мин")
        // Все ключи этого вентилятора с типами
        for (code, size, type) in all where code.hasPrefix("F\(i)") {
            let v = smc.readValueOpt(code)
            let vs = v.map { String(format: "%.2f", $0) } ?? "—"
            print("    \(code)  [\(type) ×\(size)] = \(vs)")
        }
    }
}

func dumpTemps() {
    print("--- CPU ключи ---")
    var values: [Double] = []
    for k in cpuKeysM1 {
        let v = smc.readValueOpt(k)
        let info = try? smc.keyInfo(k)
        print("    \(k)  [\(info?.type ?? "?")] = \(fmt(v))°C")
        if let v, v > 5 && v < 120 { values.append(v) }
    }
    if !values.isEmpty {
        print("    CPU avg=\(String(format: "%.1f", values.reduce(0,+) / Double(values.count)))°C  " +
              "max=\(String(format: "%.1f", values.max()!))°C")
    }
    print("--- GPU ключи ---")
    for k in gpuKeysM1 {
        let v = smc.readValueOpt(k)
        let info = try? smc.keyInfo(k)
        print("    \(k)  [\(info?.type ?? "?")] = \(fmt(v))°C")
    }
}

func dumpAllTempsAndFans() throws {
    let all = try smc.allKeys()
    print("Всего ключей SMC: \(all.count)")
    print("--- Ключи T* ---")
    for (code, size, type) in all where code.hasPrefix("T") {
        let v = smc.readValueOpt(code)
        let vs = v.map { String(format: "%.2f", $0) } ?? "—"
        print("    \(code)  [\(type) ×\(size)] = \(vs)")
    }
}

func testWrite() throws {
    let count = try smc.fanCount()
    guard count > 0 else { print("Нет вентиляторов"); return }
    let id = 0
    let info = try smc.fanInfo(id)
    let beforeTarget = smc.fanTarget(id)
    let beforeCurrent = smc.fanCurrent(id)
    print("До записи: Ac=\(Int(beforeCurrent))  Tg=\(Int(beforeTarget))  " +
          "min=\(Int(info.min))  max=\(Int(info.max))")

    let ftst = smc.readRawByte("Ftst")
    print("Ftst = \(ftst.map { String($0) } ?? "—")")
    let modeKey = smc.fanModeKey(id)
    let modeBefore = smc.readRawByte(modeKey ?? "")
    print("Ключ режима: \(modeKey ?? "нет")  значение: \(modeBefore.map { String($0) } ?? "—")")

    print("Включаю ручной режим и пишу F\(id)Tg = \(Int(beforeCurrent + 500)) ...")
    do {
        try smc.setFanManual(id)
        try smc.setFanTarget(id, rpm: beforeCurrent + 500, floor: info.min, ceiling: info.max)
        print("Запись выполнена")
    } catch let e as SMCError {
        print("ОШИБКА ЗАПИСИ: \(e)")
        return
    }

    for step in 1...6 {
        Thread.sleep(forTimeInterval: 1)
        let ac = smc.fanCurrent(id)
        let tg = smc.fanTarget(id)
        print("  t+\(step)s  Ac=\(Int(ac))  Tg=\(Int(tg))")
    }

    print("--- Возвращаю системное автоуправление (Ftst=0, F\(id)Md=0) ---")
    smc.restoreSystemControl(fans: count)
    for step in 1...8 {
        Thread.sleep(forTimeInterval: 1)
        let ac = smc.fanCurrent(id)
        let tg = smc.fanTarget(id)
        let md = smc.readRawByte(modeKey ?? "")
        print("  t+\(step)s  Ac=\(Int(ac))  Tg=\(Int(tg))  Md=\(md.map { String($0) } ?? "—")")
    }
    print("Если Tg снова 'плавает' относительно Ac — автоуправление вернулось.")
}

func watch(seconds: Int) {
    let count = (try? smc.fanCount()) ?? 0
    let cpu: [String] = cpuKeysM1
    for t in 0..<seconds {
        var vals: [Double] = []
        for k in cpu { if let v = smc.readValueOpt(k), v > 5 && v < 120 { vals.append(v) } }
        let maxT = vals.max() ?? 0
        var fanStr = "—"
        if count > 0 {
            fanStr = "Ac=\(Int(smc.fanCurrent(0))) Tg=\(Int(smc.fanTarget(0)))"
        }
        print("[\(t)s] CPU max=\(String(format: "%.1f", maxT))°C  Fan0 \(fanStr)")
        Thread.sleep(forTimeInterval: 1)
    }
}

do {
    try smc.open()
    if args.contains("--all") {
        try dumpAllTempsAndFans()
    } else if args.contains("--testwrite") {
        try dumpFans()
        try testWrite()
    } else if let idx = args.firstIndex(of: "--watch"), let n = Int(args[args.index(after: idx)]) {
        watch(seconds: n)
    } else {
        try dumpFans()
        dumpTemps()
    }
    smc.close()
} catch {
    print("ОШИБКА: \(error)")
    exit(1)
}
