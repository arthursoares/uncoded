import SwiftUI

/// Custom About window: what the app is, and the shoulders it stands on.
struct AboutView: View {
    private var version: String {
        let short = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String
        return build.map { "\(short) (\($0))" } ?? short
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 10) {
                // Six hollow pits: the uncoded lens this app exists for.
                BitPatternView(code: "000000", dotSize: 11)
                    .padding(.top, 28)

                Text("UNCODED")
                    .font(.system(size: 18, weight: .bold))
                    .tracking(5)
                    .foregroundStyle(Theme.engraved)

                Text("Truthful lens metadata for Leica M shooters.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.dim)

                Text("Version \(version)")
                    .font(Theme.mono(10))
                    .foregroundStyle(Theme.faint)
            }
            .padding(.bottom, 20)

            Divider().overlay(Theme.panelEdge)

            VStack(alignment: .leading, spacing: 14) {
                EngravedLabel("credits")

                credit("Leica M 6-bit lens code table",
                       detail: "based on the community-maintained spreadsheet of lens codes",
                       url: "https://docs.google.com/spreadsheets/d/1Bx9L8IqhiQOc-jbGNaWn4rV-HRmf_zMHyHuLRkiO_FY/edit")

                credit("fix_6bit_exif",
                       detail: "the command-line ancestor of this app",
                       url: "https://github.com/arthursoares/fix_6bit_exif")

                credit("ExifTool by Phil Harvey",
                       detail: "the reference against which Uncoded's native metadata engine is validated",
                       url: "https://exiftool.org")

                credit("Adobe lens correction profiles",
                       detail: "read from your local Lightroom / Camera Raw installation",
                       url: nil)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)

            Divider().overlay(Theme.panelEdge)

            VStack(spacing: 4) {
                Text("© 2026 Arthur Soares")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.dim)
                Text("Not affiliated with Leica Camera AG or Adobe Inc.\nLeica is a trademark of Leica Camera AG. Lightroom and Camera Raw are trademarks of Adobe Inc.")
                    .multilineTextAlignment(.center)
                    .font(.system(size: 9))
                    .foregroundStyle(Theme.faint)
            }
            .padding(.vertical, 14)
        }
        .frame(width: 440)
        .background(Theme.bg)
        .preferredColorScheme(.dark)
    }

    @ViewBuilder
    private func credit(_ title: String, detail: String, url: String?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            if let url, let destination = URL(string: url) {
                Link(title, destination: destination)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.engraved)
            } else {
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.engraved)
            }
            Text(detail)
                .font(.system(size: 10))
                .foregroundStyle(Theme.dim)
        }
    }
}
