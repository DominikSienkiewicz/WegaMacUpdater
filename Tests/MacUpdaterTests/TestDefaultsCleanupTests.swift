import Foundation
import Testing
import WegaTestSupport

struct TestDefaultsCleanupTests {
    @Test func isolatedDefaultsNeverCreatePersistentFiles() throws {
        let label = "cleanup-regression-\(UUID().uuidString)"
        let (defaults, teardown) = TestDefaults.isolated(label)
        defer { teardown() }
        defaults.set("fixture", forKey: "cleanup-value")
        #expect(defaults.synchronize())

        try expectNoFiles(label: label)
        teardown()
        #expect(defaults.object(forKey: "cleanup-value") == nil)
        #expect(defaults.synchronize())
        try expectNoFiles(label: label)
    }

    @Test func isolatedDefaultsRetainFoundationValueConversions() throws {
        let label = "cleanup-value-types-\(UUID().uuidString)"
        let (defaults, teardown) = TestDefaults.isolated(label)
        defer { teardown() }
        let data = Data([1, 2, 3])
        let date = Date(timeIntervalSince1970: 123)
        let fileURL = URL(fileURLWithPath: "/tmp/wega-test-fixture")
        let webURL = try #require(URL(string: "https://example.invalid/test?q=value"))

        defaults.set("value", forKey: "string")
        defaults.set(true, forKey: "bool")
        defaults.set(42, forKey: "integer")
        defaults.set(Float(1.25), forKey: "float")
        defaults.set(2.5, forKey: "double")
        defaults.set(data, forKey: "data")
        defaults.set(date, forKey: "date")
        defaults.set(["one", "two"], forKey: "array")
        defaults.set(["key": "value"], forKey: "dictionary")
        defaults.set(fileURL, forKey: "file-url")
        defaults.set(webURL, forKey: "web-url")

        #expect(defaults.string(forKey: "string") == "value")
        #expect(defaults.bool(forKey: "bool"))
        #expect(defaults.integer(forKey: "integer") == 42)
        #expect(defaults.float(forKey: "float") == 1.25)
        #expect(defaults.double(forKey: "double") == 2.5)
        #expect(defaults.data(forKey: "data") == data)
        #expect(defaults.object(forKey: "date") as? Date == date)
        #expect(defaults.stringArray(forKey: "array") == ["one", "two"])
        #expect(defaults.dictionary(forKey: "dictionary") as? [String: String] == ["key": "value"])
        #expect(defaults.url(forKey: "file-url") == fileURL)
        #expect(defaults.url(forKey: "web-url") == webURL)
        #expect(defaults.dictionaryRepresentation()["string"] as? String == "value")
        #expect(defaults.synchronize())
        try expectNoFiles(label: label)
    }

    @Test func teardownClearsOnlyItsOwnValuesAndIsRepeatable() {
        let (first, clearFirst) = TestDefaults.isolated("cleanup-isolation")
        let (second, clearSecond) = TestDefaults.isolated("cleanup-isolation")
        defer { clearFirst(); clearSecond() }
        first.set("first", forKey: "shared-key")
        second.set("second", forKey: "shared-key")

        #expect(first.string(forKey: "shared-key") == "first")
        #expect(second.string(forKey: "shared-key") == "second")
        clearFirst()
        clearFirst()
        #expect(first.object(forKey: "shared-key") == nil)
        #expect(second.string(forKey: "shared-key") == "second")

        second.removeObject(forKey: "shared-key")
        #expect(second.object(forKey: "shared-key") == nil)
        second.set("replacement", forKey: "shared-key")
        second.set(nil as Any?, forKey: "shared-key")
        #expect(second.object(forKey: "shared-key") == nil)
    }

    @Test func isolatedWritesDoNotChangeStandardDefaults() {
        let (defaults, teardown) = TestDefaults.isolated("cleanup-standard-isolation")
        defer { teardown() }
        let key = "cleanup-\(UUID().uuidString)"
        defaults.set("fixture", forKey: key)
        #expect(UserDefaults.standard.object(forKey: key) == nil)
        teardown()
        #expect(UserDefaults.standard.object(forKey: key) == nil)
    }

    @Test func writesCopyMutablePropertyListValues() {
        let (defaults, teardown) = TestDefaults.isolated("cleanup-copy-values")
        defer { teardown() }
        let array = NSMutableArray(array: ["original"])
        let data = NSMutableData(data: Data([1, 2, 3]))
        let dictionary = NSMutableDictionary(dictionary: ["array": array, "data": data])
        defaults.set(dictionary, forKey: "snapshot")

        array.add("changed")
        data.append(Data([4]))
        dictionary["extra"] = "changed"

        let snapshot = defaults.dictionary(forKey: "snapshot")
        #expect(snapshot?["array"] as? [String] == ["original"])
        #expect(snapshot?["data"] as? Data == Data([1, 2, 3]))
        #expect(snapshot?["extra"] == nil)
    }

    private func expectNoFiles(label: String) throws {
        let directory = try #require(FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first)
            .appendingPathComponent("Preferences", isDirectory: true)
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("\(TestDefaults.suitePrefix).\(label).") }
        #expect(files.isEmpty, "Test settings must stay in memory so cfprefsd cannot recreate a plist after teardown")
    }
}
