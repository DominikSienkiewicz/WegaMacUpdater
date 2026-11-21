import Foundation
import Testing
import WegaHelperKit

/// Z14: launchd runs the helper as root from the app bundle, so the app neither registers nor uses
/// it, and the helper serves no one, unless every folder and file launchd runs it from belongs to
/// root and nobody else can change it. These tests pin the pure decision.
@Suite("Helper bundle gate")
struct HelperBundleGateTests {
    private static let bundle = "/Applications/WegaMacUpdater.app"

    private static func sound(_ entry: HelperBundleEntry) -> HelperBundleEntryFacts {
        HelperBundleEntryFacts(
            kind: entry.isDirectory ? .directory : .regularFile,
            ownerUID: 0,
            permissions: entry.isDirectory ? 0o755 : 0o644,
            accessControl: .absent
        )
    }

    private static func trust(
        _ path: String = bundle,
        changing target: HelperBundleEntry? = nil,
        _ change: (inout HelperBundleEntryFacts) -> Void = { _ in }
    ) -> HelperBundleTrust {
        HelperBundleGate.trust(bundlePath: path) { entry in
            var facts = sound(entry)
            if entry == target { change(&facts) }
            return facts
        }
    }

    // MARK: - Where the bundle is

    @Test(arguments: ["/Applications/WegaMacUpdater.app", "/Applications/Wega Mac Updater.app", "/Applications/W.app"])
    func aBundleDirectlyInApplicationsIsAccepted(path: String) {
        #expect(HelperBundleGate.isApplicationsEntry(path))
        #expect(Self.trust(path) == .trusted)
    }

    /// Anything else refuses before a single entry is read: Downloads, a disk image, App Translocation,
    /// `~/Applications`, a folder inside `/Applications`, the Data volume's spelling, another case, a
    /// trailing slash, `.`/`..`/empty components, a NUL, a relative path and a name that is not a bundle.
    @Test(arguments: [
        "/Users/someone/Downloads/WegaMacUpdater.app",
        "/Volumes/WegaMacUpdater/WegaMacUpdater.app",
        "/private/var/folders/xy/abc/T/AppTranslocation/0A1B/d/WegaMacUpdater.app",
        "/Users/someone/Applications/WegaMacUpdater.app",
        "/Applications/Utilities/WegaMacUpdater.app",
        "/System/Volumes/Data/Applications/WegaMacUpdater.app",
        "/applications/WegaMacUpdater.app",
        "/Applications/WegaMacUpdater.app/",
        "/Applications/./WegaMacUpdater.app",
        "/Applications/../Applications/WegaMacUpdater.app",
        "//Applications/WegaMacUpdater.app",
        "/Applications//WegaMacUpdater.app",
        "/Applications/WegaMacUpdater.app\u{0}x",
        "Applications/WegaMacUpdater.app",
        "/Applications/WegaMacUpdater",
        "/Applications/.app",
        "/Applications",
        "/",
        "",
    ])
    func anyOtherLocationIsRefusedBeforeAnythingIsRead(path: String) {
        var read: [HelperBundleEntry] = []

        let trust = HelperBundleGate.trust(bundlePath: path) { entry in
            read.append(entry)
            return Self.sound(entry)
        }

        #expect(!HelperBundleGate.isApplicationsEntry(path))
        #expect(trust == .refused(.notInApplications))
        #expect(read.isEmpty)
    }

    /// The path is split on its UTF-8 bytes, the way the kernel reads it: a `/` followed by a combining
    /// mark is one Swift `Character`, so a split on characters would see one folder fewer.
    @Test func aSlashFusedWithACombiningMarkStillCountsAsAFolder() {
        #expect(!HelperBundleGate.isApplicationsEntry("/Applications/Folder/\u{0301}WegaMacUpdater.app"))
    }

    // MARK: - What each entry must be

    @Test func aSoundBundleIsTrusted() {
        #expect(Self.trust() == .trusted)
    }

    @Test func theEntriesAreEveryPathLaunchdRunsTheHelperFrom() {
        #expect(HelperBundleEntry.allCases.map(\.relativePath) == [
            "",
            "Contents",
            "Contents/MacOS",
            "Contents/MacOS/WegaPrivilegedHelper",
            "Contents/Library",
            "Contents/Library/LaunchDaemons",
            "Contents/Library/LaunchDaemons/\(WegaHelper.plistName)",
        ])
        #expect(HelperBundleEntry.allCases.filter { !$0.isDirectory } == [.helperExecutable, .launchdPlist])
    }

    @Test(arguments: HelperBundleEntry.allCases)
    func anEntryThatIsMissingOrUnreadableIsRefused(entry: HelperBundleEntry) {
        let trust = HelperBundleGate.trust(bundlePath: Self.bundle) { $0 == entry ? nil : Self.sound($0) }

        #expect(trust == .refused(.unreadable(entry)))
    }

    @Test(arguments: HelperBundleEntry.allCases)
    func aSymbolicLinkIsRefusedWhoeverOwnsIt(entry: HelperBundleEntry) {
        let trust = Self.trust(changing: entry) { $0.kind = .symbolicLink; $0.ownerUID = 501; $0.permissions = 0o777 }

        #expect(trust == .refused(.symbolicLink(entry)))
    }

    @Test(arguments: HelperBundleEntry.allCases)
    func anEntryOfTheWrongKindIsRefused(entry: HelperBundleEntry) {
        for kind in [HelperBundleEntryFacts.Kind.directory, .regularFile, .other] where kind != Self.sound(entry).kind {
            let trust = Self.trust(changing: entry) { $0.kind = kind; $0.ownerUID = 501 }

            #expect(trust == .refused(.unexpectedKind(entry)), "\(entry) as \(kind)")
        }
    }

    @Test(arguments: HelperBundleEntry.allCases)
    func anEntryThatDoesNotBelongToRootIsRefused(entry: HelperBundleEntry) {
        for owner: UInt32 in [501, 1, UInt32.max] {
            let trust = Self.trust(changing: entry) { $0.ownerUID = owner; $0.permissions = 0o777 }

            #expect(trust == .refused(.notOwnedByRoot(entry)), "\(entry) owned by \(owner)")
        }
    }

    @Test(arguments: HelperBundleEntry.allCases)
    func anEntryTheGroupOrOthersCanWriteIsRefused(entry: HelperBundleEntry) {
        for permissions: UInt16 in [0o775, 0o757, 0o777, 0o664, 0o646, 0o1777, 0o020, 0o002] {
            let trust = Self.trust(changing: entry) { $0.permissions = permissions; $0.accessControl = .present }

            #expect(trust == .refused(.writableByGroupOrOthers(entry)), "\(entry) \(String(permissions, radix: 8))")
        }
    }

    /// Setuid, setgid, sticky and the owner's own write bit grant nobody but root anything.
    @Test(arguments: HelperBundleEntry.allCases)
    func bitsThatGrantNobodyElseWriteAreAccepted(entry: HelperBundleEntry) {
        for permissions: UInt16 in [0o7755, 0o700, 0o555, 0o000] {
            #expect(Self.trust(changing: entry) { $0.permissions = permissions } == .trusted)
        }
    }

    /// An ACL can give a user write access whatever the mode says; one that cannot be read is no proof.
    @Test(arguments: HelperBundleEntry.allCases)
    func anEntryWithAnACLOrAnUnreadableOneIsRefused(entry: HelperBundleEntry) {
        for state in [PAMAccessControlState.present, .unreadable] {
            let trust = Self.trust(changing: entry) { $0.accessControl = state }

            #expect(trust == .refused(.accessControlList(entry)), "\(entry) \(state)")
        }
    }

    /// Every folder is proven before anything inside it is read, so the live reader never resolves a
    /// name through a folder someone else could change.
    @Test(arguments: HelperBundleEntry.allCases)
    func nothingAfterARefusedEntryIsRead(entry: HelperBundleEntry) {
        var read: [HelperBundleEntry] = []

        let trust = HelperBundleGate.trust(bundlePath: Self.bundle) { asked in
            read.append(asked)
            var facts = Self.sound(asked)
            if asked == entry { facts.ownerUID = 501 }
            return facts
        }

        #expect(trust == .refused(.notOwnedByRoot(entry)))
        #expect(read == Array(HelperBundleEntry.allCases.prefix { $0 != entry }) + [entry])
    }

    @Test func everyFolderIsReadBeforeWhatItHolds() {
        for entry in HelperBundleEntry.allCases {
            guard let parent = entry.parent else {
                #expect(entry == .bundle)
                continue
            }
            let order = HelperBundleEntry.allCases
            #expect(order.firstIndex(of: parent)! < order.firstIndex(of: entry)!, "\(parent) before \(entry)")
            #expect(parent.isDirectory)
        }
    }

    // MARK: - From the helper's own executable to its bundle

    @Test func theHelperFindsItsBundleFromItsExecutable() {
        #expect(HelperBundleGate.bundlePath(ofHelperExecutable: "/Applications/WegaMacUpdater.app/Contents/MacOS/WegaPrivilegedHelper")
            == "/Applications/WegaMacUpdater.app")
        #expect(HelperBundleGate.bundlePath(ofHelperExecutable: "/Users/someone/Downloads/W.app/Contents/MacOS/WegaPrivilegedHelper")
            == "/Users/someone/Downloads/W.app")
    }

    @Test(arguments: [
        "/Applications/WegaMacUpdater.app/Contents/MacOS/WegaMacUpdater",
        "/Applications/WegaMacUpdater.app/Contents/Helpers/WegaPrivilegedHelper",
        "/Contents/MacOS/WegaPrivilegedHelper",
        "Contents/MacOS/WegaPrivilegedHelper",
        "WegaPrivilegedHelper",
        "",
    ])
    func anExecutablePathOfAnyOtherShapeHasNoBundle(path: String) {
        #expect(HelperBundleGate.bundlePath(ofHelperExecutable: path) == nil)
    }
}
