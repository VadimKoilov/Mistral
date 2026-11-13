//
//  StatusMenuController.swift — иконка в строке меню и выпадающее меню
//  в стиле Macs Fan Control: вентиляторы с подменю оборотов, профили,
//  «Ещё», «Завершить».
//

import AppKit
import Combine

final class MenuPayload: NSObject {
    let kind: String
    var fan: Int = 0
    var value: Double = 0
    var text: String = ""

    init(kind: String, fan: Int = 0, value: Double = 0, text: String = "") {
        self.kind = kind
        self.fan = fan
        self.value = value
        self.text = text
    }
}

final class StatusMenuController: NSObject, NSMenuDelegate {
    private let controller = FanController.shared
    private var statusItem: NSStatusItem?
    private var cancellable: Any?
    private var lastTitle = ""

    // MARK: - Установка

    func install() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.image = NSImage(systemSymbolName: "fan", accessibilityDescription: "Mistral")?
                .withSymbolConfiguration(.init(pointSize: 13, weight: .medium))
            button.image?.isTemplate = true
            button.title = "--°"
        }
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = self
        item.menu = menu
        statusItem = item

        cancellable = controller.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.updateTitle() }
        }
        updateTitle()
    }

    private func updateTitle() {
        guard let button = statusItem?.button else { return }
        let t = controller.cpuTemp
        let title = t > 0 ? String(format: "%.0f°", t) : "--°"
        // перерисовываем значок только если текст реально изменился
        guard title != lastTitle else { return }
        lastTitle = title
        button.title = title
    }

    // MARK: - Построение меню (перестраивается при каждом открытии)

    func menuNeedsUpdate(_ menu: NSMenu) {
        rebuild(menu)
    }

    private func rebuild(_ menu: NSMenu) {
        menu.removeAllItems()
        let c = controller

        // Показать Mistral
        menu.addItem(make("Показать Mistral", kind: "show"))

        // Вентиляторы
        let fansHeader = make("Доступные вентиляторы:", kind: "")
        fansHeader.isEnabled = false
        menu.addItem(fansHeader)

        if !c.helperInstalled {
            let it = make(c.helperBusy ? "Установка помощника…" : "Помощник не установлен — установить…",
                          kind: "installHelper")
            it.isEnabled = !c.helperBusy
            menu.addItem(it)
        } else if c.fans.isEmpty {
            let it = make("Вентиляторы не найдены", kind: "")
            it.isEnabled = false
            menu.addItem(it)
        } else {
            for fan in c.fans {
                let sub = NSMenu()
                sub.autoenablesItems = false

                let md = c.fanModeByte(fan.id)
                let sys = make("Системное авто", kind: "fanSystem", fan: fan.id)
                sys.state = md == 0 ? .on : .off
                sub.addItem(sys)

                let maxIt = make("Максимальные обороты", kind: "fanMax", fan: fan.id)
                sub.addItem(maxIt)
                sub.addItem(.separator())

                for rpm in presets(fan) {
                    let it = make("\(rpm) об/мин", kind: "fanRpm", fan: fan.id, value: Double(rpm))
                    if md == 1, c.mode == .manual,
                       let v = c.manualValues[fan.id], abs(v - Double(rpm)) < 25 {
                        it.state = .on
                    }
                    sub.addItem(it)
                }

                let fanItem = make("\(fan.name) – \(fanStateText(fan))", kind: "", enabled: true)
                fanItem.submenu = sub
                menu.addItem(fanItem)
            }
        }

        menu.addItem(.separator())

        // Профили
        let profilesHeader = make("Профили:", kind: "")
        profilesHeader.isEnabled = false
        menu.addItem(profilesHeader)

        let sysMode = make("Системное управление", kind: "modeSystem")
        sysMode.state = c.mode == .system ? .on : .off
        menu.addItem(sysMode)

        for p in FanController.Profile.allCases {
            let it = make(p.title, kind: "profile", text: p.rawValue)
            it.state = (c.mode == .auto && c.profile == p) ? .on : .off
            menu.addItem(it)
        }

        let maxAll = make("Максимальные обороты", kind: "maxAll")
        maxAll.state = (c.mode == .manual && c.fans.allSatisfy { f in
            (c.manualValues[f.id] ?? 0) >= f.max - 100
        }) ? .on : .off
        menu.addItem(maxAll)

        menu.addItem(.separator())

        // Настройки
        menu.addItem(make("Настройки…", kind: "settings"))

        // Ещё
        let more = NSMenu()
        more.autoenablesItems = false

        let launch = make("Запускать при входе в систему", kind: "launch")
        launch.state = c.launchAtLogin ? .on : .off
        more.addItem(launch)

        let boost = make("Буст при высокой нагрузке CPU", kind: "boost")
        boost.state = c.loadBoostEnabled ? .on : .off
        more.addItem(boost)

        if c.helperInstalled {
            more.addItem(.separator())
            more.addItem(make("Удалить помощника", kind: "uninstallHelper"))
        }

        let moreItem = make("Еще", kind: "", enabled: true)
        moreItem.submenu = more
        menu.addItem(moreItem)

        menu.addItem(make("Завершить Mistral", kind: "quit"))
    }

    // MARK: - Помощники построения

    private func make(_ title: String, kind: String, fan: Int = 0,
                      value: Double = 0, text: String = "", enabled: Bool? = nil) -> NSMenuItem {
        let hasAction = !kind.isEmpty
        let it = NSMenuItem(title: title, action: hasAction ? #selector(handleMenu(_:)) : nil,
                            keyEquivalent: "")
        it.target = hasAction ? self : nil
        it.isEnabled = enabled ?? hasAction
        it.representedObject = MenuPayload(kind: kind, fan: fan, value: value, text: text)
        return it
    }

    private func presets(_ fan: FanController.FanUI) -> [Int] {
        let lo = Int(fan.min), hi = Int(fan.max)
        let step = max(200, (hi - lo) / 6 / 50 * 50)
        var vals: [Int] = []
        var v = ((lo + step) / 50) * 50
        while v < hi - 100 {
            vals.append(v)
            v += step
        }
        return vals
    }

    private func fanStateText(_ fan: FanController.FanUI) -> String {
        let md = controller.fanModeByte(fan.id)
        if md == 0 { return "Автоматически" }
        switch controller.mode {
        case .auto: return "Авто (Mistral)"
        case .manual:
            let v = controller.manualValues[fan.id] ?? fan.target
            return "\(Int(v)) об/мин"
        case .system: return "Ручной"
        }
    }

    // MARK: - Действия

    @objc private func handleMenu(_ sender: NSMenuItem) {
        guard let p = sender.representedObject as? MenuPayload else { return }
        let c = controller
        switch p.kind {
        case "show", "settings":
            MainWindow.show()
        case "fanSystem":
            c.setFanSystem(p.fan)
        case "fanMax":
            if let f = c.fans.first(where: { $0.id == p.fan }) {
                c.setFanManualRPM(p.fan, rpm: f.max)
            }
        case "fanRpm":
            c.setFanManualRPM(p.fan, rpm: p.value)
        case "modeSystem":
            c.setMode(.system)
        case "profile":
            if let profile = FanController.Profile(rawValue: p.text) {
                c.setProfile(profile)
            }
        case "maxAll":
            c.setAllMax()
        case "launch":
            c.toggleLaunchAtLogin()
        case "boost":
            c.toggleLoadBoost()
        case "installHelper":
            c.installHelper()
        case "uninstallHelper":
            c.uninstallHelper()
        case "quit":
            NSApp.terminate(nil)
        default:
            break
        }
    }
}
