import Foundation

enum InterfaceLanguage: String, CaseIterable {
    case russian = "ru"
    case english = "en"
}

struct AppStrings: Sendable {
    let language: InterfaceLanguage
    private let translations: Bundle?

    init(_ language: InterfaceLanguage, bundle: Bundle = .main) {
        self.language = language
        translations = bundle.url(forResource: language.rawValue, withExtension: "lproj").flatMap(Bundle.init(url:))
    }

    static let russian = AppStrings(.russian)

    func callAsFunction(_ key: String) -> String {
        translations?.localizedString(forKey: key, value: key, table: nil) ?? key
    }

    func format(_ key: String, _ arguments: CVarArg...) -> String {
        String(format: self(key), arguments: arguments)
    }

    func title(_ node: USBNode) -> String {
        guard node.kind == .port else { return node.title }
        if node.title.hasPrefix("Порт ") { return format("Порт %@", String(node.title.dropFirst(5))) }
        return self(node.title)
    }

    func section(_ name: String) -> String {
        for (prefix, formatKey) in [("Интерфейс ", "Интерфейс %@"), ("Накопитель · ", "Накопитель · %@"),
                                    ("Сеть · ", "Сеть · %@")] where name.hasPrefix(prefix) {
            return format(formatKey, String(name.dropFirst(prefix.count)))
        }
        return self(name)
    }

    func value(_ field: Field) -> String {
        switch field.label {
        case "Соединение", "Запись", "Линк", "Ошибки линии", "Активные транспорты", "Выделенные транспорты", "Поддерживает":
            return self(field.value)
        case "Класс USB", "Класс":
            if field.value.hasPrefix("По интерфейсам · ") {
                return format("По интерфейсам · %@", String(field.value.dropFirst("По интерфейсам · ".count)))
            }
        default: break
        }
        return field.value
    }

    func error(_ error: any Error) -> String {
        if let error = error as? InspectorError { return self(error.message) + error.detail }
        return error.localizedDescription
    }
}

enum ReconnectNotice {
    case unavailable(String), resetting(String), returned(String), unconfirmed(String), failed(String, any Error)

    func text(_ strings: AppStrings) -> String {
        switch self {
        case .unavailable(let name): strings.format("«%@» уже недоступно для переподключения.", name)
        case .resetting(let name): strings.format("Переподключение «%@»…", name)
        case .returned(let name): strings.format("«%@» снова подключено.", name)
        case .unconfirmed(let name): strings.format("macOS приняла запрос. Повторное появление «%@» подтвердить не удалось.", name)
        case .failed(let name, let error): strings.format("Не удалось переподключить «%@». %@", name, strings.error(error))
        }
    }
}
