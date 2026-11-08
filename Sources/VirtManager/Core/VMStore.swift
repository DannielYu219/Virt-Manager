import AppKit
import Combine
import Darwin
import Foundation
import Virtualization

@MainActor
public final class VMStore: ObservableObject {
    @Published public private(set) var machines: [VMRecord] = []
    @Published public var errorMessage: String?
    public let rootURL: URL

    private struct Entry: Codable {
        let id: UUID
        var url: URL
        var bookmark: Data?
    }
    private let fileManager = FileManager.default
    private var entries: [UUID: Entry] = [:]
    private var registryLoaded = false
    private var registryURL: URL { rootURL.appendingPathComponent("Library.plist") }

    public init(rootURL: URL? = nil) {
        self.rootURL = (rootURL ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/VirtManager/Machines", isDirectory: true)).standardizedFileURL
        reload()
    }

    public func directory(for record: VMRecord) -> URL {
        entries[record.id]?.url ?? rootURL.appendingPathComponent(record.id.uuidString + ".virtvm", isDirectory: true)
    }

    public func create(_ record: VMRecord, parentDirectory: URL? = nil) throws {
        try validate(record)
        try loadRegistry()
        guard entries[record.id] == nil else { throw StoreError.operation("A machine with this ID is already registered.") }
        let parent = (parentDirectory ?? rootURL).standardizedFileURL
        try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
        let external = parent.resolvingSymlinksInPath() != rootURL.resolvingSymlinksInPath()
        let filename = (external ? sanitized(record.name) + "-" : "") + record.id.uuidString + ".virtvm"
        let dir = parent.appendingPathComponent(filename, isDirectory: true)
        guard mkdir(dir.path, S_IRWXU) == 0 else {
            throw StoreError.operation("Cannot create machine package: \(String(cString: strerror(errno)))")
        }
        // Retain incomplete newly created packages on failure; never remove user files.
        let fd = open(dir.appendingPathComponent("Disk.img").path, O_CREAT | O_EXCL | O_RDWR, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw StoreError.operation("Cannot create sparse disk: \(String(cString: strerror(errno)))") }
        let (bytes, overflow) = Int64(record.diskGiB).multipliedReportingOverflow(by: 1024 * 1024 * 1024)
        guard !overflow, ftruncate(fd, off_t(bytes)) == 0 else { close(fd); throw StoreError.operation("Cannot size sparse disk.") }
        close(fd)
        if record.kind == .linux {
            _ = try VZEFIVariableStore(creatingVariableStoreAt: dir.appendingPathComponent("EFIVariableStore"))
            try VZGenericMachineIdentifier().dataRepresentation.write(to: dir.appendingPathComponent("MachineIdentifier"), options: .withoutOverwriting)
        }
        let packageRecord = try WoAPackage.prepare(record: record, in: dir, fileManager: fileManager)
        try VMPackage.write(record: packageRecord, to: dir)
        try register(packageRecord, at: dir)
        reload()
    }

    public func update(_ record: VMRecord) throws {
        try validate(record)
        guard let entry = entries[record.id] else { throw StoreError.notFound }
        try withAccess(entry.url) {
            let executionLock = try VMExecutionLock(directory: entry.url)
            defer { withExtendedLifetime(executionLock) {} }
            try verifyPackage(entry.url, id: record.id)
            let packageRecord = try WoAPackage.prepare(record: record, in: entry.url, fileManager: fileManager)
            try VMPackage.write(record: packageRecord, to: entry.url)
        }
        reload()
    }

    @discardableResult
    public func importPackage(at url: URL) throws -> VMRecord {
        try loadRegistry()
        let dir = url.standardizedFileURL
        let record = try withAccess(dir) {
            try verifyPackageDirectory(dir)
            return try VMPackage.read(from: dir)
        }
        try validate(record)
        try register(record, at: dir)
        reload()
        return record
    }

    public func remove(_ record: VMRecord) throws {
        guard let entry = entries[record.id] else { throw StoreError.notFound }
        try withAccess(entry.url) {
            let executionLock = try VMExecutionLock(directory: entry.url)
            defer { withExtendedLifetime(executionLock) {} }
            try verifyPackage(entry.url, id: record.id)
            // Only the exact registered, identity-checked package is sent to Trash.
            var result: NSURL?
            try fileManager.trashItem(at: entry.url, resultingItemURL: &result)
        }
        entries.removeValue(forKey: record.id)
        try saveRegistry()
        reload()
    }

    public func reload() {
        var failures: [String] = []
        do { try loadRegistry() } catch { errorMessage = error.localizedDescription; return }
        do { try migrateLegacyDirectories(failures: &failures) } catch { failures.append(error.localizedDescription) }
        var candidates = entries
        if fileManager.fileExists(atPath: rootURL.path) {
            do {
                let urls = try fileManager.contentsOfDirectory(at: rootURL, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                for url in urls where url.pathExtension.lowercased() == "virtvm" {
                    do {
                        try verifyPackageDirectory(url)
                        let record = try VMPackage.read(from: url)
                        if let existing = candidates[record.id], existing.url.resolvingSymlinksInPath() != url.resolvingSymlinksInPath(),
                           fileManager.fileExists(atPath: existing.url.path) {
                            throw StoreError.operation("Duplicate machine ID in \(url.lastPathComponent).")
                        }
                        candidates[record.id] = Entry(id: record.id, url: url, bookmark: nil)
                    } catch { failures.append("\(url.lastPathComponent): \(error.localizedDescription)") }
                }
            } catch { failures.append(error.localizedDescription) }
        }
        entries = candidates
        var loaded: [VMRecord] = []
        for entry in entries.values {
            do {
                let record = try withAccess(entry.url) {
                    try verifyPackage(entry.url, id: entry.id)
                    return try VMPackage.read(from: entry.url)
                }
                loaded.append(record)
            } catch { failures.append("\(entry.url.lastPathComponent): \(error.localizedDescription)") }
        }
        machines = loaded.sorted { $0.createdAt < $1.createdAt }
        do { if !entries.isEmpty || fileManager.fileExists(atPath: registryURL.path) { try saveRegistry() } }
        catch { failures.append(error.localizedDescription) }
        errorMessage = failures.isEmpty ? nil : failures.joined(separator: "\n")
    }

    private func register(_ record: VMRecord, at url: URL) throws {
        if let old = entries[record.id], old.url.resolvingSymlinksInPath() != url.resolvingSymlinksInPath(),
           fileManager.fileExists(atPath: old.url.path) {
            throw StoreError.operation("Another package with this machine ID already exists at \(old.url.path).")
        }
        let previous = entries[record.id]
        let bookmark = try? url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
        entries[record.id] = Entry(id: record.id, url: url, bookmark: bookmark)
        do { try saveRegistry() } catch { entries[record.id] = previous; throw error }
    }

    private func loadRegistry() throws {
        guard !registryLoaded else { return }
        if fileManager.fileExists(atPath: registryURL.path) {
            let stored = try PropertyListDecoder().decode([Entry].self, from: Data(contentsOf: registryURL))
            for var entry in stored {
                if let bookmark = entry.bookmark {
                    var stale = false
                    if let resolved = try? URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope, .withoutUI], relativeTo: nil, bookmarkDataIsStale: &stale) {
                        entry.url = resolved.standardizedFileURL
                    }
                }
                guard entries[entry.id] == nil else { throw StoreError.operation("Duplicate ID in Library.plist.") }
                entries[entry.id] = entry
            }
        }
        registryLoaded = true
    }

    private func saveRegistry() throws {
        try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .xml
        try encoder.encode(entries.values.sorted { $0.id.uuidString < $1.id.uuidString }).write(to: registryURL, options: .atomic)
    }

    private func migrateLegacyDirectories(failures: inout [String]) throws {
        guard fileManager.fileExists(atPath: rootURL.path) else { return }
        let defaultRoot = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/VirtManager/Machines", isDirectory: true).standardizedFileURL
        let currentPID = ProcessInfo.processInfo.processIdentifier
        let anotherInstance = NSRunningApplication.runningApplications(withBundleIdentifier: "com.dannielyu.virtmanager")
            .contains(where: { $0.processIdentifier != currentPID })
        let urls = try fileManager.contentsOfDirectory(at: rootURL, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        if rootURL == defaultRoot, anotherInstance,
           urls.contains(where: { UUID(uuidString: $0.lastPathComponent) != nil && fileManager.fileExists(atPath: $0.appendingPathComponent("config.json").path) }) {
            throw StoreError.operation("检测到另一个 VirtManager 实例。请退出旧版本后重启，以安全迁移虚拟机文件包。")
        }
        for source in urls {
            guard let expectedID = UUID(uuidString: source.lastPathComponent) else { continue }
            do {
                let values = try source.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                guard values.isDirectory == true, values.isSymbolicLink != true,
                      source.deletingLastPathComponent().standardizedFileURL == rootURL else { continue }
                let jsonURL = source.appendingPathComponent("config.json")
                guard fileManager.fileExists(atPath: jsonURL.path) else { continue }
                let record = try JSONDecoder().decode(VMRecord.self, from: Data(contentsOf: jsonURL))
                guard record.id == expectedID else { throw StoreError.operation("Legacy directory ID does not match its record.") }
                let target = rootURL.appendingPathComponent(expectedID.uuidString + ".virtvm", isDirectory: true)
                guard !fileManager.fileExists(atPath: target.path) else { throw StoreError.operation("Migration target already exists.") }
                let executionLock = try VMExecutionLock(directory: source)
                defer { withExtendedLifetime(executionLock) {} }
                let disk = source.appendingPathComponent("Disk.img")
                let fd = open(disk.path, O_RDWR | O_NOFOLLOW)
                guard fd >= 0 else { throw StoreError.operation("Cannot lock legacy disk for migration.") }
                defer { close(fd) }
                guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { throw StoreError.operation("Legacy disk is in use; migration deferred.") }
                defer { _ = flock(fd, LOCK_UN) }
                let config = source.appendingPathComponent(VMPackage.configurationFileName)
                if fileManager.fileExists(atPath: config.path) {
                    let existing = try VMPackage.read(from: source)
                    let encoder = PropertyListEncoder()
                    encoder.outputFormat = .xml
                    guard try encoder.encode(existing) == encoder.encode(record) else { throw StoreError.operation("Existing package configuration conflicts with legacy JSON.") }
                } else {
                    try VMPackage.write(record: record, to: source)
                }
                // source and target are verified direct children of root, derived from the matching UUID.
                try fileManager.moveItem(at: source, to: target)
            } catch { failures.append("\(source.lastPathComponent): \(error.localizedDescription)") }
        }
    }

    private func verifyPackageDirectory(_ url: URL) throws {
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard url.isFileURL, url.pathExtension.lowercased() == "virtvm", values.isDirectory == true,
              values.isSymbolicLink != true else { throw StoreError.operation("Select a .virtvm package directory.") }
    }

    private func verifyPackage(_ url: URL, id: UUID) throws {
        try verifyPackageDirectory(url)
        guard try VMPackage.read(from: url).id == id else { throw StoreError.operation("Package identity does not match the registered machine.") }
    }

    private func withAccess<T>(_ url: URL, operation: () throws -> T) rethrows -> T {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        return try operation()
    }

    private func sanitized(_ name: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_ "))
        let text = String(name.unicodeScalars.map { allowed.contains($0) ? Character(String($0)) : "-" }).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? "Machine" : String(text.prefix(80))
    }

    private func validate(_ record: VMRecord) throws {
        guard !record.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw StoreError.operation("Machine name cannot be empty.") }
        guard (1...64).contains(record.cpuCount), (1...1024).contains(record.memoryGiB), (1...16384).contains(record.diskGiB) else { throw StoreError.operation("CPU must be 1–64, memory 1–1024 GiB, and disk 1–16384 GiB.") }
        guard (1...16384).contains(record.displayWidth), (1...16384).contains(record.displayHeight) else { throw StoreError.operation("Display dimensions must be between 1 and 16384 pixels.") }
        if record.kind == .macOS && record.rosettaEnabled { throw StoreError.operation("Rosetta for Linux 仅适用于 ARM64 Linux 客户机。") }
        if record.kind == .macOS && record.sharedDirectoryPath != nil { throw StoreError.operation("Shared directories are unsupported for macOS guests.") }
    }

    public enum StoreError: LocalizedError {
        case notFound
        case operation(String)
        public var errorDescription: String? {
            switch self { case .notFound: return "Machine package not registered."; case .operation(let text): return text }
        }
    }
}
