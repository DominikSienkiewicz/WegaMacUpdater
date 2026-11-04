import Foundation

/// Test double for injected settings stores. Native getters retain Foundation's conversions;
/// overridden setters use instance-owned values so no write reaches the preferences daemon.
/// This is not a fixture for registration domains, persistent domains, cross-process access or KVO.
final class EphemeralUserDefaults: UserDefaults {
    private let mutationLock = NSLock()
    private var values: [String: Any] = [:]

    override func set(_ value: Any?, forKey defaultName: String) {
        let snapshot = value.map(Self.propertyListSnapshot)
        mutationLock.withLock {
            values[defaultName] = snapshot
        }
    }

    override func object(forKey defaultName: String) -> Any? {
        mutationLock.withLock { values[defaultName] }
    }

    override func dictionaryRepresentation() -> [String: Any] {
        mutationLock.withLock { values }
    }

    override func removeObject(forKey defaultName: String) {
        set(nil as Any?, forKey: defaultName)
    }

    override func set(_ value: Int, forKey defaultName: String) {
        set(NSNumber(value: value), forKey: defaultName)
    }

    override func set(_ value: Float, forKey defaultName: String) {
        set(NSNumber(value: value), forKey: defaultName)
    }

    override func set(_ value: Double, forKey defaultName: String) {
        set(NSNumber(value: value), forKey: defaultName)
    }

    override func set(_ value: Bool, forKey defaultName: String) {
        set(NSNumber(value: value), forKey: defaultName)
    }

    override func set(_ url: URL?, forKey defaultName: String) {
        guard let url else {
            removeObject(forKey: defaultName)
            return
        }
        if url.isFileURL {
            set((url.path as NSString).abbreviatingWithTildeInPath, forKey: defaultName)
        } else {
            do {
                let data = try NSKeyedArchiver.archivedData(withRootObject: url, requiringSecureCoding: true)
                set(data, forKey: defaultName)
            } catch {
                preconditionFailure("Unable to encode test URL")
            }
        }
    }

    func clear() {
        mutationLock.withLock {
            values.removeAll()
        }
    }

    private static func propertyListSnapshot(_ value: Any) -> Any {
        do {
            let data = try PropertyListSerialization.data(fromPropertyList: value, format: .binary, options: 0)
            return try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
        } catch {
            preconditionFailure("Test defaults require property-list values")
        }
    }
}
