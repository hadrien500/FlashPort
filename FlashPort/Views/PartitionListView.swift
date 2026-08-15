import SwiftUI
import UniformTypeIdentifiers

struct PartitionListView: View {
    @Binding var jobs: [FlashJob]
    let onFileSelected: (URL, String) -> Void

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(jobs) { job in
                    HStack {
                        Text(job.partitionName)
                            .frame(width: 140, alignment: .leading)
                            .fontWeight(.medium)
                        Text(job.fileURL?.lastPathComponent ?? "Aucun fichier")
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Spacer()
                        Button("Choisir...") {
                            selectFile(for: job.partitionName)
                        }
                    }
                    .padding(.vertical, 6)

                    Divider()
                }
            }
            .padding(.horizontal, 8)
        }
        .frame(minHeight: 200)
        .background(Color.black.opacity(0.03))
        .cornerRadius(6)
    }

    private func selectFile(for partitionName: String) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.title = "Selectionner l'image pour \(partitionName)"
        if panel.runModal() == .OK, let url = panel.url {
            onFileSelected(url, partitionName)
        }
    }
}
