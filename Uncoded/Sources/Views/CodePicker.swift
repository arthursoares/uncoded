import SwiftUI

/// Searchable 6-bit code list, ranked so the most plausible borrowed code for
/// the lens described by `suggestionSeed` appears first.
struct CodePickerList: View {
    var suggestionSeed: String
    @Binding var selection: String?
    @State private var search = ""

    private var ranked: [String] {
        let codes = SixBitTable.ranked(for: LensNameParser.parse(suggestionSeed))
        guard !search.isEmpty else { return codes }
        let q = search.lowercased()
        return codes.filter { code in
            code.contains(q) || (SixBitTable.byCode[code] ?? []).contains {
                $0.lensName.lowercased().contains(q)
            }
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
                        Text(entries.first?.lensName ?? "")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.dim)
                            .fixedSize(horizontal: false, vertical: true)
                        if entries.count > 1 {
                            Text("+ \(entries.count - 1) generation\(entries.count > 2 ? "s" : "")")
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
