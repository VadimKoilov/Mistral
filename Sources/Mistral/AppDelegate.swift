//
//  AppDelegate.swift
//

import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusMenu: StatusMenuController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        FanController.shared.start()

        statusMenu = StatusMenuController()
        statusMenu?.install()

        MainWindow.snapshotIfNeeded()
        if CommandLine.arguments.contains("--debugwindow") {
            MainWindow.show()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Возвращаем вентиляторы под системное управление при выходе
        FanController.shared.shutdownRestore()
    }
}
