import SwiftUI

struct DeviceStatusView: View {
    let isConnected: Bool
    let deviceDescription: String?
    let onRefresh: () -> Void

    var body: some View {
        HStack {
            Circle()
                .fill(isConnected ? Color.green : Color.red)
                .frame(width: 10, height: 10)
            VStack(alignment: .leading, spacing: 2) {
                Text(isConnected ? "Terminal en mode Download détecté" : "Aucun terminal détecté")
                if let deviceDescription {
                    Text(deviceDescription)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button("Actualiser", action: onRefresh)
        }
    }
}
