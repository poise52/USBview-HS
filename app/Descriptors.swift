import Foundation
import IOKit
import IOKit.usb

enum Descriptors {
    static func read(_ entry: UInt64, strings: AppStrings = .russian) throws -> String {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IORegistryEntryIDMatching(entry))
        guard service != 0 else { throw InspectorError("Устройство отключено.") }
        defer { IOObjectRelease(service) }
        func uuid(_ value: String) -> CFUUID { CFUUIDCreateFromString(nil, value as CFString) }
        var plugin: UnsafeMutablePointer<UnsafeMutablePointer<IOCFPlugInInterface>?>?
        var score: Int32 = 0
        let status = IOCreatePlugInInterfaceForService(service, uuid("9DC7B780-9EC0-11D4-A54F-000A27052861"),
            uuid("C244E858-109C-11D4-91D4-0050E4C6426F"), &plugin, &score)
        guard status == kIOReturnSuccess, let plugin, let table = plugin.pointee else {
            throw failure("IOCreatePlugInInterfaceForService", status)
        }
        defer { _ = table.pointee.Release(plugin) }
        var raw: UnsafeMutableRawPointer?
        let result = table.pointee.QueryInterface(plugin,
            CFUUIDGetUUIDBytes(uuid("5C8187D0-9EF3-11D4-8B45-000A27052861")), &raw)
        guard result == S_OK, let raw else { throw failure("QueryInterface", result) }
        let slot = raw.assumingMemoryBound(to: UnsafeMutablePointer<IOUSBDeviceInterface>?.self)
        guard let api = slot.pointee else { throw InspectorError("Пустой интерфейс IOUSBLib.") }
        defer { _ = api.pointee.Release(raw) }

        var count: UInt8 = 0
        let countStatus = api.pointee.GetNumberOfConfigurations(raw, &count)
        guard countStatus == kIOReturnSuccess else { throw failure("GetNumberOfConfigurations", countStatus) }
        guard count > 0 else { throw InspectorError("Устройство сообщило ноль конфигураций.") }
        var sections: [String] = []
        for index in 0..<count {
            var descriptor: IOUSBConfigurationDescriptorPtr?
            let rc = api.pointee.GetConfigurationDescriptorPtr(raw, index, &descriptor)
            guard rc == kIOReturnSuccess, let descriptor else {
                sections.append(strings.format("Индекс %u · ", index) + failure("GetConfigurationDescriptorPtr", rc).message)
                continue
            }
            let length = Int(UInt16(littleEndian: descriptor.pointee.wTotalLength))
            let buffer = UnsafeRawBufferPointer(start: descriptor, count: length)
            sections.append(try decode(Array(buffer), strings: strings))
        }
        return sections.joined(separator: "\n\n")
    }

    static func decode(_ bytes: [UInt8], strings: AppStrings = .russian) throws -> String {
        func invalid(_ offset: Int) -> InspectorError { InspectorError(strings.format("Повреждённый дескриптор, смещение %d.", offset)) }
        guard bytes.count >= 9, bytes[0] >= 9, bytes[1] == 2,
              Int(bytes[2]) + Int(bytes[3]) * 256 == bytes.count else { throw invalid(0) }
        var lines: [String] = []
        var offset = 0
        while offset < bytes.count {
            guard bytes.count - offset >= 2 else { throw invalid(offset) }
            let length = Int(bytes[offset])
            guard length >= 2, length <= bytes.count - offset else { throw invalid(offset) }
            let record = Array(bytes[offset..<(offset + length)])
            switch record[1] {
            case 2:
                guard length >= 9 else { throw invalid(offset) }
                lines.append(strings.format("Конфигурация %u · интерфейсов %u", record[5], record[4]))
                lines.append(String(format: "  bmAttributes 0x%02X · bMaxPower %u", record[7], record[8]))
            case 4:
                guard length >= 9 else { throw invalid(offset) }
                lines.append(strings.format("  Интерфейс %u · alt %u · класс %02X/%02X/%02X · точек %u",
                                    record[2], record[3], record[5], record[6], record[7], record[4]))
            case 5:
                guard length >= 7 else { throw invalid(offset) }
                let transfer = ["Control", "Isochronous", "Bulk", "Interrupt"][Int(record[3] & 3)]
                let packet = (Int(record[4]) + Int(record[5]) * 256) & 0x7ff
                lines.append(String(format: "    EP 0x%02X", record[2]) + strings.format(" · %@ · пакет %d B · bInterval %u", transfer, packet, record[6]))
            default:
                let hex = record.map { String(format: "%02X", $0) }.joined(separator: " ")
                lines.append(strings.format("    Тип 0x%02X", record[1]) + " · \(hex)")
            }
            offset += length
        }
        return lines.joined(separator: "\n")
    }

    private static func failure(_ operation: String, _ code: Int32) -> InspectorError {
        InspectorError(operation + String(format: " (0x%08X)", UInt32(bitPattern: code)))
    }
}
