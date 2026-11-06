import NextTypedCore
import SwiftUI

/// "What NextTyped has learned from you" — the transparency half of an **encrypted**
/// store.
///
/// The alternative was a plaintext file the user could open in any editor (radical transparency, no
/// encryption). This gives both: the profile stays encrypted at rest, and everything in it is legible
/// here — the sentences verbatim, the characteristic terms ranked. Which also means the honesty of the
/// Privacy-pane claims is checkable rather than promised: if a quoted reply or a pasted paragraph ever
/// showed up in this list, the own-inserted capture invariant would be visibly broken.
struct LearnedProfileView: View {
    @EnvironmentObject private var coordinator: AppCoordinator
    let onClose: () -> Void

    @State private var profile: StyleProfile?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "text.book.closed")
                    .font(.largeTitle).foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text("What NextTyped has learned").font(.title3.weight(.semibold))
                    Text(subtitle).font(.subheadline).foregroundStyle(.secondary)
                }
            }

            // This list is the transparency promise. Listing sentences that will not survive
            // the quit without saying so breaks it more quietly than not listing them at all
            // , so the warning sits above the content it qualifies.
            if coordinator.learnedProfileIsUnreadable {
                ProfileNotSavingNotice(title: "None of this is being saved")
            }

            if let profile, !profile.exemplars.isEmpty || !profile.terms.isEmpty {
                content(profile)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Nothing yet.").fontWeight(.medium)
                    Text("Sentences you type are learned when you move to another field or window, and "
                         + "only from apps where learning is on.")
                    .font(.subheadline).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 20)
            }

            HStack {
                Spacer()
                Button("Done", action: onClose).keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 520, height: 520)
        .task { profile = await coordinator.learnedProfile() }
    }

    private var subtitle: String {
        guard let profile else { return "Reading the encrypted profile…" }
        return "\(profile.exemplars.count) sentences · \(profile.terms.count) words and phrases"
    }

    private func content(_ profile: StyleProfile) -> some View {
        List {
            Section("Your sentences") {
                // Newest first — that is the voice the retrieval weights highest.
                ForEach(Array(profile.exemplars.reversed().enumerated()), id: \.offset) { _, exemplar in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(exemplar.text)
                            .fixedSize(horizontal: false, vertical: true)
                        if let language = exemplar.language {
                            Text(language).font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            Section("Words and phrases you use") {
                Text(profile.characteristicTerms.prefix(80).joined(separator: " · "))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .listStyle(.inset)
    }
}
