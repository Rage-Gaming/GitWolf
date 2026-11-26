import AppKit
import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings()
                .tabItem { Label("General", systemImage: "gearshape") }
            GitSettings()
                .tabItem { Label("Git", systemImage: "arrow.triangle.branch") }
        }
        .frame(width: 480, height: 300)
        .tint(Theme.brand)
    }
}

private struct GeneralSettings: View {
    @AppStorage(SettingsKey.appearance) private var appearance = AppearanceChoice.system.rawValue
    @AppStorage(SettingsKey.autoFetchMinutes) private var autoFetch = 5
    @AppStorage(SettingsKey.commitPageSize) private var pageSize = 1000
    @AppStorage(SettingsKey.diffContext) private var context = 4

    var body: some View {
        Form {
            Picker("Appearance", selection: $appearance) {
                ForEach(AppearanceChoice.allCases) { Text($0.title).tag($0.rawValue) }
            }
            .pickerStyle(.segmented)

            Picker("Fetch in background", selection: $autoFetch) {
                Text("Never").tag(0)
                Text("Every minute").tag(1)
                Text("Every 5 minutes").tag(5)
                Text("Every 15 minutes").tag(15)
                Text("Every 30 minutes").tag(30)
            }

            Picker("Commits per page", selection: $pageSize) {
                Text("500").tag(500)
                Text("1,000").tag(1000)
                Text("2,000").tag(2000)
                Text("5,000").tag(5000)
            }

            Picker("Diff context lines", selection: $context) {
                ForEach([1, 3, 4, 6, 10], id: \.self) { Text("\($0)").tag($0) }
            }
        }
        .formStyle(.grouped)
    }
}

private struct GitSettings: View {
    @AppStorage(SettingsKey.gitPath) private var gitPath = ""

    private var resolved: String { AppSettings.shared.gitPath }
    private var isValid: Bool {
        gitPath.trimmingCharacters(in: .whitespaces).isEmpty
            || FileManager.default.isExecutableFile(atPath: gitPath)
    }

    var body: some View {
        Form {
            Section {
                HStack {
                    TextField("Git executable", text: $gitPath, prompt: Text(AppSettings.defaultGitPath))
                        .textFieldStyle(.roundedBorder)
                    Button("Choose…", action: choose)
                    if !gitPath.isEmpty { Button("Reset") { gitPath = "" } }
                }
                if isValid {
                    Label("Using \(resolved)", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.secondary).font(.callout)
                } else {
                    Label("Not an executable file — falling back to \(AppSettings.defaultGitPath)",
                          systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange).font(.callout)
                }
            } footer: {
                Text("Leave empty to use the system Git. Set this to use a Homebrew or custom build.")
            }
        }
        .formStyle(.grouped)
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.prompt = "Choose"
        if panel.runModal() == .OK, let url = panel.url { gitPath = url.path }
    }
}
