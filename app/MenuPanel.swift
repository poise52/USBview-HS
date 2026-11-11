import SwiftUI

struct MenuPanel: View {
    private let deviceRowHeight: CGFloat = 44
    let model: Inspector
    @Environment(\.appStrings) private var s
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    @Environment(\.dismiss) private var dismiss
    @State private var target: USBNode?

    private func openInspector(_ id: String) {
        model.selection = id
        dismiss()
        NSApp.activate()
        openWindow(id: "inspector")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("USBview HS", systemImage: "cable.connector").font(.headline)
                Spacer()
                Button { Task { await model.refresh() } } label: {
                    Label(s("Обновить"), systemImage: "arrow.clockwise")
                }.labelStyle(.iconOnly)
                Button {
                    dismiss()
                    NSApp.activate()
                    openSettings()
                } label: {
                    Label(s("Настройки"), systemImage: "gearshape")
                }.labelStyle(.iconOnly)
            }
            Divider()
            if let error = model.error {
                Label(s.error(error), systemImage: "exclamationmark.triangle")
                    .font(.callout).foregroundStyle(.secondary)
            }
            if let snapshot = model.snapshot {
                let devices = snapshot.nodes.filter { $0.kind.isDevice }
                if devices.isEmpty {
                    Text(s("Нет подключённых устройств")).foregroundStyle(.secondary)
                } else {
                    ScrollView {
                        VStack(spacing: 0) {
                            ForEach(devices) { node in
                                HStack(spacing: 8) {
                                    Button { openInspector(node.id) } label: {
                                        HStack(spacing: 10) {
                                            Image(systemName: node.kind.symbol).frame(width: 20)
                                            VStack(alignment: .leading, spacing: 3) {
                                                Text(node.title).lineLimit(1)
                                                Text(node.subtitle).font(.caption).foregroundStyle(.secondary)
                                            }
                                            Spacer()
                                        }.contentShape(Rectangle())
                                    }.buttonStyle(.plain)
                                    Button { target = node } label: {
                                        Label(s.format("Переподключить «%@»?", node.title), systemImage: "arrow.triangle.2.circlepath")
                                    }
                                    .labelStyle(.iconOnly)
                                    .help(s("Переподключить…"))
                                    .disabled(model.reconnectingID != nil)
                                }.frame(minHeight: deviceRowHeight)
                            }
                        }
                        .padding(.trailing, 16)
                    }
                    .frame(height: CGFloat(min(devices.count, 5)) * deviceRowHeight)
                    .clipped()
                    .padding(.vertical, 4)
                }
            } else if model.error == nil {
                ProgressView(s("Чтение IORegistry…")).controlSize(.small)
            }
            if let message = model.reconnectMessage {
                Text(message.text(s)).font(.callout)
            }
            Divider()
            Button(s("Открыть USB-инспектор")) { openInspector("overview") }
        }
        .buttonStyle(.borderless)
        .padding(16)
        .frame(width: 340)
        .navigationTitle(s("Мини-окно USB"))
        .modifier(ConfirmReconnect(target: $target, model: model))
    }
}

struct ConfirmReconnect: ViewModifier {
    @Binding var target: USBNode?
    let model: Inspector
    @Environment(\.appStrings) private var s

    func body(content: Content) -> some View {
        let presented = Binding(get: { target != nil }, set: { if !$0 { target = nil } })
        content.alert(s.format("Переподключить «%@»?", target?.title ?? ""), isPresented: presented, presenting: target) { node in
            Button(s("Отмена"), role: .cancel) {}
            Button(s("Переподключить"), role: .destructive) {
                Task { await model.reconnect(node) }
            }
        } message: { node in
            if node.kind == .hub {
                Text(s("Устройства на этой ветке хаба временно отключатся. Перед сбросом извлеките подключённые к ней тома."))
            } else if node.fields.contains(where: { $0.label == "BSD-имя" }) {
                Text(s("Сначала извлеките тома этого накопителя в Finder. Сброс прерывает операции с диском."))
            } else {
                Text(s("macOS кратко отключит это USB-устройство и попробует подключить его заново."))
            }
        }
    }
}
