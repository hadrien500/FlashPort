import SwiftUI

struct PitSummaryView: View {
    let entries: [PitEntry]

    var body: some View {
        if !entries.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("Table de partitions détectée : \(entries.count) partitions")
                    .font(.headline)

                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(entries) { entry in
                            HStack(spacing: 12) {
                                Text(entry.partitionName)
                                    .fontWeight(.medium)
                                    .frame(width: 140, alignment: .leading)

                                Text(entry.flashFilename.isEmpty ? "-" : entry.flashFilename)
                                    .foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)

                                Text("\(entry.blockCount) blocs")
                                    .foregroundStyle(.secondary)
                                    .frame(width: 90, alignment: .trailing)
                            }
                            .font(.caption)
                            .padding(.vertical, 5)

                            Divider()
                        }
                    }
                    .padding(.horizontal, 8)
                }
                .frame(minHeight: 120, idealHeight: 150, maxHeight: 170)
                .background(Color.black.opacity(0.04))
                .cornerRadius(6)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

#Preview {
    PitSummaryView(entries: [
        PitEntry(
            binaryType: 0,
            deviceType: 2,
            identifier: 80,
            attributes: 2,
            updateAttributes: 1,
            blockSizeOrOffset: 0,
            blockCount: 1734,
            fileOffset: 0,
            fileSize: 0,
            partitionName: "BOOTLOADER",
            flashFilename: "sboot.bin",
            fotaFilename: ""
        )
    ])
    .padding()
    .frame(width: 560, height: 220)
}
