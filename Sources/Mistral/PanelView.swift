//
//  PanelView.swift — панель меню-бара: температуры, обороты, графики, управление.
//

import SwiftUI

private func tempColor(_ t: Double) -> Color {
    if t >= 85 { return .red }
    if t >= 72 { return .orange }
    if t >= 60 { return .yellow }
    return .green
}

// MARK: - График истории

struct HistoryChart: View {
    let history: [FanController.Sample]

    var body: some View {
        Canvas { context, size in
            // сетка
            var grid = Path()
            for i in 1..<4 {
                let y = size.height * CGFloat(i) / 4
                grid.move(to: CGPoint(x: 0, y: y))
                grid.addLine(to: CGPoint(x: size.width, y: y))
            }
            context.stroke(grid, with: .color(.primary.opacity(0.08)), lineWidth: 1)

            guard history.count > 2 else { return }
            let startT = history.first!.t
            let endT = max(history.last!.t, startT + 1)

            func x(_ t: Double) -> CGFloat {
                CGFloat((t - startT) / (endT - startT)) * size.width
            }

            // температура: 35…95°C
            func yTemp(_ v: Double) -> CGFloat {
                let clamped = min(max(v, 35), 95)
                return size.height - CGFloat((clamped - 35) / 60) * size.height
            }
            // обороты: 0…1
            func yFrac(_ v: Double) -> CGFloat {
                size.height - CGFloat(v) * size.height
            }

            var tempPath = Path()
            var fanPath = Path()
            var startedT = false
            var startedF = false
            for s in history {
                let p = CGPoint(x: x(s.t), y: yTemp(s.temp))
                if startedT { tempPath.addLine(to: p) } else { tempPath.move(to: p); startedT = true }
                let q = CGPoint(x: x(s.t), y: yFrac(s.frac))
                if startedF { fanPath.addLine(to: q) } else { fanPath.move(to: q); startedF = true }
            }

            context.stroke(tempPath, with: .color(.red.opacity(0.9)), lineWidth: 1.6)
            context.stroke(fanPath, with: .color(.blue.opacity(0.75)), lineWidth: 1.4)
        }
    }
}

// MARK: - Строка вентилятора

struct FanRow: View {
    @EnvironmentObject var controller: FanController
    let fan: FanController.FanUI

    private var frac: Double {
        guard fan.max > fan.min else { return 0 }
        return min(1, max(0, (fan.current - fan.min) / (fan.max - fan.min)))
    }

    var body: some View {
        VStack(spacing: 4) {
            HStack {
                Image(systemName: "fan")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Text(fan.name)
                    .font(.system(size: 12))
                    .lineLimit(1)
                Spacer()
                Text("\(Int(fan.current)) об/мин")
                    .font(.system(size: 12, weight: .semibold).monospacedDigit())
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary)
                    Capsule()
                        .fill(Color.accentColor.opacity(0.8))
                        .frame(width: max(6, geo.size.width * frac))
                }
            }
            .frame(height: 5)

            if controller.mode == .manual {
                HStack(spacing: 8) {
                    Slider(
                        value: Binding(
                            get: { controller.manualValues[fan.id] ?? fan.current },
                            set: { controller.manualValues[fan.id] = $0 }
                        ),
                        in: fan.min...fan.max
                    ) { editing in
                        if !editing {
                            controller.applyManual(fan: fan.id,
                                                   rpm: controller.manualValues[fan.id] ?? fan.current)
                        }
                    }
                    .controlSize(.small)

                    Text(String(format: "%.0f", controller.manualValues[fan.id] ?? fan.current))
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 42, alignment: .trailing)
                }
            }
        }
    }
}

// MARK: - Панель

struct PanelView: View {
    @EnvironmentObject var controller: FanController

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if !controller.smcAvailable {
                Label("Нет доступа к SMC", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
                    .font(.callout)
            }
            temps
            HistoryChart(history: controller.history)
                .frame(height: 64)
            legend
            Divider()
            modeSection
            fanList
            Divider()
            helperSection
            footer
        }
        .padding(14)
        .frame(width: 340)
    }

    // MARK: блоки

    private var header: some View {
        HStack {
            Image(systemName: "fan")
                .foregroundStyle(Color.accentColor)
            Text("Mistral")
                .font(.system(size: 14, weight: .bold))
            Spacer()
            if controller.mode != .system {
                Text("активно")
                    .font(.system(size: 10, weight: .semibold))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.accentColor.opacity(0.18)))
            } else if controller.helperInstalled {
                Text("система управляет")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var temps: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 0) {
                Text(String(format: "%.1f°", controller.cpuTemp))
                    .font(.system(size: 30, weight: .bold).monospacedDigit())
                    .foregroundStyle(tempColor(controller.cpuTemp))
                Text("CPU")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 0) {
                Text(controller.gpuTemp > 0 ? String(format: "%.1f°", controller.gpuTemp) : "—")
                    .font(.system(size: 18, weight: .semibold).monospacedDigit())
                    .foregroundStyle(tempColor(controller.gpuTemp))
                Text("GPU")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 0) {
                Text("\(Int(controller.cpuLoad * 100))%")
                    .font(.system(size: 18, weight: .semibold).monospacedDigit())
                    .foregroundStyle(controller.cpuLoad > 0.6 ? .orange : .secondary)
                Text("нагрузка")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    private var legend: some View {
        HStack(spacing: 12) {
            Label("температура", systemImage: "circle.fill")
                .font(.system(size: 9))
                .foregroundStyle(.red.opacity(0.9))
            Label("обороты", systemImage: "circle.fill")
                .font(.system(size: 9))
                .foregroundStyle(.blue.opacity(0.75))
            Spacer()
            Text("4 мин")
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
        }
    }

    private var modeSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Режим", selection: Binding(
                get: { controller.mode },
                set: { controller.setMode($0) }
            )) {
                Text("Система").tag(FanController.Mode.system)
                Text("Авто").tag(FanController.Mode.auto)
                Text("Ручной").tag(FanController.Mode.manual)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            if controller.mode == .auto {
                HStack(spacing: 6) {
                    ForEach(FanController.Profile.allCases) { p in
                        Button {
                            controller.profile = p
                        } label: {
                            Text(p.title)
                                .font(.system(size: 10, weight: controller.profile == p ? .semibold : .regular))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(
                                    Capsule().fill(controller.profile == p
                                                   ? Color.accentColor.opacity(0.2)
                                                   : Color.primary.opacity(0.05))
                                )
                        }
                        .buttonStyle(.plain)
                    }
                    Spacer()
                }
                Toggle("Буст при высокой нагрузке CPU", isOn: Binding(
                    get: { controller.loadBoostEnabled },
                    set: { controller.loadBoostEnabled = $0 }
                ))
                .font(.system(size: 11))
            }

            if let warning = controller.warning {
                Label(warning, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
            }
        }
    }

    private var fanList: some View {
        VStack(spacing: 10) {
            if controller.fans.isEmpty {
                Text(controller.smcAvailable ? "Вентиляторы не найдены" : "—")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(controller.fans) { fan in
                    FanRow(fan: fan)
                }
            }
        }
    }

    private var helperSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !controller.helperInstalled {
                HStack {
                    Text("Для управления нужен помощник (root)")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        controller.installHelper()
                    } label: {
                        if controller.helperBusy {
                            ProgressView().controlSize(.small)
                        } else {
                            Text("Установить…")
                                .font(.system(size: 11, weight: .medium))
                        }
                    }
                    .controlSize(.small)
                    .disabled(controller.helperBusy)
                }
            } else if controller.mode == .system {
                Text("Помощник установлен. Выберите «Авто» или «Ручной».")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            if let msg = controller.helperMessage {
                Text(msg)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var footer: some View {
        VStack(spacing: 6) {
            Divider()
            Toggle("Запускать при входе в систему", isOn: Binding(
                get: { controller.launchAtLogin },
                set: { controller.setLaunchAtLogin($0) }
            ))
            .font(.system(size: 11))

            HStack {
                if controller.helperInstalled {
                    Button {
                        controller.uninstallHelper()
                    } label: {
                        Text("Удалить помощника")
                    }
                    .controlSize(.small)
                }

                Spacer()

                Button {
                    NSApp.terminate(nil)
                } label: {
                    Text("Выйти")
                }
                .controlSize(.small)
            }
        }
    }
}

// MARK: - Главное окно (открывается из меню «Показать Mistral» / «Настройки…»)

final class MainWindow {
    private static var window: NSWindow?
    private static var closeObserver: Any?

    static func show() {
        if let window, window.isVisible {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        NSApp.setActivationPolicy(.accessory)
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 360, height: 620),
                           styleMask: [.titled, .closable],
                           backing: .buffered, defer: false)
        win.title = "Mistral"
        win.contentView = NSHostingView(rootView: PanelView().environmentObject(FanController.shared))
        win.center()
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window = win

        // пока окно открыто — контроллер читает GPU-датчики каждый тик
        FanController.shared.panelVisible = true
        if closeObserver == nil {
            closeObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification, object: win, queue: .main) { _ in
                FanController.shared.panelVisible = false
            }
        }
    }

    /// Mistral --snapshot <путь.png> — рендер панели в файл (для проверки структуры UI)
    static func snapshotIfNeeded() {
        let args = CommandLine.arguments
        guard let idx = args.firstIndex(of: "--snapshot"),
              args.indices.contains(idx + 1) else { return }
        let path = args[idx + 1]
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) {
            let hosting = NSHostingView(rootView: PanelView()
                .environmentObject(FanController.shared)
                .environment(\.colorScheme, .light))
            hosting.frame = NSRect(x: 0, y: 0, width: 340, height: 640)
            guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else {
                print("snapshot: rep failed")
                NSApp.terminate(nil)
                return
            }
            rep.size = hosting.bounds.size
            hosting.cacheDisplay(in: hosting.bounds, to: rep)
            if let png = rep.representation(using: .png, properties: [:]) {
                try? png.write(to: URL(fileURLWithPath: path))
                print("snapshot: \(path)")
            } else {
                print("snapshot: encode failed")
            }
            NSApp.terminate(nil)
        }
    }
}
