//
//  SMC.swift
//  SMCCore — доступ к AppleSMC из user space.
//
//  Структура обмена (80 байт) описана в открытом коде Apple PowerManagement
//  (pmconfigd, PrivateLib.c); интерфейс повторяет beltex/SMCKit (MIT) и
//  exelban/stats (MIT). Раскладка чистой Swift-структуры (stride == 80)
//  совпадает с ожиданиями AppleSMC.kext; C-раскладка (84) не подходит.
//

import Foundation
import IOKit

public enum SMCError: Error, CustomStringConvertible {
    case driverNotFound
    case failedToOpen(kernReturn: kern_return_t)
    case keyNotFound(code: String)
    case notPrivileged
    case badValue
    case unknown(code: Int32)

    public var description: String {
        switch self {
        case .driverNotFound: return "AppleSMC driver not found"
        case .failedToOpen(let r): return "failed to open AppleSMC (kIOReturn=\(r))"
        case .keyNotFound(let k): return "key not found: \(k)"
        case .notPrivileged: return "not privileged"
        case .badValue: return "bad value"
        case .unknown(let c): return "unknown error (code=\(c))"
        }
    }
}

// MARK: - Структура обмена с AppleSMC.kext (ровно 80 байт stride)

struct SMCKeyData {
    struct Vers {
        var major: CUnsignedChar = 0
        var minor: CUnsignedChar = 0
        var build: CUnsignedChar = 0
        var reserved: CUnsignedChar = 0
        var release: CUnsignedShort = 0
    }

    struct LimitData {
        var version: UInt16 = 0
        var length: UInt16 = 0
        var cpuPLimit: UInt32 = 0
        var gpuPLimit: UInt32 = 0
        var memPLimit: UInt32 = 0
    }

    struct KeyInfo {
        var dataSize: UInt32 = 0
        var dataType: UInt32 = 0
        var dataAttributes: UInt8 = 0
    }

    var key: UInt32 = 0
    var vers = Vers()
    var pLimitData = LimitData()
    var keyInfo = KeyInfo()
    var padding: UInt16 = 0
    var result: UInt8 = 0
    var status: UInt8 = 0
    /// Команда (readKey / writeKey / readIndex / readKeyInfo)
    var data8: UInt8 = 0
    var data32: UInt32 = 0
    var bytes: SMCBytes = (UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0),
                           UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0),
                           UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0),
                           UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0),
                           UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0),
                           UInt8(0), UInt8(0))
}

public typealias SMCBytes = (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                             UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                             UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                             UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8)

private func tuple(_ arr: [UInt8]) -> SMCBytes {
    let b = arr + Array(repeating: UInt8(0), count: max(0, 32 - arr.count))
    return (b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7], b[8], b[9], b[10], b[11],
            b[12], b[13], b[14], b[15], b[16], b[17], b[18], b[19], b[20], b[21], b[22],
            b[23], b[24], b[25], b[26], b[27], b[28], b[29], b[30], b[31])
}

// MARK: - SMC клиент

public final class SMC {
    public static let shared = SMC()

    private var connection: io_connect_t = 0
    private let lock = NSLock()
    private var infoCache: [String: KeyInfo] = [:]

    private enum Command: UInt8 {
        case readKey = 5
        case writeKey = 6
        case readIndex = 8
        case readKeyInfo = 9
    }

    private let kernelIndex: UInt32 = 2

    // MARK: Соединение

    public func open() throws {
        lock.lock(); defer { lock.unlock() }
        guard connection == 0 else { return }

        let service = IOServiceGetMatchingService(kIOMainPortDefault,
                                                  IOServiceMatching("AppleSMC"))
        guard service != 0 else { throw SMCError.driverNotFound }
        let kr = IOServiceOpen(service, mach_task_self_, 0, &connection)
        IOObjectRelease(service)
        guard kr == kIOReturnSuccess else {
            throw SMCError.failedToOpen(kernReturn: kr)
        }
    }

    public func close() {
        lock.lock(); defer { lock.unlock() }
        guard connection != 0 else { return }
        infoCache.removeAll()
        IOServiceClose(connection)
        connection = 0
    }

    // MARK: Низкий уровень

    private func call(_ input: inout SMCKeyData) throws -> SMCKeyData {
        var output = SMCKeyData()
        let inSize = MemoryLayout<SMCKeyData>.stride
        var outSize = MemoryLayout<SMCKeyData>.stride

        let kr = IOConnectCallStructMethod(connection, kernelIndex,
                                           &input, inSize, &output, &outSize)
        if kr == kIOReturnNotPrivileged { throw SMCError.notPrivileged }
        if kr != kIOReturnSuccess { throw SMCError.unknown(code: Int32(kr)) }
        if output.result == 0x84 { throw SMCError.keyNotFound(code: input.key.fourCCString) }
        if output.result != 0 { throw SMCError.unknown(code: Int32(output.result)) }
        return output
    }

    // MARK: Информация о ключе

    public struct KeyInfo {
        public let size: UInt32
        public let type: String
    }

    public func keyInfo(_ key: String) throws -> KeyInfo {
        lock.lock(); defer { lock.unlock() }
        return try keyInfoLocked(key)
    }

    private func keyInfoLocked(_ key: String) throws -> KeyInfo {
        if let cached = infoCache[key] { return cached }
        var input = SMCKeyData()
        input.key = key.fourCC
        input.data8 = Command.readKeyInfo.rawValue
        let output = try call(&input)
        let info = KeyInfo(size: output.keyInfo.dataSize,
                           type: output.keyInfo.dataType.fourCCString)
        infoCache[key] = info
        return info
    }

    // MARK: Чтение

    public func readBytes(_ key: String) throws -> (bytes: SMCBytes, info: KeyInfo) {
        let info = try keyInfo(key)
        lock.lock(); defer { lock.unlock() }
        var input = SMCKeyData()
        input.key = key.fourCC
        input.keyInfo.dataSize = info.size
        input.data8 = Command.readKey.rawValue
        let output = try call(&input)
        return (output.bytes, info)
    }

    /// Универсальное чтение значения ключа (декодирование по типу)
    public func readValue(_ key: String) throws -> Double? {
        let (bytes, info) = try readBytes(key)
        return SMCCodec.decode(bytes: bytes, size: info.size, type: info.type)
    }

    /// Чтение без throw: ключа нет или ошибка — nil
    public func readValueOpt(_ key: String) -> Double? {
        do { return try readValue(key) } catch { return nil }
    }

    /// Чтение сырых байтов (для флагов типа Ftst / F0Md)
    public func readRawByte(_ key: String) -> UInt8? {
        do {
            let (bytes, info) = try readBytes(key)
            guard info.size >= 1 else { return nil }
            return bytes.0
        } catch { return nil }
    }

    /// Запись одного байта
    public func writeRawByte(_ key: String, _ byte: UInt8) throws {
        lock.lock(); defer { lock.unlock() }
        var input = SMCKeyData()
        input.key = key.fourCC
        input.keyInfo.dataSize = 1
        input.data8 = Command.writeKey.rawValue
        input.bytes = tuple([byte])
        _ = try call(&input)
    }

    // MARK: Запись значения

    public func writeValue(_ key: String, _ value: Double) throws {
        let info = try keyInfo(key)
        guard let bytes = SMCCodec.encode(value: value, size: info.size, type: info.type) else {
            throw SMCError.badValue
        }
        lock.lock(); defer { lock.unlock() }
        var input = SMCKeyData()
        input.key = key.fourCC
        input.keyInfo.dataSize = info.size
        input.data8 = Command.writeKey.rawValue
        input.bytes = bytes
        _ = try call(&input)
    }

    // MARK: Перечисление ключей

    public func keyCount() throws -> Int {
        lock.lock(); defer { lock.unlock() }
        var input = SMCKeyData()
        input.key = "#KEY".fourCC
        input.keyInfo.dataSize = 4
        input.data8 = Command.readKey.rawValue
        let output = try call(&input)
        let b = output.bytes
        let v = UInt32(b.0) << 24 | UInt32(b.1) << 16 | UInt32(b.2) << 8 | UInt32(b.3)
        return Int(v)
    }

    /// Все ключи с их типами (медленно, для диагностики)
    public func allKeys() throws -> [(code: String, size: UInt32, type: String)] {
        let count = try keyCount()
        var result: [(String, UInt32, String)] = []
        result.reserveCapacity(count)
        for i in 0..<count {
            do {
                lock.lock()
                var input = SMCKeyData()
                input.data8 = Command.readIndex.rawValue
                input.data32 = UInt32(i)
                let output = try call(&input)
                let code = output.key.fourCCString
                let info = try keyInfoLocked(code)
                lock.unlock()
                result.append((code, info.size, info.type))
            } catch {
                lock.unlock()
                continue
            }
        }
        return result
    }

    // MARK: Вентиляторы

    public struct FanInfo {
        public let id: Int
        public let name: String
        public let min: Double
        public let max: Double
    }

    public func fanCount() throws -> Int {
        guard let v = readValueOpt("FNum") else { return 0 }
        return Int(v)
    }

    public func fanInfo(_ id: Int) throws -> FanInfo {
        let min = readValueOpt("F\(id)Mn") ?? 0
        let max = readValueOpt("F\(id)Mx") ?? 0
        var name = ""
        if let (bytes, info) = try? readBytes("F\(id)ID"), info.type == "{fds" {
            name = SMCCodec.decodeFanName(bytes: bytes)
        }
        return FanInfo(id: id, name: name, min: min, max: max)
    }

    public func fanCurrent(_ id: Int) -> Double { readValueOpt("F\(id)Ac") ?? 0 }
    public func fanTarget(_ id: Int) -> Double { readValueOpt("F\(id)Tg") ?? 0 }

    public func setFanTarget(_ id: Int, rpm: Double, floor: Double, ceiling: Double) throws {
        let clamped = Swift.max(Swift.min(rpm, ceiling), floor)
        try writeValue("F\(id)Tg", clamped)
    }

    // MARK: Режимы управления вентилятором

    /// Ключ режима: "F0Md" или "F0md" в зависимости от прошивки
    public func fanModeKey(_ id: Int) -> String? {
        for k in ["F\(id)Md", "F\(id)md"] where (try? keyInfo(k)) != nil {
            return k
        }
        return nil
    }

    /// Включить ручное (форсированное) управление вентилятором
    public func setFanManual(_ id: Int) throws {
        guard let modeKey = fanModeKey(id) else { return }
        try writeRawByte(modeKey, 1)
    }

    /// Вернуть вентилятор под управление системы
    public func setFanAuto(_ id: Int) throws {
        guard let modeKey = fanModeKey(id) else { return }
        let mode = readRawByte(modeKey) ?? 0
        guard mode != 0 else { return }
        try writeRawByte(modeKey, 0)
    }

    /// Полный сброс: вернуть все вентиляторы системе. Ключ Ftst — глобальный
    /// флаг тест-режима SMC (как в exelban/stats).
    public func restoreSystemControl(fans: Int) {
        if let ftst = readRawByte("Ftst"), ftst != 0 {
            try? writeRawByte("Ftst", 0)
        }
        for i in 0..<fans {
            try? setFanAuto(i)
        }
    }
}

// MARK: - Кодирование/декодирование значений SMC

public enum SMCCodec {

    public static func decode(bytes: SMCBytes, size: UInt32, type: String) -> Double? {
        let arr = [bytes.0, bytes.1, bytes.2, bytes.3, bytes.4, bytes.5, bytes.6, bytes.7]
        let be16 = UInt16(arr[0]) << 8 | UInt16(arr[1])
        let le32 = UInt32(arr[0]) | UInt32(arr[1]) << 8 | UInt32(arr[2]) << 16 | UInt32(arr[3]) << 24

        switch type {
        case "flt " where size >= 4:
            return Double(Float32(bitPattern: le32))
        case "fp1f": return Double(be16) / 32768.0
        case "fp4c": return Double(be16) / 4096.0
        case "fp5b": return Double(be16) / 2048.0
        case "fp6a": return Double(be16) / 1024.0
        case "fp79": return Double(be16) / 512.0
        case "fp88": return Double(be16) / 256.0
        case "fpa6": return Double(be16) / 64.0
        case "fpc4": return Double(be16) / 16.0
        case "fpe2": return Double(be16) / 4.0
        case "sp1e": return Double(Int16(bitPattern: be16)) / 16384.0
        case "sp3c": return Double(Int16(bitPattern: be16)) / 4096.0
        case "sp4b": return Double(Int16(bitPattern: be16)) / 2048.0
        case "sp5a": return Double(Int16(bitPattern: be16)) / 1024.0
        case "sp69": return Double(Int16(bitPattern: be16)) / 512.0
        case "sp78": return Double(Int16(bitPattern: be16)) / 256.0
        case "sp87": return Double(Int16(bitPattern: be16)) / 128.0
        case "sp96": return Double(Int16(bitPattern: be16)) / 64.0
        case "spb4": return Double(Int16(bitPattern: be16)) / 16.0
        case "spf0": return Double(Int16(bitPattern: be16))
        case "ui8 " where size >= 1: return Double(arr[0])
        case "ui16" where size >= 2: return Double(be16)
        case "ui32" where size >= 4:
            let v = UInt32(arr[0]) << 24 | UInt32(arr[1]) << 16 | UInt32(arr[2]) << 8 | UInt32(arr[3])
            return Double(v)
        case "ui64" where size >= 8:
            let a = UInt64(arr[0]) << 24 | UInt64(arr[1]) << 16 | UInt64(arr[2]) << 8 | UInt64(arr[3])
            let b = UInt64(arr[4]) << 24 | UInt64(arr[5]) << 16 | UInt64(arr[6]) << 8 | UInt64(arr[7])
            return Double(a << 32 | b)
        case "si8 " where size >= 1: return Double(Int8(bitPattern: arr[0]))
        case "si16" where size >= 2: return Double(Int16(bitPattern: be16))
        case "flag": return Double(arr[0])
        default: return nil
        }
    }

    public static func encode(value: Double, size: UInt32, type: String) -> SMCBytes? {
        let clampedD = { (_ v: Double, _ lo: Double, _ hi: Double) -> Double in
            max(lo, min(hi, v.rounded()))
        }
        var bytes = tuple([UInt8](repeating: 0, count: 32))

        switch type {
        case "flt " where size >= 4:
            let bits = Float32(value).bitPattern
            bytes = tuple([
                UInt8(bits & 0xff), UInt8((bits >> 8) & 0xff),
                UInt8((bits >> 16) & 0xff), UInt8((bits >> 24) & 0xff)
            ])
        case "fpe2" where size == 2:
            let v = UInt16(clampedD(value * 4, 0, Double(UInt16.max)))
            bytes = tuple([UInt8(v >> 8), UInt8(v & 0xff)])
        case "fp88" where size == 2:
            let i = Int16(truncatingIfNeeded: Int(clampedD(value * 256, -32768, 32767)))
            let v = UInt16(bitPattern: i)
            bytes = tuple([UInt8(v >> 8), UInt8(v & 0xff)])
        case "fp79" where size == 2:
            let i = Int16(truncatingIfNeeded: Int(clampedD(value * 512, -32768, 32767)))
            let v = UInt16(bitPattern: i)
            bytes = tuple([UInt8(v >> 8), UInt8(v & 0xff)])
        case "ui8 " where size == 1:
            bytes = tuple([UInt8(clampedD(value, 0, 255))])
        case "ui16" where size == 2:
            let v = UInt16(clampedD(value, 0, 65535))
            bytes = tuple([UInt8(v >> 8), UInt8(v & 0xff)])
        case "ui32" where size == 4:
            let v = UInt32(clampedD(value, 0, 4_294_967_295))
            bytes = tuple([UInt8((v >> 24) & 0xff), UInt8((v >> 16) & 0xff),
                           UInt8((v >> 8) & 0xff), UInt8(v & 0xff)])
        default:
            return nil
        }
        return bytes
    }

    /// Имя вентилятора из ключа F*ID (тип '{fds', имя в байтах 4..15)
    public static func decodeFanName(bytes: SMCBytes) -> String {
        let arr = [bytes.4, bytes.5, bytes.6, bytes.7, bytes.8, bytes.9, bytes.10,
                   bytes.11, bytes.12, bytes.13, bytes.14, bytes.15]
        let chars = arr.compactMap { b -> Character? in
            guard b >= 32 && b < 127 else { return nil }
            return Character(UnicodeScalar(b))
        }
        let name = String(chars).trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? "Fan" : name
    }
}

// MARK: - FourCharCode helpers

extension UInt32 {
    var fourCCString: String {
        let chars = [UInt8((self >> 24) & 0xff), UInt8((self >> 16) & 0xff),
                     UInt8((self >> 8) & 0xff), UInt8(self & 0xff)]
        return String(bytes: chars, encoding: .macOSRoman) ?? "????"
    }
}

extension String {
    var fourCC: UInt32 {
        let bytes = Array(utf8)
        guard bytes.count == 4 else { return 0 }
        return UInt32(bytes[0]) << 24 | UInt32(bytes[1]) << 16 |
               UInt32(bytes[2]) << 8 | UInt32(bytes[3])
    }
}
