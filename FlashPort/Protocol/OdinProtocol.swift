import Foundation

/// Constantes et structures du protocole Odin (mode Download Samsung).
///
/// ATTENTION : les valeurs numeriques ci-dessous reproduisent la structure
/// generale du protocole telle que documentee par le projet open source
/// Heimdall (Glassechidna/Heimdall). Elles doivent être revalidées octet par
/// octet contre le code source de référence avant tout flash sur matériel
/// réel. Une valeur erronée provoque un échec de handshake ou de commande,
/// sans risque matériel, mais bloque le fonctionnement.
enum OdinProtocol {

    // Identifiants USB Samsung en mode Download.
    static let samsungVendorID: UInt16 = 0x04E8

    // Plusieurs ProductID existent selon la generation de chipset.
    // Liste reprise des regles udev Heimdall.
    static let knownProductIDs: [UInt16] = [0x6601, 0x685D, 0x68C3]

    // Sequences de handshake.
    static let handshakeRequest: [UInt8] = Array("ODIN".utf8)
    static let handshakeResponse: [UInt8] = Array("LOKE".utf8)

    // Taille standard d'un paquet de commande de session (à vérifier).
    static let sessionPacketSize = 1024
    static let responsePacketSize = 8
    static let pitFilePartSize = 500
    static let defaultFilePartSize = 131_072
    static let defaultFileTransferSequenceMaxLength = 800
    static let defaultFileTransferSequenceTimeout: TimeInterval = 30
    static let negotiatedFilePartSize = 1_048_576
    static let negotiatedFileTransferSequenceMaxLength = 30
    static let negotiatedFileTransferSequenceTimeout: TimeInterval = 120
    static let maximumPitFileSize = 1_048_576
    static let interPartitionFlashDelay: TimeInterval = 0.25
    static let largePartitionFlashDelay: TimeInterval = 1.25
    static let eraseUserDataTimeout: TimeInterval = 600
    // Après une très grosse image, le téléphone finit d'écrire en mémoire
    // avant de confirmer la dernière séquence et la fin de session.
    static let finalSequenceTimeout: TimeInterval = 300
    static let endSessionTimeout: TimeInterval = 300
    static let cleanupEndSessionTimeout: TimeInterval = 5
    static let requestedProtocolVersion: UInt32 = 4
    static let compressedTransferSupportFlag: UInt32 = 0x8000

    /// Types de controle Odin 3. Les paquets sortants commencent par l'un de
    /// ces identifiants, puis par une requete optionnelle.
    enum ControlType: UInt32 {
        case session = 0x64
        case pitFile = 0x65
        case fileTransfer = 0x66
        case endSession = 0x67
    }

    /// Requetes de setup de session.
    enum SessionRequest: UInt32 {
        case beginSession = 0x00
        case deviceType = 0x01
        case totalBytes = 0x02
        case filePartSize = 0x05
        case eraseUserData = 0x07
        case enableTFlash = 0x08
    }

    /// Requetes pour le transfert PIT.
    enum PitRequest: UInt32 {
        case flash = 0x00
        case dump = 0x01
        case part = 0x02
        case endTransfer = 0x03
    }

    /// Requetes pour le transfert de fichiers de partition.
    enum FileTransferRequest: UInt32 {
        case flash = 0x00
        case dump = 0x01
        case part = 0x02
        case end = 0x03
        case compressedFlash = 0x05
        case compressedPart = 0x06
        case compressedEnd = 0x07
    }

    enum FileTransferDestination: UInt32 {
        case phone = 0x00
        case modem = 0x01
    }

    enum ResponseType: UInt32 {
        case sendFilePart = 0x00
        case sessionSetup = 0x64
        case pitFile = 0x65
        case fileTransfer = 0x66
        case endSession = 0x67
    }

    /// Requetes de fin de session.
    enum EndSessionRequest: UInt32 {
        case end = 0x00
        case reboot = 0x01
    }
}

/// Structure generique d'un paquet de controle Odin, complete a 1024 octets.
struct SessionCommandPacket {
    var controlType: UInt32
    var request: UInt32?
    var payload: [UInt32]

    func serialize() -> Data {
        var data = Data()
        append(controlType, to: &data)
        if let request {
            append(request, to: &data)
        }
        for value in payload {
            append(value, to: &data)
        }
        if data.count < OdinProtocol.sessionPacketSize {
            data.append(Data(repeating: 0, count: OdinProtocol.sessionPacketSize - data.count))
        }
        return data
    }

    private func append(_ value: UInt32, to data: inout Data) {
        var littleEndian = value.littleEndian
        withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
    }
}
