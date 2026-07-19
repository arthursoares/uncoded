import SwiftUI

enum SidebarItem: String, CaseIterable, Identifiable {
    case scan = "Scan"
    case lenses = "My Lenses"
    case codes = "6-Bit Codes"

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .scan: return "viewfinder"
        case .lenses: return "camera.aperture"
        case .codes: return "circle.grid.3x3"
        }
    }
}

struct ContentView: View {
    @State private var selection: SidebarItem? = .scan
    @State private var scanSession = ScanSession()

    var body: some View {
        NavigationSplitView {
            List(SidebarItem.allCases, selection: $selection) { item in
                Label(item.rawValue, systemImage: item.symbol)
                    .tag(item)
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 200)
            .safeAreaInset(edge: .top) {
                HStack(spacing: 8) {
                    Circle().fill(Theme.accent).frame(width: 10, height: 10)
                    Text("UNCODED")
                        .font(.system(size: 13, weight: .bold))
                        .tracking(3)
                        .foregroundStyle(Theme.engraved)
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            }
        } detail: {
            Group {
                switch selection ?? .scan {
                case .scan: ScanView(session: scanSession)
                case .lenses: LensesView()
                case .codes: CodesView()
                }
            }
            .background(Theme.bg)
        }
        .preferredColorScheme(.dark)
    }
}
