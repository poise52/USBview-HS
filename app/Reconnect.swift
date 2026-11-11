import Foundation
import IOKit
import IOUSBHost

enum USBReconnect {
    static func reset(entryID: UInt64) throws {
        guard let match = IORegistryEntryIDMatching(entryID) else {
            throw InspectorError("Не удалось найти выбранную запись USB.")
        }
        let service = IOServiceGetMatchingService(kIOMainPortDefault, match)
        guard service != 0 else { throw InspectorError("Устройство уже отключилось.") }
        defer { IOObjectRelease(service) }
        guard IOObjectConformsTo(service, "IOUSBHostDevice") != 0
                || IOObjectConformsTo(service, "IOUSBDevice") != 0 else {
            throw InspectorError("Выбранная запись не является USB-устройством.")
        }
        do {
            let device = try IOUSBHostDevice(__ioService: service, options: [], queue: nil, interestHandler: nil)
            defer { device.destroy() }
            try device.reset()
        } catch {
            let error = error as NSError
            let code = Int32(truncatingIfNeeded: error.code)
            let reason: String
            switch code {
            case kIOReturnExclusiveAccess, kIOReturnBusy: reason = "Устройство занято другим клиентом."
            case kIOReturnNotPermitted, kIOReturnNotPrivileged: reason = "macOS отказала в доступе к устройству."
            case kIOReturnNoDevice: reason = "Устройство уже отключилось."
            default: reason = error.localizedDescription
            }
            throw InspectorError(reason, detail: " (\(error.domain), \(String(format: "0x%08X", UInt32(bitPattern: code))))")
        }
    }

    static func replacement(for original: USBNode, in snapshot: Snapshot, excluding previousIDs: Set<String>) -> USBNode? {
        let nodes = snapshot.nodes
        guard let identity = original.identity, !nodes.contains(where: { $0.id == original.id }) else { return nil }
        let matches = nodes.filter { node in
            node.kind == original.kind && !previousIDs.contains(node.id) && node.identity.map(identity.matches) == true
        }
        return matches.count == 1 ? matches.first : nil
    }
}
