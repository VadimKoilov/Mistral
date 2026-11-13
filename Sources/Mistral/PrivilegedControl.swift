//
//  PrivilegedControl.swift — клиент mistrald (root-хелпера) + установка/удаление.
//

import Foundation
import Darwin

final class PrivilegedControl {

    static let socketPath = "/var/run/mistralctl.sock"
    static let label = "app.mistral.helper"
    static let installDir = "/usr/local/mistral"
    static let plistPath = "/Library/LaunchDaemons/app.mistral.helper.plist"

    enum HelperError: Error, CustomStringConvertible {
        case timeout
        case protocolError(String)

        var description: String {
            switch self {
            case .timeout: return "хелпер не отвечает"
            case .protocolError(let m): return "ошибка хелпера: \(m)"
            }
        }
    }

    /// Демо-режим для разработки UI (без реальных записей)
    static var demoMode: Bool {
        ProcessInfo.processInfo.environment["MISTRAL_DEMO"] == "1"
    }

    /// Переопределение пути сокета (для разработки)
    static var effectiveSocketPath: String {
        ProcessInfo.processInfo.environment["MISTRAL_SOCKET"] ?? socketPath
    }

    // MARK: - Сокет

    private func connectSocket(timeout: TimeInterval) -> Int32? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let path = Self.effectiveSocketPath
        let bytes = Array(path.utf8CString)
        guard bytes.count <= MemoryLayout<sockaddr_un>.size - MemoryLayout<sa_family_t>.size else {
            close(fd)
            return nil
        }
        withUnsafeMutableBytes(of: &addr.sun_path) { dst in
            for (i, b) in bytes.enumerated() { dst[i] = UInt8(b) }
        }

        var tv = timeval(tv_sec: 0, tv_usec: Int32(timeout * 1_000_000))
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        let res = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                connect(fd, sa, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard res == 0 else { close(fd); return nil }
        return fd
    }

    private func socketCommand(_ cmd: String, timeout: TimeInterval = 0.5) -> String? {
        guard let fd = connectSocket(timeout: timeout) else { return nil }
        defer { close(fd) }
        let msg = cmd + "\n"
        _ = msg.withCString { send(fd, $0, strlen($0), 0) }
        var buf = [UInt8](repeating: 0, count: 512)
        let n = recv(fd, &buf, buf.count - 1, 0)
        guard n > 0 else { return nil }
        var s = String(decoding: buf[0..<n], as: UTF8.self)
        while s.hasSuffix("\n") || s.hasSuffix("\r") { s.removeLast() }
        return s
    }

    private func exec(_ cmd: String) throws -> String {
        if Self.demoMode { return "OK demo" }
        guard let r = socketCommand(cmd) else { throw HelperError.timeout }
        guard r.hasPrefix("OK") else { throw HelperError.protocolError(r) }
        return r
    }

    /// Хелпер установлен и отвечает?
    var installed: Bool {
        if Self.demoMode { return true }
        guard let r = socketCommand("PING") else { return false }
        return r.hasPrefix("OK mistrald")
    }

    // MARK: - Команды управления

    func setTarget(fan: Int, rpm: Double) throws {
        _ = try exec("SETT \(fan) \(Int(rpm))")
    }

    func setMode(fan: Int, manual: Bool) throws {
        _ = try exec("MODE \(fan) \(manual ? 1 : 0)")
    }

    func reset() throws {
        _ = try exec("RESET")
    }

    enum InstallError: Error {
        case message(String)
    }

    // MARK: - Установка хелпера (диалог с паролем администратора)

    static func helperSourceURL() -> URL? {
        if let exe = Bundle.main.executableURL {
            let sibling = exe.deletingLastPathComponent().appendingPathComponent("mistrald")
            if FileManager.default.fileExists(atPath: sibling.path) { return sibling }
        }
        // для запуска из .build (разработка)
        if let exe = Bundle.main.executableURL {
            return exe.deletingLastPathComponent().appendingPathComponent("mistrald")
        }
        return nil
    }

    static func plistContent() -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key>
            <string>\(label)</string>
            <key>ProgramArguments</key>
            <array>
                <string>\(installDir)/mistrald</string>
            </array>
            <key>RunAtLoad</key>
            <true/>
            <key>KeepAlive</key>
            <true/>
            <key>StandardOutPath</key>
            <string>\(installDir)/helper.log</string>
            <key>StandardErrorPath</key>
            <string>\(installDir)/helper.log</string>
        </dict>
        </plist>
        """
    }

    static func uninstall(completion: @escaping (Result<Void, PrivilegedControl.InstallError>) -> Void) {
        DispatchQueue.global().async {
            let shell = "launchctl bootout system/\(label) >/dev/null 2>&1; rm -f \(plistPath) \(installDir)/owner.uid \(socketPath); rm -rf \(installDir)"
            runOsascript(shell: shell,
                         prompt: "Mistral: удаление помощника (нужны права администратора)",
                         completion: completion)
        }
    }

    static func install(completion: @escaping (Result<Void, PrivilegedControl.InstallError>) -> Void) {
        DispatchQueue.global().async {
            guard let src = helperSourceURL() else {
                DispatchQueue.main.async { completion(.failure(.message("Не найден файл помощника (mistrald)"))) }
                return
            }
            // plist кладём во временную папку заранее (без root)
            let tmpPlist = NSTemporaryDirectory() + "app.mistral.helper.plist"
            do {
                try plistContent().write(toFile: tmpPlist, atomically: true, encoding: .utf8)
            } catch {
                DispatchQueue.main.async { completion(.failure(.message("Не удалось записать plist: \(error.localizedDescription)"))) }
                return
            }

            let uid = getuid()
            let shell =
                "mkdir -p \(installDir) && " +
                "cp '\(src.path)' \(installDir)/mistrald && " +
                "chmod 755 \(installDir)/mistrald && " +
                "chown root:wheel \(installDir)/mistrald && " +
                "printf \(uid) > \(installDir)/owner.uid && " +
                "cp '\(tmpPlist)' \(plistPath) && " +
                "chown root:wheel \(plistPath) && " +
                "launchctl bootout system/\(label) >/dev/null 2>&1; " +
                "launchctl bootstrap system \(plistPath)"

            runOsascript(shell: shell,
                         prompt: "Mistral установит помощника для управления вентиляторами",
                         completion: completion)
        }
    }

    private static func runOsascript(shell: String, prompt: String,
                                     completion: @escaping (Result<Void, PrivilegedControl.InstallError>) -> Void) {
        // osascript отдельным процессом: NSAppleScript нельзя использовать вне main-потока
        let script = "do shell script \"\(shell)\" with administrator privileges with prompt \"\(prompt)\""
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", script]
        let stderr = Pipe()
        p.standardError = stderr
        p.standardOutput = Pipe()

        do {
            try p.run()
        } catch {
            DispatchQueue.main.async { completion(.failure(.message("Не удалось запустить osascript"))) }
            return
        }
        p.terminationHandler = { proc in
            DispatchQueue.main.async {
                if proc.terminationStatus == 0 {
                    completion(.success(()))
                } else {
                    let data = stderr.fileHandleForReading.readDataToEndOfFile()
                    let msg = String(decoding: data, as: UTF8.self)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    completion(.failure(.message(msg.isEmpty ? "отклонено пользователем" : msg)))
                }
            }
        }
    }
}
