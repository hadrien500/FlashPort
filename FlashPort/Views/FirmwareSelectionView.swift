import SwiftUI
import UniformTypeIdentifiers

struct FirmwareSelectionView: View {
    let archiveForSlot: (FirmwareSlot) -> FirmwareArchive?
    let mappings: [FirmwareMapping]
    let unmatchedEntries: [FirmwareUnmatchedEntry]
    let selectedMappingIDs: Set<String>
    let selectionWarnings: [String]
    let warnings: [String]
    let errors: [String]
    let mappingSourceName: String
    let hasMappingSource: Bool
    let onMappingSelectionChanged: (String, Bool) -> Void
    let onRecommendedSelectionRequested: () -> Void
    let onSmallCscSelectionRequested: () -> Void
    let onSelectionCleared: () -> Void
    let onArchiveSelected: (URL, FirmwareSlot) -> Void
    let onArchiveRemoved: (FirmwareSlot) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Archives firmware")
                .font(.headline)

            VStack(spacing: 0) {
                ForEach(FirmwareSlot.allCases) { slot in
                    firmwareRow(for: slot)

                    if slot != FirmwareSlot.allCases.last {
                        Divider()
                    }
                }
            }
            .padding(.horizontal, 8)
            .background(Color.black.opacity(0.03))
            .cornerRadius(6)

            validationSummary

            if !mappings.isEmpty {
                selectionControls
                mappingList
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func firmwareRow(for slot: FirmwareSlot) -> some View {
        let archive = archiveForSlot(slot)

        return HStack(spacing: 10) {
            Text(slot.rawValue)
                .fontWeight(.medium)
                .frame(width: 80, alignment: .leading)

            VStack(alignment: .leading, spacing: 2) {
                Text(archive?.displayName ?? "Aucune archive")
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let archive {
                    Text("\(archive.entries.count) entrées")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(mappingStatusText(for: slot))
                        .font(.caption)
                        .foregroundStyle(mappingStatusColor(for: slot))
                }
            }

            Spacer()

            if archive != nil {
                Button {
                    onArchiveRemoved(slot)
                } label: {
                    Image(systemName: "xmark.circle")
                }
                .buttonStyle(.borderless)
                .help("Retirer")
            }

            Button("Choisir...") {
                selectArchive(for: slot)
            }
        }
        .padding(.vertical, 6)
    }

    private var validationSummary: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Correspondances : \(mappings.count) images associées à \(mappingSourceName)")
                .font(.subheadline)
                .fontWeight(.medium)

            ForEach(errors, id: \.self) { error in
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            ForEach(warnings, id: \.self) { warning in
                Text(warning)
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            ForEach(selectionWarnings, id: \.self) { warning in
                Text(warning)
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }

    private var selectionControls: some View {
        HStack(spacing: 8) {
            Text("Images à flasher : \(selectedMappings.count), \(byteCount(selectedSize))")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Spacer()

            Button("Sélection conseillée") {
                onRecommendedSelectionRequested()
            }

            Button("CSC minimal") {
                onSmallCscSelectionRequested()
            }

            Button("Effacer") {
                onSelectionCleared()
            }
            .disabled(selectedMappingIDs.isEmpty)
        }
    }

    private var mappingList: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(mappings) { mapping in
                    HStack(spacing: 10) {
                        Toggle(
                            "",
                            isOn: Binding(
                                get: { selectedMappingIDs.contains(mapping.id) },
                                set: { onMappingSelectionChanged(mapping.id, $0) }
                            )
                        )
                        .labelsHidden()
                        .frame(width: 24)

                        Text(mapping.slot.rawValue)
                            .fontWeight(.medium)
                            .frame(width: 70, alignment: .leading)

                        Text(mapping.entry.fileName)
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)

                        Image(systemName: "arrow.right")
                            .foregroundStyle(.secondary)

                        Text(mapping.partition.partitionName)
                            .frame(width: 130, alignment: .leading)

                        Text(byteCount(mapping.entry.size))
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
        .frame(minHeight: 150, idealHeight: 190, maxHeight: 220)
        .background(Color.black.opacity(0.04))
        .cornerRadius(6)
    }

    private func selectArchive(for slot: FirmwareSlot) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.title = "Selectionner l'archive \(slot.rawValue)"
        panel.allowedContentTypes = [.data]
        if panel.runModal() == .OK, let url = panel.url {
            onArchiveSelected(url, slot)
        }
    }

    private func byteCount(_ value: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: value), countStyle: .file)
    }

    private func mappingStatusText(for slot: FirmwareSlot) -> String {
        guard hasMappingSource else { return "En attente \(mappingSourceName)" }

        let count = mappingCount(for: slot)
        let ignored = ignoredCount(for: slot)
        if count == 0 {
            return ignored == 0 ? "0 correspondance \(mappingSourceName)" : "0 correspondance \(mappingSourceName), \(ignored) ignorees"
        }
        if count == 1 {
            return ignored == 0 ? "1 correspondance \(mappingSourceName)" : "1 correspondance \(mappingSourceName), \(ignored) ignorees"
        }
        return ignored == 0 ? "\(count) correspondances \(mappingSourceName)" : "\(count) correspondances \(mappingSourceName), \(ignored) ignorees"
    }

    private func mappingStatusColor(for slot: FirmwareSlot) -> Color {
        guard hasMappingSource else { return .secondary }
        return mappingCount(for: slot) == 0 ? .orange : .secondary
    }

    private func mappingCount(for slot: FirmwareSlot) -> Int {
        mappings.filter { $0.slot == slot }.count
    }

    private func ignoredCount(for slot: FirmwareSlot) -> Int {
        unmatchedEntries.filter { $0.slot == slot }.count
    }

    private var selectedMappings: [FirmwareMapping] {
        mappings.filter { selectedMappingIDs.contains($0.id) }
    }

    private var selectedSize: UInt64 {
        selectedMappings.reduce(UInt64(0)) { $0 + $1.entry.size }
    }
}

#Preview {
    FirmwareSelectionView(
        archiveForSlot: { _ in nil },
        mappings: [],
        unmatchedEntries: [],
        selectedMappingIDs: [],
        selectionWarnings: [],
        warnings: ["Lire le PIT avant de valider un firmware."],
        errors: [],
        mappingSourceName: "PIT",
        hasMappingSource: false,
        onMappingSelectionChanged: { _, _ in },
        onRecommendedSelectionRequested: {},
        onSmallCscSelectionRequested: {},
        onSelectionCleared: {},
        onArchiveSelected: { _, _ in },
        onArchiveRemoved: { _ in }
    )
    .padding()
    .frame(width: 720, height: 360)
}
