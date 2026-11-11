import Darwin
import SwiftUI

private final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}

struct USBInspectorApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = Inspector()
    @AppStorage("interfaceLanguage") private var language: InterfaceLanguage = .russian
    @AppStorage("showMenuBarItem") private var showsMenu = true

    var body: some Scene {
        Window("USBview HS", id: "inspector") {
            ContentView(model: model)
                .modifier(ObserveUSB(model: model, surface: .inspector))
                .modifier(InterfaceLocale())
        }
        .defaultSize(width: 1030, height: 720)

        Window(AppStrings(language)("Мини-окно USB"), id: "compact") {
            MenuPanel(model: model)
                .modifier(ObserveUSB(model: model, surface: .compact))
                .modifier(InterfaceLocale())
        }
        .windowLevel(.floating)
        .windowResizability(.contentSize)
        .defaultPosition(.topLeading)
        .defaultLaunchBehavior(.suppressed)

        Settings { InspectorSettings().modifier(InterfaceLocale()) }

        MenuBarExtra("USBview HS", systemImage: "cable.connector", isInserted: $showsMenu) {
            MenuPanel(model: model)
                .modifier(ObserveUSB(model: model, surface: .menuBar))
                .modifier(InterfaceLocale())
        }
        .menuBarExtraStyle(.window)
    }
}

private func runCLI(_ args: [String]) throws -> Int32 {
    if args == ["--help"] {
        print("USBviewHS [--dump-tree | --dump-json | --details | --descriptors | --network | --storage | --watch]")
        return 0
    }
    if args == ["--descriptors"] {
        let (snapshot, _) = try Engine.capture()
        let devices = snapshot.nodes.filter { $0.kind.isDevice }
        if devices.isEmpty { print("USB-устройства не обнаружены.") }
        var status: Int32 = 0
        for device in devices {
            guard let id = UInt64(device.id) else { throw InspectorError("Некорректный Entry ID.") }
            print(device.title.unicodeScalars.map { CharacterSet.controlCharacters.contains($0) ? " " : String($0) }.joined())
            do { print(try Descriptors.read(id)) }
            catch { print(error.localizedDescription); status = 1 }
            print()
        }
        return status
    }
    let path = Engine.executable.path
    let argv = ([path] + args).map { strdup($0) } + [nil]
    defer { argv.forEach { free($0) } }
    guard !argv.dropLast().contains(where: { $0 == nil }) else { throw InspectorError("Недостаточно памяти.") }
    _ = argv.withUnsafeBufferPointer { execv(path, $0.baseAddress!) }
    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
}

let arguments = Array(CommandLine.arguments.dropFirst())
if arguments.first?.hasPrefix("--") == true {
    do { exit(try runCLI(arguments)) }
    catch {
        FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
        exit(1)
    }
} else {
    USBInspectorApp.main()
}
