import Foundation

/// Une entree de la table PIT correspond a une partition du terminal.
struct PitEntry: Identifiable, Equatable {
    let id = UUID()
    var binaryType: UInt32
    var deviceType: UInt32
    var identifier: UInt32
    var attributes: UInt32
    var updateAttributes: UInt32
    var blockSizeOrOffset: UInt32
    var blockCount: UInt32
    var fileOffset: UInt32
    var fileSize: UInt32
    var partitionName: String
    var flashFilename: String
    var fotaFilename: String

    var isFlashable: Bool {
        !partitionName.isEmpty
    }

    static func == (lhs: PitEntry, rhs: PitEntry) -> Bool {
        lhs.binaryType == rhs.binaryType &&
        lhs.deviceType == rhs.deviceType &&
        lhs.identifier == rhs.identifier &&
        lhs.attributes == rhs.attributes &&
        lhs.updateAttributes == rhs.updateAttributes &&
        lhs.blockSizeOrOffset == rhs.blockSizeOrOffset &&
        lhs.blockCount == rhs.blockCount &&
        lhs.fileOffset == rhs.fileOffset &&
        lhs.fileSize == rhs.fileSize &&
        lhs.partitionName == rhs.partitionName &&
        lhs.flashFilename == rhs.flashFilename &&
        lhs.fotaFilename == rhs.fotaFilename
    }
}

enum PitFileError: Error, Equatable, LocalizedError {
    case dataTooShort(required: Int, actual: Int)
    case invalidIdentifier(UInt32)
    case invalidEntryCount(UInt32)
    case stringTooLong(field: String, maximumLength: Int)

    var errorDescription: String? {
        switch self {
        case .dataTooShort(let required, let actual):
            return "PIT incomplet : \(actual) octets reçus, \(required) octets requis."
        case .invalidIdentifier(let identifier):
            return "Identifiant PIT invalide : 0x\(String(identifier, radix: 16, uppercase: true))."
        case .invalidEntryCount(let count):
            return "Nombre d'entrées PIT invalide : \(count)."
        case .stringTooLong(let field, let maximumLength):
            return "Champ PIT trop long (\(field)), maximum \(maximumLength - 1) caracteres."
        }
    }
}

/// Representation et parsing du fichier PIT (Partition Information Table).
///
/// Format reference Heimdall/libpit :
/// - identifiant 0x12349876
/// - en-tete de 28 octets
/// - entrées de 132 octets
/// - noms de partition / flash / FOTA sur 32 octets chacun.
struct PitFile: Equatable {
    private static let fileIdentifier: UInt32 = 0x12349876
    private static let headerDataSize = 28
    private static let entryDataSize = 132
    private static let partitionNameLength = 32
    private static let flashFilenameLength = 32
    private static let fotaFilenameLength = 32
    private static let paddedSizeMultiplicand = 4096

    var unknown1: UInt32
    var unknown2: UInt32
    var unknown3: UInt16
    var unknown4: UInt16
    var unknown5: UInt16
    var unknown6: UInt16
    var unknown7: UInt16
    var unknown8: UInt16
    var entries: [PitEntry]

    init(
        unknown1: UInt32 = 0,
        unknown2: UInt32 = 0,
        unknown3: UInt16 = 0,
        unknown4: UInt16 = 0,
        unknown5: UInt16 = 0,
        unknown6: UInt16 = 0,
        unknown7: UInt16 = 0,
        unknown8: UInt16 = 0,
        entries: [PitEntry]
    ) {
        self.unknown1 = unknown1
        self.unknown2 = unknown2
        self.unknown3 = unknown3
        self.unknown4 = unknown4
        self.unknown5 = unknown5
        self.unknown6 = unknown6
        self.unknown7 = unknown7
        self.unknown8 = unknown8
        self.entries = entries
    }

    static func parse(_ data: Data) throws -> PitFile {
        let bytes = Array(data)
        guard bytes.count >= headerDataSize else {
            throw PitFileError.dataTooShort(required: headerDataSize, actual: bytes.count)
        }

        let identifier = readUInt32(bytes, at: 0)
        guard identifier == fileIdentifier else {
            throw PitFileError.invalidIdentifier(identifier)
        }

        let entryCountValue = readUInt32(bytes, at: 4)
        let requiredSize64 = UInt64(headerDataSize) + UInt64(entryCountValue) * UInt64(entryDataSize)
        guard requiredSize64 <= UInt64(Int.max) else {
            throw PitFileError.invalidEntryCount(entryCountValue)
        }

        let entryCount = Int(entryCountValue)
        let requiredSize = Int(requiredSize64)
        guard bytes.count >= requiredSize else {
            throw PitFileError.dataTooShort(required: requiredSize, actual: bytes.count)
        }

        var entries: [PitEntry] = []
        entries.reserveCapacity(entryCount)

        for index in 0..<entryCount {
            let offset = headerDataSize + index * entryDataSize
            entries.append(
                PitEntry(
                    binaryType: readUInt32(bytes, at: offset),
                    deviceType: readUInt32(bytes, at: offset + 4),
                    identifier: readUInt32(bytes, at: offset + 8),
                    attributes: readUInt32(bytes, at: offset + 12),
                    updateAttributes: readUInt32(bytes, at: offset + 16),
                    blockSizeOrOffset: readUInt32(bytes, at: offset + 20),
                    blockCount: readUInt32(bytes, at: offset + 24),
                    fileOffset: readUInt32(bytes, at: offset + 28),
                    fileSize: readUInt32(bytes, at: offset + 32),
                    partitionName: readFixedString(bytes, at: offset + 36, length: partitionNameLength),
                    flashFilename: readFixedString(bytes, at: offset + 36 + partitionNameLength, length: flashFilenameLength),
                    fotaFilename: readFixedString(bytes, at: offset + 36 + partitionNameLength + flashFilenameLength, length: fotaFilenameLength)
                )
            )
        }

        return PitFile(
            unknown1: readUInt32(bytes, at: 8),
            unknown2: readUInt32(bytes, at: 12),
            unknown3: readUInt16(bytes, at: 16),
            unknown4: readUInt16(bytes, at: 18),
            unknown5: readUInt16(bytes, at: 20),
            unknown6: readUInt16(bytes, at: 22),
            unknown7: readUInt16(bytes, at: 24),
            unknown8: readUInt16(bytes, at: 26),
            entries: entries
        )
    }

    func serialize(paddedToBlockSize blockSize: Int? = nil) throws -> Data {
        let baseSize = Self.headerDataSize + entries.count * Self.entryDataSize
        let targetSize = paddedSize(for: baseSize, blockSize: blockSize)
        var data = Data(repeating: 0, count: targetSize)

        Self.writeUInt32(Self.fileIdentifier, to: &data, at: 0)
        Self.writeUInt32(UInt32(entries.count), to: &data, at: 4)
        Self.writeUInt32(unknown1, to: &data, at: 8)
        Self.writeUInt32(unknown2, to: &data, at: 12)
        Self.writeUInt16(unknown3, to: &data, at: 16)
        Self.writeUInt16(unknown4, to: &data, at: 18)
        Self.writeUInt16(unknown5, to: &data, at: 20)
        Self.writeUInt16(unknown6, to: &data, at: 22)
        Self.writeUInt16(unknown7, to: &data, at: 24)
        Self.writeUInt16(unknown8, to: &data, at: 26)

        for (index, entry) in entries.enumerated() {
            let offset = Self.headerDataSize + index * Self.entryDataSize
            Self.writeUInt32(entry.binaryType, to: &data, at: offset)
            Self.writeUInt32(entry.deviceType, to: &data, at: offset + 4)
            Self.writeUInt32(entry.identifier, to: &data, at: offset + 8)
            Self.writeUInt32(entry.attributes, to: &data, at: offset + 12)
            Self.writeUInt32(entry.updateAttributes, to: &data, at: offset + 16)
            Self.writeUInt32(entry.blockSizeOrOffset, to: &data, at: offset + 20)
            Self.writeUInt32(entry.blockCount, to: &data, at: offset + 24)
            Self.writeUInt32(entry.fileOffset, to: &data, at: offset + 28)
            Self.writeUInt32(entry.fileSize, to: &data, at: offset + 32)
            try Self.writeFixedString(entry.partitionName, to: &data, at: offset + 36, length: Self.partitionNameLength, field: "partitionName")
            try Self.writeFixedString(entry.flashFilename, to: &data, at: offset + 36 + Self.partitionNameLength, length: Self.flashFilenameLength, field: "flashFilename")
            try Self.writeFixedString(entry.fotaFilename, to: &data, at: offset + 36 + Self.partitionNameLength + Self.flashFilenameLength, length: Self.fotaFilenameLength, field: "fotaFilename")
        }

        return data
    }

    func paddedSerialize() throws -> Data {
        try serialize(paddedToBlockSize: Self.paddedSizeMultiplicand)
    }

    func entry(named partitionName: String) -> PitEntry? {
        entries.first { $0.isFlashable && $0.partitionName == partitionName }
    }

    private func paddedSize(for size: Int, blockSize: Int?) -> Int {
        guard let blockSize, blockSize > 0 else { return size }
        let remainder = size % blockSize
        return remainder == 0 ? size : size + blockSize - remainder
    }

    private static func readUInt16(_ bytes: [UInt8], at offset: Int) -> UInt16 {
        UInt16(bytes[offset]) |
        UInt16(bytes[offset + 1]) << 8
    }

    private static func readUInt32(_ bytes: [UInt8], at offset: Int) -> UInt32 {
        UInt32(bytes[offset]) |
        UInt32(bytes[offset + 1]) << 8 |
        UInt32(bytes[offset + 2]) << 16 |
        UInt32(bytes[offset + 3]) << 24
    }

    private static func readFixedString(_ bytes: [UInt8], at offset: Int, length: Int) -> String {
        let field = bytes[offset..<offset + length]
        let endIndex = field.firstIndex(of: 0) ?? field.endIndex
        return String(decoding: field[..<endIndex], as: UTF8.self)
    }

    private static func writeUInt16(_ value: UInt16, to data: inout Data, at offset: Int) {
        var littleEndian = value.littleEndian
        withUnsafeBytes(of: &littleEndian) { buffer in
            data.replaceSubrange(offset..<offset + 2, with: buffer)
        }
    }

    private static func writeUInt32(_ value: UInt32, to data: inout Data, at offset: Int) {
        var littleEndian = value.littleEndian
        withUnsafeBytes(of: &littleEndian) { buffer in
            data.replaceSubrange(offset..<offset + 4, with: buffer)
        }
    }

    private static func writeFixedString(_ value: String, to data: inout Data, at offset: Int, length: Int, field: String) throws {
        let encoded = Array(value.utf8)
        guard encoded.count < length else {
            throw PitFileError.stringTooLong(field: field, maximumLength: length)
        }

        data.replaceSubrange(offset..<offset + encoded.count, with: encoded)
    }
}
