import SwiftUI
import SwiftData

struct CodeSelection: Identifiable {
    let code: String
    var id: String { code }
}

/// Every 6-bit code a Leica M lens wears, drawn as its flange pit pattern,
/// with the user's mapping (borrowed code -> real lens) shown in place.
struct CodesView: View {
    @Query private var mappings: [CodeMapping]
    @State private var search = ""
    @State private var codeToMap: CodeSelection?

    private var mappingByCode: [String: CodeMapping] {
        Dictionary(mappings.map { ($0.code, $0) }, uniquingKeysWith: { a, _ in a })
    }

    private var filteredCodes: [String] {
        guard !search.isEmpty else { return SixBitTable.uniqueCodes }
        return SixBitTable.uniqueCodes.filter { code in
            let entries = SixBitTable.byCode[code] ?? []
            return Search.matches(search, in: [code] + entries.map(\.lensName)
                + entries.flatMap(\.productCodes))
        }
    }

    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), spacing: 12)], spacing: 12) {
                ForEach(filteredCodes, id: \.self) { code in
                    CodeCard(code: code,
                             entries: SixBitTable.byCode[code] ?? [],
                             mapping: mappingByCode[code])
                        .onTapGesture { codeToMap = CodeSelection(code: code) }
                }
            }
            .padding(16)
        }
        .background(Theme.bg)
        .searchable(text: $search, prompt: "Code, lens, or product number")
        .navigationTitle("6-Bit Codes")
        .sheet(item: $codeToMap) { selection in
            MapCodeSheet(code: selection.code, existing: mappingByCode[selection.code])
        }
    }
}

private struct CodeCard: View {
    let code: String
    let entries: [SixBitCode]
    let mapping: CodeMapping?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(code)
                    .font(Theme.code())
                    .foregroundStyle(Theme.engraved)
                Spacer()
                BitPatternView(code: code)
            }

            VStack(alignment: .leading, spacing: 2) {
                ForEach(entries.prefix(3)) { entry in
                    Text(entry.lensName)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.dim)
                        .lineLimit(1)
                }
                if entries.count > 3 {
                    Text("+ \(entries.count - 3) more")
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.faint)
                }
            }

            Divider().overlay(Theme.panelEdge)

            if let lens = mapping?.lens {
                HStack(spacing: 6) {
                    Circle().fill(Theme.accent).frame(width: 6, height: 6)
                    Text(lens.name)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Theme.engraved)
                        .lineLimit(1)
                }
            } else {
                EngravedLabel("unmapped", color: Theme.faint)
            }
        }
        .instrumentCard(highlighted: mapping?.lens != nil)
        .contentShape(Rectangle())
    }
}

/// Assigns (or clears) the user's real lens for a borrowed code.
/// Also presented from the Scan tab when an unclaimed code is detected.
struct MapCodeSheet: View {
    let code: String
    let existing: CodeMapping?

    @Query(sort: \UserLens.name) private var lenses: [UserLens]
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @State private var selection: UserLens?
    @State private var pendingTransfer: MappingTransferRequest?
    @State private var showTransferConfirmation = false
    @State private var ownershipChangedMessage: String?

    init(code: String, existing: CodeMapping?) {
        self.code = code
        self.existing = existing
        _selection = State(initialValue: existing?.lens)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 6) {
                    EngravedLabel("map code")
                    HStack(spacing: 12) {
                        Text(code).font(Theme.code(28)).foregroundStyle(Theme.engraved)
                        BitPatternView(code: code, dotSize: 11)
                    }
                }
                Spacer()
            }

            Text("Use this lens for all photos with code \(code), including future scans. Individual photo assignments take priority.")
                .font(.system(size: 11))
                .foregroundStyle(Theme.dim)
                .fixedSize(horizontal: false, vertical: true)

            if lenses.isEmpty {
                Text("No lenses yet — add your real lenses under “My Lenses” first.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.dim)
            } else {
                List {
                    ForEach(lenses) { lens in
                        Button {
                            selection = lens
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(lens.name)
                                        .font(.system(size: 12, weight: .medium))
                                        .foregroundStyle(Theme.engraved)
                                    Text("\(lens.focalLength)  \(lens.aperture)")
                                        .font(Theme.mono(10))
                                        .foregroundStyle(Theme.dim)
                                }
                                Spacer()
                                if selection?.persistentModelID == lens.persistentModelID {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(Theme.accent)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .scrollContentBackground(.hidden)
            }

            HStack {
                if existing != nil {
                    Button("Clear Mapping", role: .destructive) {
                        if let existing { Mappings.remove(existing, in: context) }
                        dismiss()
                    }
                }
                Spacer()
                if let ownershipChangedMessage {
                    Text(ownershipChangedMessage)
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.accent)
                }
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save Mapping") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(selection == nil)
            }
        }
        .padding(20)
        .frame(minWidth: 420, minHeight: 360)
        .background(Theme.bg)
        .preferredColorScheme(.dark)
        .alert("Transfer 6-Bit Code?", isPresented: $showTransferConfirmation,
               presenting: pendingTransfer) { transfer in
            Button("Cancel", role: .cancel) {}
            Button("Transfer Code", role: .destructive) {
                save(confirming: transfer)
            }
        } message: { transfer in
            Text("Code \(transfer.code) currently belongs to “\(transfer.oldOwnerName)”. Transfer it to “\(transfer.newOwnerName)”?" )
        }
    }

    private func save(confirming confirmation: MappingTransferRequest? = nil) {
        guard let lens = selection else { return }
        let authorization: MappingAuthorization
        do {
            authorization = try Mappings.authorization(
                for: code, newOwnerName: lens.name, currentLens: lens,
                confirming: confirmation, in: context
            )
        } catch {
            ownershipChangedMessage = "Couldn’t verify code ownership. No changes were made. Try again."
            return
        }
        switch authorization {
        case .allowed:
            ownershipChangedMessage = nil
            break
        case .confirmationRequired(let transfer):
            if confirmation != nil {
                pendingTransfer = nil
                ownershipChangedMessage = "Ownership changed to \(transfer.oldOwnerName). Choose Save Mapping again to review the transfer."
                return
            }
            ownershipChangedMessage = nil
            pendingTransfer = transfer
            showTransferConfirmation = true
            return
        }
        do {
            try Mappings.assign(code: code, to: lens, in: context)
        } catch {
            ownershipChangedMessage = "Couldn’t save the code mapping. No changes were made. Try again."
            return
        }
        dismiss()
    }
}
