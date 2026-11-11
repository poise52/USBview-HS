import Foundation

@main
struct AppTest {
    static func check(_ condition: Bool, _ description: String) throws {
        if !condition { throw InspectorError(description) }
    }

    @MainActor static func main() async throws {
        let valid: [UInt8] = [9, 2, 25, 0, 1, 1, 0, 128, 50, 9, 4, 0, 0, 1, 3, 1, 2, 0, 7, 5, 129, 3, 64, 0, 10]
        let executable = URL(fileURLWithPath: CommandLine.arguments[1])
        let appURL = executable.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        guard let bundle = Bundle(url: appURL) else { throw InspectorError("Missing app bundle") }
        let english = AppStrings(.english, bundle: bundle)
        let translated = try Descriptors.decode(valid, strings: english)
        try check(translated.contains("EP 0x81 · Interrupt · packet 64 B"), "English descriptor resource missing")
        try check(english.section("Интерфейс 2") == "Interface 2", "Interface number lost in translation")
        let vendor = Field(section: "Устройство", label: "Производитель", value: "Контроллер")
        try check(english.value(vendor) == vendor.value, "Translation changed hardware data")
        let report = try Descriptors.decode(valid)
        try check(report.contains("EP 0x81 · Interrupt · пакет 64 B"), "Invalid endpoint")
        for bytes in [Array(valid.dropLast()), [9, 2, 11, 0, 1, 1, 0, 128, 50, 0, 4],
                      [9, 2, 11, 0, 1, 1, 0, 128, 50, 9, 4], [9, 2, 10, 0, 1, 1, 0, 128, 50, 1]] {
            try check((try? Descriptors.decode(bytes)) == nil, "Accepted invalid descriptor")
        }

        func device(_ id: String) -> USBNode {
            USBNode(id: id, kind: .device, title: "Test", subtitle: "1234:ABCD", fields: [], children: [])
        }
        func snapshot(_ child: USBNode) -> Snapshot {
            Snapshot(schema: 1, controllers: [USBNode(id: "1", kind: .controller, title: "xHCI",
                subtitle: "", fields: [], children: [child])])
        }
        let first = snapshot(device("10"))
        try check(first.controllers[0].filtered(by: "abcd")?.children.count == 1, "Search lost ancestry")
        try check(first.controllers[0].filtered(by: "absent") == nil, "Search retained unrelated nodes")
        let model = Inspector()
        model.apply(first, at: Date())
        try check(model.events.isEmpty, "Initial snapshot reported attached devices")
        model.selection = "10"
        model.expanded.remove("1")
        model.apply(first, at: Date())
        try check(model.events.isEmpty && !model.expanded.contains("1"), "Refresh reset expansion or emitted events")
        model.apply(snapshot(device("11")), at: Date())
        try check(model.selection == "overview" && model.events.count == 2, "Replug handling failed")
        try check(model.events[0].attached && !model.events[1].attached, "Wrong event directions")

        var keyboard = device("20")
        keyboard.identity = DeviceIdentity(path: "/bus/hub/port4/keyboard", locationID: 4,
                                           vendorProduct: "1234:ABCD", serial: nil)
        let target = keyboard
        var replugged = device("30")
        replugged.identity = target.identity
        var other = device("31")
        other.identity = DeviceIdentity(path: "/bus/hub/port3/keyboard", locationID: 3,
                                        vendorProduct: "1234:ABCD", serial: nil)
        let baseline = snapshot(target)
        let returned = snapshot(replugged)
        let wrongPort = snapshot(other)
        let resetSelected: @Sendable (UInt64) throws -> Void = { id in
            try check(id == 20, "Reset must target the selected keyboard")
        }
        let recover = Inspector()
        recover.apply(baseline, at: Date())
        recover.selection = target.id
        await recover.reconnect(target, reset: resetSelected, capture: { (wrongPort, Data()) }, timeout: .zero)
        try check(recover.reconnectMessage?.text(.russian).contains("подтвердить не удалось") == true, "Wrong port confirmed")
        recover.apply(baseline, at: Date())
        recover.selection = target.id
        await recover.reconnect(target, reset: resetSelected, capture: { (baseline, Data()) }, timeout: .zero)
        try check(recover.reconnectMessage?.text(.russian).contains("подтвердить не удалось") == true, "Original ID confirmed")
        await recover.reconnect(target, reset: resetSelected, capture: { (returned, Data()) }, timeout: .zero)
        try check(recover.selection == replugged.id && recover.reconnectMessage?.text(.russian).contains("снова подключено") == true,
                  "Reconnected device selection or status lost")
        await recover.reconnect(target, reset: { _ in fatalError("Stale selection issued reset") })
        try check(recover.reconnectMessage?.text(.russian).contains("недоступно") == true, "Stale device reported success")
        await recover.reconnect(replugged, reset: { _ in throw InspectorError("driver busy") },
                                capture: { fatalError("Refused reset started polling") })
        try check(recover.reconnectingID == nil && recover.reconnectMessage?.text(.russian).contains("driver busy") == true,
                  "Driver refusal lost or retry disabled")
        do {
            try USBReconnect.reset(entryID: 0)
            throw InspectorError("Missing service accepted")
        } catch let error as InspectorError {
            try check(error.message.contains("отключилось"), "Unexpected missing-service result")
        }

        let task = Process()
        task.executableURL = executable
        task.arguments = ["--dump-json"]
        let pipe = Pipe()
        task.standardOutput = pipe
        try task.run()
        let bytes = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        try check(task.terminationStatus == 0, "Packaged engine failed")
        let real = try JSONDecoder().decode(Snapshot.self, from: bytes)
        try check(real.schema == 1 && Set(real.nodes.map(\.id)).count == real.nodes.count, "Invalid live snapshot")
        print("OK · descriptor bounds, search, selection, events, packaged CLI (\(real.controllers.count) controllers)")
    }
}
