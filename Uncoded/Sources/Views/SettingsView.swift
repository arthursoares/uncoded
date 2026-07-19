import SwiftUI

struct SettingsView: View {
    @AppStorage("keepBakBackups") private var keepBak = true

    var body: some View {
        Form {
            Toggle("Keep .bak backup copies", isOn: $keepBak)
            Text("Before fixing a file, a one-time sibling copy (photo.dng.bak) is kept. Independent of backups, every fix records an undo journal that can restore the file byte-for-byte.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            LabeledContent("Undo journals") {
                Text(JournalStore.directory.path)
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
            }
        }
        .padding(20)
        .frame(width: 480)
    }
}
