import AppKit
import GitSyncCore
import SwiftUI

/// Shown when a hook such as pre-commit rejects a commit, with everything the hook printed.
struct HookOutputSheet: View {
    let failure: HookFailedError
    let commitWithoutHooks: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("The \(failure.hook) hook stopped the commit", systemImage: "exclamationmark.octagon.fill")
                .font(.system(size: 17, weight: .semibold, design: .rounded)).foregroundStyle(.red)
            Text("Fix what it reports, stage the changes and commit again. Your message is kept.")
                .font(.callout).foregroundStyle(.secondary)
            ScrollView {
                Text(failure.output)
                    .font(.system(size: 12, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            }
            .frame(height: 260)
            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            HStack {
                Button("Copy Output") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(failure.output, forType: .string)
                }
                Button("Commit Without Hooks") { dismiss(); commitWithoutHooks() }
                    .help("Runs git commit --no-verify")
                Spacer()
                Button("Close") { dismiss() }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            }
        }
        .padding(22).frame(width: 560)
    }
}
