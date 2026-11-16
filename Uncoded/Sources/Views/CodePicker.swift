import SwiftUI
import SwiftData

/// Searchable 6-bit code list, ranked so the most plausible borrowed code for
/// the lens described by `suggestionSeed` appears first.
struct CodePickerList: View {
    @Query private var mappings: [CodeMapping]
    var suggestionSeed: String
    @Binding var selection: String?
    /// Called when the user explicitly clicks a code (as opposed to the
    /// selection being set programmatically by a suggestion).
    var onUserSelect: (() -> Void)? = nil
    /// Codes to list even when no Leica lens wears them — a lens mapped to a
    /// placeholder slot in an older version must stay visible and re-pickable.
    var extraCodes: [String] = []
    @State private var search = ""

    private var ownerByCode: [String: String] {
        Dictionary(mappings.compactMap { mapping in
            mapping.lens.map { (mapping.code, $0.name) }
        }, uniquingKeysWith: { first, _ in first })
    }

    private var ranked: [String] {
        var codes = SixBitTable.ranked(for: LensNameParser.parse(suggestionSeed))
        codes += extraCodes.filter { !codes.contains($0) }
        guard !search.isEmpty else { return codes }
        return codes.filter { code in
            Search.matches(search, in: [code] + (SixBitTable.byCode[code] ?? []).map(\.lensName))
        }
    }

    private var hasSuggestion: Bool {
        search.isEmpty && LensNameParser.parse(suggestionSeed) != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Filter codes or Leica lens names…", text: $search)
                .textFieldStyle(.roundedBorder)

            List(Array(ranked.enumerated()), id: \.element) { index, code in
                let entries = SixBitTable.byCode[code] ?? []
                Button {
                    selection = selection == code ? nil : code
                    onUserSelect?()
                } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 10) {
                            BitPatternView(code: code, dotSize: 8)
                            Text(code)
                                .font(Theme.mono(11))
                                .foregroundStyle(Theme.engraved)
                            Spacer()
                            if index == 0 && hasSuggestion && selection != code {
                                EngravedLabel("suggested", color: Theme.faint)
                            }
                            if selection == code {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(Theme.accent)
                            }
                        }
                        Text(entries.first?.lensName ?? "no Leica lens wears this code")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.dim)
                            .fixedSize(horizontal: false, vertical: true)
                        if let owner = ownerByCode[code] {
                            Text("Owned by \(owner)")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(Theme.accent)
                                .lineLimit(1)
                        } else {
                            Text("Unassigned")
                                .font(.system(size: 10))
                                .foregroundStyle(Theme.faint)
                        }
                        if entries.count > 1 {
                            Text("+ \(entries.count - 1) more")
                                .font(.system(size: 9))
                                .foregroundStyle(Theme.faint)
                        }
                    }
                    .padding(.vertical, 2)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .listRowSeparatorTint(Theme.panelEdge)
            }
            .scrollContentBackground(.hidden)
        }
    }
}
