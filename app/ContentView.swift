import SwiftUI

private struct TreeLine: Identifiable {
    let node: USBNode
    let level: Int
    var id: String { node.id }
}

struct ContentView: View {
    @Bindable var model: Inspector
    @Environment(\.openWindow) private var openWindow
    @Environment(\.appStrings) private var s
    private var preferences = InspectorPreferences()
    @State private var query = ""
    @State private var journal = false
    @State private var requestedReconnect: USBNode?

    private var rows: [TreeLine] {
        func flatten(_ nodes: [USBNode], level: Int) -> [TreeLine] {
            nodes.flatMap { node in
                [TreeLine(node: node, level: level)] +
                (model.expanded.contains(node.id) || !query.isEmpty ? flatten(node.children, level: level + 1) : [])
            }
        }
        return flatten(model.snapshot?.controllers.compactMap { $0.filtered(by: query, strings: s) } ?? [], level: 0)
    }

    var body: some View {
        NavigationSplitView {
            List(selection: $model.selection) {
                Label(s("Обзор"), systemImage: "square.grid.2x2").tag("overview")
                Section(s("Топология USB")) {
                    ForEach(rows) { item in
                        let node = item.node
                        HStack(spacing: 6) {
                            if !node.children.isEmpty {
                                Button {
                                    if !model.expanded.insert(node.id).inserted { model.expanded.remove(node.id) }
                                } label: {
                                    Image(systemName: model.expanded.contains(node.id) || !query.isEmpty ? "chevron.down" : "chevron.right")
                                        .font(.caption2.bold()).frame(width: 14, height: 24)
                                }
                                .buttonStyle(.plain)
                                .disabled(!query.isEmpty)
                                .accessibilityLabel(s.format("Развернуть или свернуть %@", s.title(node)))
                            } else {
                                Color.clear.frame(width: 14, height: 1)
                            }
                            Image(systemName: node.kind.symbol).frame(width: 17)
                                .foregroundStyle(node.kind.isDevice ? Color.accentColor : .secondary)
                            Text(s.title(node)).lineLimit(1).help(s.title(node))
                        }
                        .padding(.leading, CGFloat(item.level) * 9)
                        .tag(node.id)
                    }
                    if rows.isEmpty && !query.isEmpty { Text(s("Совпадений нет")).foregroundStyle(.secondary) }
                }
            }
            .listStyle(.sidebar)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                VStack(spacing: 0) {
                    Divider()
                    Button { openWindow(id: "compact") } label: {
                        Label(s("Мини-окно USB"), systemImage: "macwindow")
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 16).padding(.vertical, 8)
                            .contentShape(Rectangle())
                    }.buttonStyle(.plain)
                    SettingsLink {
                        Label(s("Настройки"), systemImage: "gearshape")
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 16).padding(.vertical, 10)
                            .contentShape(Rectangle())
                    }.buttonStyle(.plain)
                }.background(.bar)
            }
            .searchable(text: $query, placement: .sidebar, prompt: Text(s("Название, VID:PID, производитель")))
            .navigationSplitViewColumnWidth(min: 220, ideal: 300, max: 470)
        } detail: {
            VStack(spacing: 0) {
                if let message = model.reconnectMessage {
                    HStack {
                        if model.reconnectingID != nil { ProgressView().controlSize(.small) }
                        Text(message.text(s)).textSelection(.enabled)
                        Spacer()
                        if model.reconnectingID == nil {
                            Button { model.reconnectMessage = nil } label: {
                                Label(s("Закрыть сообщение"), systemImage: "xmark")
                            }.buttonStyle(.borderless).labelStyle(.iconOnly)
                        }
                    }
                    .font(.callout).padding(10)
                    Divider()
                }
                if let error = model.error {
                    Label(s.error(error), systemImage: "exclamationmark.triangle")
                        .font(.callout).foregroundStyle(.orange).textSelection(.enabled)
                        .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                }
                if let snapshot = model.snapshot {
                    if let node = snapshot.nodes.first(where: { $0.id == model.selection }) {
                        NodeDetails(node: node, canReconnect: model.reconnectingID == nil,
                                    reconnect: { requestedReconnect = $0 }).id(node.id)
                    } else {
                        Overview(snapshot: snapshot, select: { model.selection = $0 })
                    }
                } else if model.error == nil {
                    ProgressView(s("Чтение IORegistry…")).frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ContentUnavailableView(s("Снимок USB недоступен"), systemImage: "cable.connector.slash")
                }
                Divider()
                HStack {
                    Image(systemName: preferences.live ? "arrow.triangle.2.circlepath" : "pause.circle")
                    Text(preferences.live ? s.format("Автообновление · %d с", preferences.seconds) : s("Автообновление выключено"))
                    Spacer()
                    if let updated = model.updated {
                        Text(s.format("Снимок %@", updated.formatted(date: .omitted, time: .standard))).monospacedDigit()
                    }
                }
                .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 16).padding(.vertical, 7)
            }
        }
        .navigationSplitViewStyle(.balanced)
        .toolbar {
            ToolbarItemGroup {
                Button { Task { await model.refresh() } } label: { Label(s("Обновить"), systemImage: "arrow.clockwise") }
                    .keyboardShortcut("r").help(s("Обновить снимок (⌘R)"))
                Toggle(isOn: preferences.$live) { Label(s("Автообновление"), systemImage: "waveform.path.ecg") }
                    .help(s("Автообновление"))
                Button { journal = true } label: { Label(s("Журнал"), systemImage: "clock.arrow.circlepath") }
                    .help(s("Журнал подключений"))
                Button { model.save() } label: { Label(s("Сохранить JSON"), systemImage: "square.and.arrow.down") }
                    .disabled(model.snapshot == nil).help(s("Сохранить снимок в JSON"))
            }
        }
        .sheet(isPresented: $journal) { EventLog(events: model.events) }
        .modifier(ConfirmReconnect(target: $requestedReconnect, model: model))
        .frame(minWidth: 760, minHeight: 460)
    }
}

private struct Overview: View {
    @Environment(\.appStrings) private var s
    let snapshot: Snapshot
    let select: (String) -> Void

    var body: some View {
        let devices = snapshot.nodes.filter { $0.kind.isDevice }
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text(s("Обзор USB")).font(.largeTitle.bold())
                HStack(spacing: 28) {
                    metric(snapshot.controllers.count, "Контроллеры")
                    metric(snapshot.nodes.filter { $0.kind == .port }.count, "Порты")
                    metric(devices.filter { $0.kind == .hub }.count, "Хабы")
                    metric(devices.filter { $0.kind == .device }.count, "Периферия")
                }
                Divider()
                Text(s("Подключённые устройства")).font(.headline)
                if devices.isEmpty {
                    Text(s("В снимке нет подключённых USB-устройств.")).foregroundStyle(.secondary)
                }
                ForEach(devices) { node in
                    Button { select(node.id) } label: {
                        HStack(spacing: 12) {
                            Image(systemName: node.kind.symbol).foregroundStyle(.tint).frame(width: 26)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(node.title).font(.body.weight(.medium))
                                Text(node.subtitle).font(.caption.monospaced()).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                        }.contentShape(Rectangle())
                    }.buttonStyle(.plain)
                }
            }.padding(26).frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func metric(_ count: Int, _ caption: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(count, format: .number).font(.title.bold()).monospacedDigit()
            Text(s(caption)).font(.caption).foregroundStyle(.secondary)
        }
    }
}

private struct NodeDetails: View {
    @Environment(\.appStrings) private var s
    let node: USBNode
    let canReconnect: Bool
    let reconnect: (USBNode) -> Void
    @State private var showDescriptors = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Label(s(node.kind.caption), systemImage: node.kind.symbol).foregroundStyle(.secondary)
                Text(s.title(node)).font(.largeTitle.bold()).textSelection(.enabled)
                if !node.subtitle.isEmpty { Text(node.subtitle).font(.body.monospaced()).textSelection(.enabled) }
                if node.kind.isDevice {
                    HStack {
                        Button(s("Переподключить…")) { reconnect(node) }.disabled(!canReconnect)
                        Button(s("Дескрипторы конфигураций…")) { showDescriptors = true }
                    }
                }
                let sections = node.fields.reduce(into: [String]()) { if !$0.contains($1.section) { $0.append($1.section) } }
                ForEach(sections, id: \.self) { section in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(s.section(section)).font(.headline)
                        Grid(alignment: .leading, horizontalSpacing: 22, verticalSpacing: 9) {
                            ForEach(Array(node.fields.filter { $0.section == section }.enumerated()), id: \.offset) { _, field in
                                GridRow {
                                    Text(s(field.label)).foregroundStyle(.secondary)
                                    Text(verbatim: s.value(field)).textSelection(.enabled)
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(14)
                        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
                    }
                }
            }.padding(26).frame(maxWidth: .infinity, alignment: .leading)
        }
        .sheet(isPresented: $showDescriptors) { DescriptorSheet(node: node) }
    }
}

private struct DescriptorSheet: View {
    @Environment(\.appStrings) private var s
    let node: USBNode
    @Environment(\.dismiss) private var dismiss
    @State private var output: String?
    @State private var reportHeight: CGFloat = 64

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(s("Дескрипторы конфигураций")).font(.subheadline).foregroundStyle(.secondary)
                Text(node.title).font(.title2.bold())
            }
            if let output {
                ScrollView {
                    Text(verbatim: output)
                        .font(.body.monospaced()).lineSpacing(3)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(14)
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { reportHeight = $0 }
                }
                .frame(height: min(320, max(64, reportHeight)))
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
            } else { ProgressView(s("Чтение дескрипторов…")).controlSize(.small) }
            HStack { Spacer(); Button(s("Закрыть")) { dismiss() }.keyboardShortcut(.cancelAction) }
        }
        .padding(24).frame(width: 560)
        .task(id: s.language) {
            output = nil
            do {
                guard let id = UInt64(node.id) else { throw InspectorError("Некорректный Entry ID.") }
                let strings = s
                output = try await Engine.read { try Descriptors.read(id, strings: strings) }
            } catch { if !Task.isCancelled { output = s.error(error) } }
        }
    }
}

private struct EventLog: View {
    @Environment(\.appStrings) private var s
    let events: [BusEvent]
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(s("Журнал подключений")).font(.title2.bold())
            if events.isEmpty {
                ContentUnavailableView(s("Изменений пока нет"), systemImage: "clock",
                    description: Text(s("Здесь появятся подключения и отключения между снимками USB.")))
            } else {
                List(events) { event in
                    HStack {
                        Image(systemName: event.attached ? "plus.circle" : "minus.circle")
                            .accessibilityLabel(s(event.attached ? "Подключено" : "Отключено"))
                        VStack(alignment: .leading) { Text(event.device.title); Text(event.device.subtitle).font(.caption) }
                        Spacer()
                        Text(event.time, format: .dateTime.hour().minute().second()).monospacedDigit()
                    }
                }
            }
            HStack { Spacer(); Button(s("Закрыть")) { dismiss() }.keyboardShortcut(.cancelAction) }
        }.padding(22).frame(width: 540, height: 360)
    }
}
