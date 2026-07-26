import Foundation
import Testing

@testable import WegaHelperKit

/// SEC-03 część 2 — TOCTOU przy `installVerifiedPackage`.
///
/// Helper weryfikował podpis pliku pod ścieżką **podaną przez klienta**, po czym
/// `installer -pkg` czytał tę samą ścieżkę ponownie. Plik leżał w katalogu tymczasowym
/// zapisywalnym przez procesy użytkownika, więc okno między „sprawdź" a „użyj" było lokalną
/// eskalacją do roota: wystarczyło podmienić pakiet po weryfikacji, a przed instalacją.
///
/// Decyzje testowane tutaj są czyste — demon roota jest nieosiągalny dla jakiegokolwiek targetu
/// testowego, więc wszystko, co da się wyjąć z demona, jest z niego wyjęte.
@Suite("SEC-03 root-owned staging")
struct PackageStagingTests {

    // MARK: - Gdzie leży staging

    @Test func stagingLivesUnderApplicationSupportForTheBundle() {
        let directory = PackageStaging.directory(bundleID: "com.wega.WegaMacUpdater")

        #expect(directory.path == "/Library/Application Support/com.wega.WegaMacUpdater/staging")
    }

    /// Wolumen systemowy, ten sam co `/Applications` — inaczej podmiana przestaje być atomowa.
    @Test func stagingSitsOnTheSystemVolume() {
        #expect(PackageStaging.directory(bundleID: "com.example.app").path.hasPrefix("/Library/"))
    }

    // MARK: - Kto jest właścicielem stagingu

    @Test func aStagingOwnedByRootWithPrivatePermissionsIsAccepted() {
        #expect(PackageStaging.rejection(ownerUID: 0, permissions: 0o700) == nil)
    }

    /// Cały sens stagingu: katalog, do którego użytkownik nie może pisać. Właściciel inny niż
    /// root znaczy, że okno TOCTOU nadal istnieje, tylko przeniesione w inne miejsce.
    @Test func aStagingOwnedByAUserIsRejected() {
        #expect(PackageStaging.rejection(ownerUID: 501, permissions: 0o700) == .notOwnedByRoot)
    }

    @Test func aWorldOrGroupWritableStagingIsRejected() {
        #expect(PackageStaging.rejection(ownerUID: 0, permissions: 0o755) == .permissionsTooOpen)
        #expect(PackageStaging.rejection(ownerUID: 0, permissions: 0o770) == .permissionsTooOpen)
        #expect(PackageStaging.rejection(ownerUID: 0, permissions: 0o777) == .permissionsTooOpen)
    }

    /// Prawa węższe niż 0700 nie są zagrożeniem — odrzucamy tylko to, co za szerokie.
    @Test func aStricterStagingIsAccepted() {
        #expect(PackageStaging.rejection(ownerUID: 0, permissions: 0o500) == nil)
    }

    // MARK: - Ten sam plik przy weryfikacji i przy instalacji

    @Test func anUnchangedArtifactIsAccepted() {
        let identity = PackageStaging.ArtifactIdentity(device: 16_777_233, inode: 4_242)

        #expect(PackageStaging.rejection(verified: identity, installing: identity) == nil)
    }

    /// Sedno TOCTOU: podmiana pliku między weryfikacją a instalacją zmienia inode, nawet gdy
    /// ścieżka zostaje ta sama.
    @Test func anArtifactSwappedAfterVerificationIsRejected() {
        let verified = PackageStaging.ArtifactIdentity(device: 16_777_233, inode: 4_242)
        let swapped = PackageStaging.ArtifactIdentity(device: 16_777_233, inode: 9_999)

        #expect(PackageStaging.rejection(verified: verified, installing: swapped) == .identityChanged)
    }

    /// Ten sam numer inode na innym wolumenie to inny plik — dlatego porównujemy parę
    /// (device, inode), a nie sam inode.
    @Test func anArtifactOnADifferentVolumeIsRejected() {
        let verified = PackageStaging.ArtifactIdentity(device: 16_777_233, inode: 4_242)
        let elsewhere = PackageStaging.ArtifactIdentity(device: 16_777_999, inode: 4_242)

        #expect(PackageStaging.rejection(verified: verified, installing: elsewhere) == .identityChanged)
    }

    // MARK: - Instalowana jest kopia, nie ścieżka od klienta

    @Test func aPathInsideTheStagingDirectoryIsAccepted() {
        #expect(
            PackageStaging.rejectionForInstallPath(
                "/Library/Application Support/com.wega.WegaMacUpdater/staging/update.pkg",
                bundleID: "com.wega.WegaMacUpdater"
            ) == nil
        )
    }

    /// Ścieżka od klienta prowadzi do katalogu zapisywalnego przez użytkownika — helper nie
    /// może jej podać `installer`owi, choćby przed chwilą zweryfikował podpis.
    @Test func theClientSuppliedTemporaryPathIsRejected() {
        #expect(
            PackageStaging.rejectionForInstallPath(
                "/var/folders/m9/T/WegaUpdate.pkg",
                bundleID: "com.wega.WegaMacUpdater"
            ) == .outsideStaging
        )
    }

    /// Traversal wychodzący ze stagingu — ta sama klasa błędu, którą część 1 zamknęła
    /// w `replaceBundle`, tu nie może wrócić tylnymi drzwiami.
    @Test func aTraversalEscapingTheStagingIsRejected() {
        #expect(
            PackageStaging.rejectionForInstallPath(
                "/Library/Application Support/com.wega.WegaMacUpdater/staging/../../../../tmp/evil.pkg",
                bundleID: "com.wega.WegaMacUpdater"
            ) == .outsideStaging
        )
    }

    /// Staging innego bundla to nie nasz staging.
    @Test func anotherBundlesStagingIsRejected() {
        #expect(
            PackageStaging.rejectionForInstallPath(
                "/Library/Application Support/com.evil.other/staging/update.pkg",
                bundleID: "com.wega.WegaMacUpdater"
            ) == .outsideStaging
        )
    }
}
