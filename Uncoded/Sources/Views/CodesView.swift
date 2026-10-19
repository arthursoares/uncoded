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

            if lenses.isEmpty {
                Text("No lenses yet — add your real lenses under “My Lenses” first.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.dim)
            } else {
                List {
                    ForEach(lenses) { lens in
                        Button {
                            assign(lens)
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
                                if existing?.lens === lens {
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
                        if let existing { context.delete(existing) }
                        dismiss()
                    }
                }
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(minWidth: 420, minHeight: 360)
        .background(Theme.bg)
        .preferredColorScheme(.dark)
    }

    private func assign(_ lens: UserLens) {
        Mappings.assign(code: code, to: lens, in: context)
        dismiss()
    }
}
