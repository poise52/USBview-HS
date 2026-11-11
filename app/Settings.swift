import SwiftUI

struct InspectorPreferences: DynamicProperty {
    @AppStorage("interfaceLanguage") var language: InterfaceLanguage = .russian
    @AppStorage("autoRefresh") var live = true
    @AppStorage("refreshInterval") var interval = 2
    @AppStorage("showMenuBarItem") var showsMenu = true

    static let intervals = [1, 2, 5, 10]
    var seconds: Int { Self.intervals.contains(interval) ? interval : 2 }
}

extension EnvironmentValues {
    @Entry var appStrings = AppStrings.russian
}

struct InterfaceLocale: ViewModifier {
    private var preferences = InspectorPreferences()

    func body(content: Content) -> some View {
        content
            .environment(\.locale, Locale(identifier: preferences.language.rawValue))
            .environment(\.appStrings, AppStrings(preferences.language))
    }
}

struct ObserveUSB: ViewModifier {
    let model: Inspector
    let surface: Inspector.Surface
    private var preferences = InspectorPreferences()
    private var interval: Int? { preferences.live ? preferences.seconds : nil }

    init(model: Inspector, surface: Inspector.Surface) {
        self.model = model
        self.surface = surface
    }

    func body(content: Content) -> some View {
        content
            .onAppear { model.observe(surface, every: interval) }
            .onChange(of: interval) { _, seconds in model.observe(surface, every: seconds) }
            .onDisappear { model.stopObserving(surface) }
    }
}

struct InspectorSettings: View {
    @Environment(\.appStrings) private var s
    private var preferences = InspectorPreferences()

    var body: some View {
        Form {
            Section {
                Picker(s("Язык интерфейса"), selection: preferences.$language) {
                    Text(verbatim: "Русский").tag(InterfaceLanguage.russian)
                    Text(verbatim: "English").tag(InterfaceLanguage.english)
                }
                Toggle(s("Показывать USB в строке меню"), isOn: preferences.$showsMenu)
            }
            Section(s("Обновление снимка")) {
                Toggle(s("Автообновление"), isOn: preferences.$live)
                Picker(s("Интервал"), selection: preferences.$interval) {
                    ForEach(InspectorPreferences.intervals, id: \.self) { seconds in
                        Text(s.format("%d с", seconds)).tag(seconds)
                    }
                }
                .disabled(!preferences.live)
            }
        }
        .formStyle(.grouped)
        .frame(width: 420)
        .fixedSize(horizontal: false, vertical: true)
        .navigationTitle(s("Настройки"))
    }
}
