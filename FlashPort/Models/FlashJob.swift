import Foundation

/// Association entre une partition cible et un fichier image local.
struct FlashJob: Identifiable {
    let id = UUID()
    var partitionName: String
    var fileURL: URL?
    var fileSize: Int64 {
        guard let url = fileURL else { return 0 }
        return (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap { Int64($0) } ?? 0
    }
}

/// Partitions habituellement manipulees lors d'un flash Samsung.
enum StandardPartition: String, CaseIterable {
    case bootloader = "BL"
    case applicationProcessor = "AP"
    case communicationProcessor = "CP"
    case customerSoftwareCustomization = "CSC"
    case userData = "USERDATA"
}
