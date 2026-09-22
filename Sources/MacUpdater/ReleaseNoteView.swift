import MacUpdaterCore
import SwiftUI

/// One release's notes: its version, then its body.
///
/// The row and the inspector show the same thing at different sizes, so only the body font
/// varies. Keeping it one view is what stops a change to how a release reads from having to
/// be made twice and being made once.
///
/// `note.body` arrived plain — `ReleaseNotes` is sanitised in Core, at the source that
/// produced it — so nothing here strips markup (UX-05).
struct ReleaseNoteView: View {
    let note: ReleaseNote
    var bodyFont: Font

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            // A version is missing only for notes decoded from the pre-`ReleaseNotes`
            // snapshot shape, which recorded none. Better no heading than an empty one.
            if !note.version.isEmpty {
                Text(note.version)
                    .font(.wega(.subheadline, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            Text(note.body)
                .font(bodyFont)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
