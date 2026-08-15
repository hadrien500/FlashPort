import SwiftUI
import AppKit

struct LogConsoleView: View {
    let lines: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Journal")
                    .font(.headline)

                Spacer()

                Button {
                    copyLogToPasteboard()
                } label: {
                    Label("Copier", systemImage: "doc.on.doc")
                }
                .disabled(lines.isEmpty)
            }

            ScrollView([.vertical, .horizontal]) {
                Text(logText)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: true, vertical: false)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.black.opacity(0.05))
            .cornerRadius(6)
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private var logText: String {
        lines.joined(separator: "\n")
    }

    private func copyLogToPasteboard() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(logText, forType: .string)
    }
}

#Preview {
    LogConsoleView(lines: [
        "Terminal détecté : Samsung Download Mode (0x685D).",
        "Échec du test Odin : pipes USB bulk IN/OUT introuvables.",
        "Ports série candidats : /dev/cu.usbmodem1101"
    ])
    .padding()
    .frame(width: 640, height: 220)
}
