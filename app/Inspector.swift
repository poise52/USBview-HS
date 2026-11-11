import AppKit
import Observation
import UniformTypeIdentifiers

struct BusEvent: Identifiable {
    let id = UUID()
    let time: Date
    let attached: Bool
    let device: USBNode
}

@MainActor @Observable
final class Inspector {
    var snapshot: Snapshot?
    var events: [BusEvent] = []
    var updated: Date?
    var error: (any Error)?
    var selection: String? = "overview"
    var expanded = Set<String>()
    private(set) var reconnectingID: String?
    var reconnectMessage: ReconnectNotice?
    private var exportData: Data?
    private var knownBranches = Set<String>()

    enum Surface: Hashable { case inspector, menuBar, compact }
    private var visibleSurfaces = Set<Surface>()
    private var pollTask: Task<Void, Never>?
    private var interval: Int?

    func observe(_ surface: Surface, every seconds: Int?) {
        let wasIdle = visibleSurfaces.isEmpty
        visibleSurfaces.insert(surface)
        guard wasIdle || interval != seconds else { return }
        interval = seconds
        pollTask?.cancel()
        pollTask = Task {
            repeat {
                await refresh()
                guard let seconds, !Task.isCancelled else { return }
                do { try await Task.sleep(for: .seconds(seconds)) } catch { return }
            } while !Task.isCancelled
        }
    }

    func stopObserving(_ surface: Surface) {
        visibleSurfaces.remove(surface)
        if visibleSurfaces.isEmpty { pollTask?.cancel(); pollTask = nil }
    }

    @discardableResult
    func refresh(using capture: @escaping @Sendable () throws -> (Snapshot, Data) = Engine.capture) async -> Snapshot? {
        do {
            let (next, data) = try await Engine.read(capture)
            apply(next, at: Date())
            exportData = data
            error = nil
            return next
        } catch {
            if !Task.isCancelled { self.error = error }
            return nil
        }
    }

    func reconnect(_ target: USBNode,
                   reset: @escaping @Sendable (UInt64) throws -> Void = USBReconnect.reset,
                   capture: @escaping @Sendable () throws -> (Snapshot, Data) = Engine.capture,
                   timeout: Duration = .seconds(10)) async {
        guard reconnectingID == nil else { return }
        guard target.kind.isDevice, let entryID = UInt64(target.id), let snapshot,
              snapshot.nodes.contains(where: { $0.id == target.id && $0.kind == target.kind }) else {
            reconnectMessage = .unavailable(target.title)
            return
        }
        let previousIDs = Set(snapshot.nodes.map(\.id))
        reconnectingID = target.id
        reconnectMessage = .resetting(target.title)
        defer {
            reconnectingID = nil
            if selection == target.id, self.snapshot?.nodes.contains(where: { $0.id == target.id }) == false {
                selection = "overview"
            }
        }
        do {
            try await Engine.read { try reset(entryID) }
            let deadline = ContinuousClock.now + timeout
            repeat {
                if let current = await refresh(using: capture),
                   let returned = USBReconnect.replacement(for: target, in: current, excluding: previousIDs) {
                    if selection == target.id || selection == nil { selection = returned.id }
                    reconnectMessage = .returned(returned.title)
                    return
                }
                try Task.checkCancellation()
                guard ContinuousClock.now < deadline else { break }
                try await Task.sleep(for: .milliseconds(250))
            } while true
            reconnectMessage = .unconfirmed(target.title)
        } catch is CancellationError {
            reconnectMessage = nil
        } catch {
            reconnectMessage = .failed(target.title, error)
        }
    }

    func apply(_ next: Snapshot, at time: Date) {
        let nodes = next.nodes
        let ids = Set(nodes.map(\.id))
        if let previous = snapshot {
            let before = previous.nodes.filter { $0.kind.isDevice }
            let after = nodes.filter { $0.kind.isDevice }
            let oldIDs = Set(before.map(\.id))
            let newIDs = Set(after.map(\.id))
            let added = after.filter { !oldIDs.contains($0.id) }.map { BusEvent(time: time, attached: true, device: $0) }
            let removed = before.filter { !newIDs.contains($0.id) }.map { BusEvent(time: time, attached: false, device: $0) }
            if !(added.isEmpty && removed.isEmpty) { events = Array((added + removed + events).prefix(200)) }
        }
        let branches = Set(nodes.filter { !$0.children.isEmpty }.map(\.id))
        expanded.formIntersection(branches)
        expanded.formUnion(branches.subtracting(knownBranches))
        knownBranches = branches
        if let selection, selection != "overview", selection != reconnectingID, !ids.contains(selection) {
            self.selection = "overview"
        }
        if snapshot?.controllers != next.controllers { snapshot = next }
        updated = time
    }

    func save() {
        guard let exportData else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "usb-topology.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try exportData.write(to: url, options: .atomic) }
        catch { NSAlert(error: error).runModal() }
    }
}
