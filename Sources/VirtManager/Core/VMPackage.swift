import Foundation

public enum VMPackage {
    public static let configurationFileName = "config.plist"

    public static func read(from directory: URL) throws -> VMRecord {
        try PropertyListDecoder().decode(VMRecord.self, from: Data(contentsOf: directory.appendingPathComponent(configurationFileName)))
    }

    public static func write(record: VMRecord, to directory: URL) throws {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .xml
        try encoder.encode(record).write(to: directory.appendingPathComponent(configurationFileName), options: .atomic)
    }
}
