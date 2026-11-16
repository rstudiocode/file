import FileProvider
import Foundation
import UniformTypeIdentifiers

private func providerError(_ error: Error) -> Error {
    if let error = error as? RelayError, error.status == 401 { return NSFileProviderError(.notAuthenticated) }
    if error is CancellationError { return NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError) }
    return error
}

// A shared folder can have a physical path such as /home/account while still
// being a direct child of the virtual Files root.
private struct ProviderLocation: Codable, Equatable {
    let share: String
    let path: String

    var identifier: NSFileProviderItemIdentifier {
        guard path != "/" else { return .rootContainer }
        // The length prefix keeps the two paths unambiguous when names contain colons.
        return .init(String(share.utf8.count) + ":" + share + path)
    }

    var parent: ProviderLocation {
        path == share ? Self(share: "/", path: "/") : Self(share: share, path: NASItem.parent(of: path))
    }

    static func resolve(_ identifier: NSFileProviderItemIdentifier) throws -> Self {
        if identifier == .rootContainer { return .init(share: "/", path: "/") }
        let fields = identifier.rawValue.split(separator: ":", maxSplits: 1)
        guard fields.count == 2, let size = Int(fields[0]), size > 1 else { throw NSFileProviderError(.noSuchItem) }
        let bytes = fields[1].utf8
        guard size < bytes.count,
              let share = String(bytes: bytes.prefix(size), encoding: .utf8),
              let path = String(bytes: bytes.dropFirst(size), encoding: .utf8),
              valid(share), valid(path), path == share || path.hasPrefix(share + "/") else {
            throw NSFileProviderError(.noSuchItem)
        }
        return .init(share: share, path: path)
    }

    private static func valid(_ value: String) -> Bool {
        value.hasPrefix("/") && !value.dropFirst().split(separator: "/", omittingEmptySubsequences: false)
            .contains(where: { $0.isEmpty || $0 == "." || $0 == ".." })
    }
}

private struct Entry: Codable, Equatable {
    let record: NASItem
    let share: String

    var location: ProviderLocation { .init(share: share, path: record.path) }
}

private final class ProviderItem: NSObject, NSFileProviderItem {
    let entry: Entry
    init(_ entry: Entry) { self.entry = entry }
    var record: NASItem { entry.record }
    var itemIdentifier: NSFileProviderItemIdentifier { entry.location.identifier }
    var parentItemIdentifier: NSFileProviderItemIdentifier { entry.location.parent.identifier }
    var filename: String { record.name }
    var contentType: UTType {
        record.dir ? .folder : UTType(filenameExtension: (filename as NSString).pathExtension) ?? .data
    }
    var capabilities: NSFileProviderItemCapabilities {
        record.dir ? [.allowsContentEnumerating, .allowsReading] : [.allowsReading, .allowsEvicting]
    }
    var contentPolicy: NSFileProviderContentPolicy { .downloadLazily }
    var documentSize: NSNumber? { record.dir ? nil : record.size.map { NSNumber(value: $0) } }
    var contentModificationDate: Date? { record.modified }
    var itemVersion: NSFileProviderItemVersion {
        let version = Data(((record.date ?? "") + "|" + String(record.size ?? -1)).utf8)
        return .init(contentVersion: version, metadataVersion: version)
    }
}

// This index contains metadata only. iOS owns its downloaded copies.
private actor OpenedFiles {
    static let shared = OpenedFiles()

    func list(profile: String) -> [Entry] {
        guard let data = UserDefaults.standard.data(forKey: "opened." + profile),
              let items = try? JSONDecoder().decode([Entry].self, from: data) else { return [] }
        return items
    }

    func record(_ item: Entry, profile: String) {
        let items = [item] + list(profile: profile).filter { $0.location != item.location }
        save(items, profile: profile)
    }

    func update(_ children: [Entry], parent: ProviderLocation, profile: String) {
        let byID = Dictionary(children.map { ($0.location.identifier, $0) }, uniquingKeysWith: { _, new in new })
        let items = list(profile: profile).compactMap { item in
            item.location.parent == parent ? byID[item.location.identifier] : item
        }
        save(items, profile: profile)
    }

    private func save(_ items: [Entry], profile: String) {
        if let data = try? JSONEncoder().encode(items) {
            UserDefaults.standard.set(data, forKey: "opened." + profile)
        }
    }
}

private actor Snapshot {
    private var revisions: [Data: [Entry]] = [:]
    private var order: [Data] = []

    func remember(_ children: [Entry]) -> NSFileProviderSyncAnchor {
        let token = Data(UUID().uuidString.utf8)
        order.append(token)
        revisions[token] = children
        if order.count > 4 { revisions.removeValue(forKey: order.removeFirst()) }
        return .init(token)
    }

    func current() -> NSFileProviderSyncAnchor? { order.last.map { NSFileProviderSyncAnchor($0) } }
    func children(at token: NSFileProviderSyncAnchor) throws -> [Entry] {
        guard let children = revisions[token.rawValue] else { throw NSFileProviderError(.syncAnchorExpired) }
        return children
    }
}

private final class Enumerator: NSObject, NSFileProviderEnumerator {
    private let container: NSFileProviderItemIdentifier
    private let profile: String
    private let snapshot = Snapshot()

    init(container: NSFileProviderItemIdentifier, profile: String) {
        self.container = container
        self.profile = profile
    }

    func invalidate() {}

    private func records() async throws -> [Entry] {
        if container == .trashContainer { return [] }
        if container == .workingSet {
            guard try SessionStore.read()?.profile == profile else { throw RelayError.authentication }
            return await OpenedFiles.shared.list(profile: profile)
        }
        let folder = try ProviderLocation.resolve(container)
        let records = try await Relay.shared.list(folder.path, profile: profile)
        let children = records.map { Entry(record: $0, share: folder.path == "/" ? $0.path : folder.share) }
        await OpenedFiles.shared.update(children, parent: folder, profile: profile)
        return children
    }

    func enumerateItems(for observer: NSFileProviderEnumerationObserver, startingAt page: NSFileProviderPage) {
        Task {
            do {
                let children = try await records()
                _ = await snapshot.remember(children)
                for offset in stride(from: 0, to: children.count, by: 250) {
                    observer.didEnumerate(children.dropFirst(offset).prefix(250).map(ProviderItem.init))
                }
                observer.finishEnumerating(upTo: nil)
            } catch {
                observer.finishEnumeratingWithError(providerError(error))
            }
        }
    }

    func currentSyncAnchor(completionHandler: @escaping (NSFileProviderSyncAnchor?) -> Void) {
        Task {
            if let current = await snapshot.current() {
                completionHandler(current)
            } else if let children = try? await records() {
                let anchor = await snapshot.remember(children)
                completionHandler(anchor)
            } else {
                completionHandler(nil)
            }
        }
    }

    func enumerateChanges(for observer: NSFileProviderChangeObserver, from anchor: NSFileProviderSyncAnchor) {
        Task {
            do {
                let before = try await snapshot.children(at: anchor)
                let after = try await records()
                let previous = Dictionary(before.map { ($0.location.identifier, $0) }, uniquingKeysWith: { _, new in new })
                let next = Set(after.map { $0.location.identifier })
                let removed = before.filter { !next.contains($0.location.identifier) }
                let updated = after.filter { previous[$0.location.identifier] != $0 }
                let newAnchor = await snapshot.remember(after)
                if !removed.isEmpty { observer.didDeleteItems(withIdentifiers: removed.map { $0.location.identifier }) }
                if !updated.isEmpty { observer.didUpdate(updated.map(ProviderItem.init)) }
                observer.finishEnumeratingChanges(upTo: newAnchor, moreComing: false)
            } catch {
                observer.finishEnumeratingWithError(providerError(error))
            }
        }
    }
}

final class Provider: NSObject, NSFileProviderReplicatedExtension {
    private let domain: NSFileProviderDomain
    private var profile: String { domain.identifier.rawValue }

    required init(domain: NSFileProviderDomain) { self.domain = domain }
    func invalidate() {}

    private func metadata(_ id: NSFileProviderItemIdentifier) async throws -> ProviderItem {
        let location = try ProviderLocation.resolve(id)
        guard try SessionStore.read()?.profile == profile else { throw RelayError.authentication }
        if id == .rootContainer {
            let root = NASItem(name: domain.displayName, path: "/", dir: true, size: nil, date: nil)
            return ProviderItem(.init(record: root, share: "/"))
        }
        let children = try await Relay.shared.list(location.parent.path, profile: profile)
        guard let item = children.first(where: { $0.path == location.path }) else {
            throw NSFileProviderError(.noSuchItem)
        }
        return ProviderItem(.init(record: item, share: location.share))
    }

    func item(for identifier: NSFileProviderItemIdentifier, request: NSFileProviderRequest,
              completionHandler: @escaping (NSFileProviderItem?, Error?) -> Void) -> Progress {
        run { progress in
            do { completionHandler(try await self.metadata(identifier), nil) }
            catch { completionHandler(nil, providerError(error)) }
            progress.completedUnitCount = 1
        }
    }

    func fetchContents(for itemIdentifier: NSFileProviderItemIdentifier, version requestedVersion: NSFileProviderItemVersion?,
                       request: NSFileProviderRequest,
                       completionHandler: @escaping (URL?, NSFileProviderItem?, Error?) -> Void) -> Progress {
        run { progress in
            do {
                let item = try await self.metadata(itemIdentifier)
                guard !item.record.dir else { throw NSFileProviderError(.noSuchItem) }
                if let requestedVersion, requestedVersion.contentVersion != item.itemVersion.contentVersion {
                    throw NSFileProviderError(.versionNoLongerAvailable)
                }
                guard let manager = NSFileProviderManager(for: self.domain) else {
                    throw NSFileProviderError(.providerNotFound)
                }
                let directory = try manager.temporaryDirectoryURL()
                let url = try await Relay.shared.download(item.record, profile: self.profile, to: directory)
                await OpenedFiles.shared.record(item.entry, profile: self.profile)
                completionHandler(url, item, nil)
                manager.signalEnumerator(for: .workingSet) { _ in }
                Task { await Relay.shared.recordOpening(item.record.path, profile: self.profile) }
            } catch {
                completionHandler(nil, nil, providerError(error))
            }
            progress.completedUnitCount = 1
        }
    }

    func enumerator(for containerItemIdentifier: NSFileProviderItemIdentifier, request: NSFileProviderRequest) throws
        -> NSFileProviderEnumerator {
        Enumerator(container: containerItemIdentifier, profile: profile)
    }

    func createItem(basedOn itemTemplate: NSFileProviderItem, fields: NSFileProviderItemFields,
                    contents url: URL?, options: NSFileProviderCreateItemOptions, request: NSFileProviderRequest,
                    completionHandler: @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) -> Void) -> Progress {
        completionHandler(nil, fields, false, Self.readOnly)
        return Progress(totalUnitCount: 0)
    }

    func modifyItem(_ item: NSFileProviderItem, baseVersion version: NSFileProviderItemVersion,
                    changedFields: NSFileProviderItemFields, contents newContents: URL?,
                    options: NSFileProviderModifyItemOptions, request: NSFileProviderRequest,
                    completionHandler: @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) -> Void) -> Progress {
        completionHandler(nil, changedFields, false, Self.readOnly)
        return Progress(totalUnitCount: 0)
    }

    func deleteItem(identifier: NSFileProviderItemIdentifier, baseVersion version: NSFileProviderItemVersion,
                    options: NSFileProviderDeleteItemOptions, request: NSFileProviderRequest,
                    completionHandler: @escaping (Error?) -> Void) -> Progress {
        completionHandler(Self.readOnly)
        return Progress(totalUnitCount: 0)
    }

    private static var readOnly: Error { NSError(domain: NSCocoaErrorDomain, code: NSFileWriteNoPermissionError) }

    private func run(_ operation: @escaping (Progress) async -> Void) -> Progress {
        let progress = Progress(totalUnitCount: 1)
        let task = Task { await operation(progress) }
        progress.cancellationHandler = { task.cancel() }
        return progress
    }
}
