import Foundation

enum NodeKind: String, Codable {
    case controller, port, hub, device

    var isDevice: Bool { self == .hub || self == .device }

    var symbol: String {
        switch self {
        case .controller: "cpu"
        case .port: "cable.connector"
        case .hub: "point.3.connected.trianglepath.dotted"
        case .device: "externaldrive.connected.to.line.below"
        }
    }

    var caption: String {
        switch self {
        case .controller: "Контроллер"
        case .port: "Порт USB"
        case .hub: "USB-хаб"
        case .device: "USB-устройство"
        }
    }
}

struct Field: Codable, Equatable, Sendable {
    let section: String
    let label: String
    let value: String
}

struct DeviceIdentity: Codable, Equatable, Sendable {
    let path: String
    let locationID: Int64?
    let vendorProduct: String?
    let serial: String?

    func matches(_ other: Self) -> Bool {
        guard vendorProduct == other.vendorProduct, serial == other.serial else { return false }
        if !path.isEmpty { return path == other.path }
        return locationID != nil && locationID == other.locationID && vendorProduct != nil
    }
}

struct USBNode: Identifiable, Codable, Equatable, Sendable {
    let id: String
    let kind: NodeKind
    let title: String
    let subtitle: String
    let fields: [Field]
    var children: [USBNode]
    var identity: DeviceIdentity? = nil

    var all: [USBNode] { [self] + children.flatMap(\.all) }

    func filtered(by query: String, strings: AppStrings = .russian) -> USBNode? {
        if query.isEmpty || [strings.title(self), subtitle, id].contains(where: { $0.localizedCaseInsensitiveContains(query) }) {
            return self
        }
        if fields.contains(where: { ["Производитель", "Серийный номер", "BSD-имя", "Интерфейс"].contains($0.label)
                && $0.value.localizedCaseInsensitiveContains(query) }) { return self }
        var copy = self
        copy.children = children.compactMap { $0.filtered(by: query, strings: strings) }
        return copy.children.isEmpty ? nil : copy
    }
}

struct Snapshot: Codable, Sendable {
    let schema: Int
    let controllers: [USBNode]
    var nodes: [USBNode] { controllers.flatMap(\.all) }
}

struct InspectorError: LocalizedError {
    let message: String
    let detail: String
    init(_ message: String, detail: String = "") { self.message = message; self.detail = detail }
    var errorDescription: String? { message + detail }
}

enum Engine {
    static var executable: URL {
        Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/usbview-hs")
    }

    static func capture() throws -> (Snapshot, Data) {
        let task = Process()
        task.executableURL = executable
        task.arguments = ["--dump-json"]
        let output = Pipe()
        // Both streams share one pipe so neither can block the child while we drain the other.
        task.standardOutput = output
        task.standardError = output
        try task.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        guard task.terminationStatus == 0 else {
            throw InspectorError(String(decoding: data.prefix(4096), as: UTF8.self))
        }
        let snapshot = try JSONDecoder().decode(Snapshot.self, from: data)
        guard snapshot.schema == 1 else { throw InspectorError("Неизвестная версия формата снимка.") }
        return (snapshot, data)
    }

    static let queue = DispatchQueue(label: "local.usbviewhs.capture", qos: .utility)

    static func read<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try Task.checkCancellation()
        let result: T = try await withCheckedThrowingContinuation { continuation in
            queue.async { continuation.resume(with: Result(catching: work)) }
        }
        try Task.checkCancellation()
        return result
    }
}
