import Foundation

/// Emplacements standards des archives firmware Samsung sélectionnées par l'utilisateur.
enum FirmwareSlot: String, CaseIterable, Identifiable {
    case bl = "BL"
    case ap = "AP"
    case cp = "CP"
    case csc = "CSC"
    case homeCSC = "HOME_CSC"

    var id: String { rawValue }
}

enum FirmwareDataMode: String, CaseIterable, Identifiable {
    case erase
    case preserve

    var id: String { rawValue }

    var activeCscSlot: FirmwareSlot {
        switch self {
        case .erase:
            return .csc
        case .preserve:
            return .homeCSC
        }
    }

    var title: String {
        switch self {
        case .erase:
            return "Effacer données"
        case .preserve:
            return "Sans effacement"
        }
    }
}

struct FirmwareArchive: Identifiable, Equatable {
    var id: FirmwareSlot { slot }
    var slot: FirmwareSlot
    var url: URL
    var entries: [FirmwareArchiveEntry]

    /// Contenu de meta-data/download-list.txt : quand ce fichier est présent,
    /// Odin ne flashe QUE les images qui y figurent. Exemple : le package
    /// HOME_CSC (conservation des données) exclut misc.bin, param.bin,
    /// md_udc.img et userdata.img de sa liste.
    var downloadListImageNames: Set<String>? = nil

    var displayName: String {
        url.lastPathComponent
    }

    var modelCode: String? {
        FirmwareCompatibilityValidator.firmwareModelCode(from: displayName)
    }

    var bootloaderRevision: Int? {
        FirmwareCompatibilityValidator.firmwareBootloaderRevision(from: displayName)
    }
}

struct FirmwareArchiveEntry: Identifiable, Equatable {
    var id: String { path }
    var path: String
    var size: UInt64
    var dataOffset: UInt64

    var fileName: String {
        URL(fileURLWithPath: path).lastPathComponent
    }

    var normalizedPartitionCandidate: String {
        Self.normalizeImageName(fileName)
    }

    var isFlashImageCandidate: Bool {
        let lowercasedName = fileName.lowercased()
        let uncompressedName = lowercasedName.hasSuffix(".lz4")
            ? String(lowercasedName.dropLast(4))
            : lowercasedName
        let flashSuffixes = [
            ".img",
            ".bin",
            ".mbn",
            ".elf",
            ".ext4",
            ".sparse"
        ]
        return flashSuffixes.contains { uncompressedName.hasSuffix($0) }
    }

    static func normalizeImageName(_ name: String) -> String {
        var name = URL(fileURLWithPath: name).lastPathComponent.lowercased()
        let suffixes = [
            ".lz4",
            ".img",
            ".bin",
            ".mbn",
            ".elf",
            ".ext4",
            ".sparse"
        ]

        var changed = true
        while changed {
            changed = false
            for suffix in suffixes where name.hasSuffix(suffix) {
                name.removeLast(suffix.count)
                changed = true
            }
        }

        return name
    }
}

struct FirmwareMapping: Identifiable, Equatable {
    var id: String { "\(slot.rawValue):\(entry.path)->\(partition.partitionName)" }
    var slot: FirmwareSlot
    var archiveName: String
    var archiveURL: URL
    var archiveEntryIndex: Int
    var entry: FirmwareArchiveEntry
    var partition: PitEntry
}

struct FirmwareUnmatchedEntry: Identifiable, Equatable {
    var id: String { "\(slot.rawValue):\(entry.path)" }
    var slot: FirmwareSlot
    var archiveName: String
    var entry: FirmwareArchiveEntry
}

struct FirmwareValidationReport: Equatable {
    var mappings: [FirmwareMapping]
    var unmatchedEntries: [FirmwareUnmatchedEntry]
    var warnings: [String]
    var errors: [String]

    var isUsableForFlashPreparation: Bool {
        !mappings.isEmpty && errors.isEmpty
    }
}

struct FirmwareCompatibilityReport: Equatable {
    var firmwareModelCodesBySlot: [FirmwareSlot: String]
    var firmwareModelCodes: [String]
    var firmwareBootloaderRevisionsBySlot: [FirmwareSlot: Int]
    var firmwareBootloaderRevisions: [Int]
    var expectedDeviceModelCode: String?
    var currentBootloaderRevision: Int?
    var warnings: [String]
    var errors: [String]

    var summary: String {
        let bootloaderText: String
        if firmwareBootloaderRevisions.isEmpty {
            bootloaderText = ""
        } else {
            let revisions = firmwareBootloaderRevisions
                .map { FirmwareCompatibilityValidator.bootloaderRevisionText($0) }
                .joined(separator: ", ")
            bootloaderText = ", binary \(revisions)"
        }

        guard !firmwareModelCodes.isEmpty else {
            if let expectedDeviceModelCode {
                return "Modèle attendu \(expectedDeviceModelCode). Modèle firmware non détecté dans le nom des archives."
            }
            return "Modèle firmware non détecté."
        }

        let firmwareText = firmwareModelCodes.joined(separator: ", ")
        if let expectedDeviceModelCode {
            return "Firmware \(firmwareText)\(bootloaderText), modèle attendu \(expectedDeviceModelCode)."
        }

        if let currentBootloaderRevision {
            let currentText = FirmwareCompatibilityValidator.bootloaderRevisionText(currentBootloaderRevision)
            return "Firmware \(firmwareText)\(bootloaderText), binary actuel \(currentText)."
        }

        return "Firmware \(firmwareText)\(bootloaderText). Renseigner le modèle attendu et le binary actuel pour bloquer un mauvais firmware ou downgrade."
    }
}

struct FirmwarePackageMetadata: Equatable {
    var sourceName: String?
    var archiveCount: Int
    var imageCount: Int
    var modelCodes: [String]
    var regionCodes: [String]
    var buildCodes: [String]
    var bootloaderRevisions: [Int]

    static let empty = FirmwarePackageMetadata(
        sourceName: nil,
        archiveCount: 0,
        imageCount: 0,
        modelCodes: [],
        regionCodes: [],
        buildCodes: [],
        bootloaderRevisions: []
    )

    static func scan(sourceName: String?, archives: [FirmwareArchive]) -> FirmwarePackageMetadata {
        var modelCodes = Set<String>()
        var regionCodes = Set<String>()
        var buildCodes = Set<String>()
        var bootloaderRevisions = Set<Int>()

        if let sourceName {
            if let modelCode = FirmwareCompatibilityValidator.firmwareModelCode(from: sourceName) {
                modelCodes.insert(modelCode)
            }
            if let regionCode = FirmwareCompatibilityValidator.regionCode(from: sourceName) {
                regionCodes.insert(regionCode)
            }
            if let buildCode = FirmwareCompatibilityValidator.firmwareBuildCode(from: sourceName) {
                buildCodes.insert(buildCode)
            }
        }

        for archive in archives {
            if let modelCode = archive.modelCode {
                modelCodes.insert(modelCode)
            }
            if let buildCode = FirmwareCompatibilityValidator.firmwareBuildCode(from: archive.displayName) {
                buildCodes.insert(buildCode)
            }
            if let bootloaderRevision = archive.bootloaderRevision {
                bootloaderRevisions.insert(bootloaderRevision)
            }
        }

        return FirmwarePackageMetadata(
            sourceName: sourceName,
            archiveCount: archives.count,
            imageCount: archives.reduce(0) { $0 + $1.entries.count },
            modelCodes: Array(modelCodes).sorted(),
            regionCodes: Array(regionCodes).sorted(),
            buildCodes: Array(buildCodes).sorted(),
            bootloaderRevisions: Array(bootloaderRevisions).sorted()
        )
    }
}

enum FirmwareCompatibilityValidator {
    static func validate(
        archives: [FirmwareArchive],
        expectedDeviceModelInput: String?,
        detectedDeviceModelCode: String?,
        currentBootloaderRevisionInput: String? = nil
    ) -> FirmwareCompatibilityReport {
        let expectedInput = expectedDeviceModelInput?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let normalizedExpectedModel = normalizedDeviceModelCode(expectedInput)
        let normalizedDetectedModel = detectedDeviceModelCode.flatMap { normalizedDeviceModelCode($0) }
        let activeDeviceModel = normalizedExpectedModel ?? normalizedDetectedModel
        let bootloaderRevisionInput = currentBootloaderRevisionInput?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let currentBootloaderRevision = bootloaderRevisionCode(from: bootloaderRevisionInput)

        var modelCodesBySlot: [FirmwareSlot: String] = [:]
        var bootloaderRevisionsBySlot: [FirmwareSlot: Int] = [:]
        for archive in archives {
            if let modelCode = archive.modelCode {
                modelCodesBySlot[archive.slot] = modelCode
            }
            if let bootloaderRevision = archive.bootloaderRevision {
                bootloaderRevisionsBySlot[archive.slot] = bootloaderRevision
            }
        }

        let firmwareModelCodes = Array(Set(modelCodesBySlot.values)).sorted()
        let firmwareBootloaderRevisions = Array(Set(bootloaderRevisionsBySlot.values)).sorted()
        var warnings: [String] = []
        var errors: [String] = []

        if !expectedInput.isEmpty && normalizedExpectedModel == nil {
            errors.append("Modèle attendu invalide : utiliser un code comme SM-A536B ou A536B.")
        }

        if !bootloaderRevisionInput.isEmpty && currentBootloaderRevision == nil {
            errors.append("Binary actuel invalide : utiliser 1-9 ou A-Z selon l'écran Download Mode.")
        }

        if !archives.isEmpty && firmwareModelCodes.isEmpty {
            warnings.append("Sécurité firmware : modèle non détecté dans le nom des archives officielles.")
        }

        if !archives.isEmpty && firmwareBootloaderRevisions.isEmpty {
            warnings.append("Sécurité downgrade : binary firmware non détecté dans le nom des archives officielles.")
        }

        if firmwareModelCodes.count > 1 {
            let details = modelCodesBySlot
                .sorted { $0.key.rawValue < $1.key.rawValue }
                .map { "\($0.key.rawValue) \($0.value)" }
                .joined(separator: ", ")
            errors.append("Firmware bloqué : archives de modèles différents (\(details)).")
        }

        if firmwareBootloaderRevisions.count > 1 {
            let details = bootloaderRevisionsBySlot
                .sorted { $0.key.rawValue < $1.key.rawValue }
                .map { "\($0.key.rawValue) binary \(bootloaderRevisionText($0.value))" }
                .joined(separator: ", ")
            warnings.append("Sécurité downgrade : archives avec binary différents (\(details)).")
        }

        if let activeDeviceModel, let firmwareModel = firmwareModelCodes.first, firmwareModelCodes.count == 1 {
            if firmwareModel != activeDeviceModel {
                errors.append("Firmware bloqué : modèle firmware \(firmwareModel) différent du modèle attendu \(activeDeviceModel).")
            }
        } else if activeDeviceModel != nil && !archives.isEmpty && firmwareModelCodes.isEmpty {
            warnings.append("Modèle attendu renseigné, mais le modèle firmware n'a pas pu être lu depuis les noms d'archives.")
        }

        if let currentBootloaderRevision {
            let lowerFirmwareRevisions = firmwareBootloaderRevisions.filter { $0 < currentBootloaderRevision }
            if !lowerFirmwareRevisions.isEmpty {
                let firmwareText = lowerFirmwareRevisions
                    .map { bootloaderRevisionText($0) }
                    .joined(separator: ", ")
                let currentText = bootloaderRevisionText(currentBootloaderRevision)
                errors.append("Firmware bloqué : downgrade bootloader impossible (firmware binary \(firmwareText) < téléphone binary \(currentText)).")
            }
        }

        return FirmwareCompatibilityReport(
            firmwareModelCodesBySlot: modelCodesBySlot,
            firmwareModelCodes: firmwareModelCodes,
            firmwareBootloaderRevisionsBySlot: bootloaderRevisionsBySlot,
            firmwareBootloaderRevisions: firmwareBootloaderRevisions,
            expectedDeviceModelCode: activeDeviceModel,
            currentBootloaderRevision: currentBootloaderRevision,
            warnings: warnings,
            errors: errors
        )
    }

    static func firmwareModelCode(from archiveName: String) -> String? {
        let archiveTokens = tokens(from: archiveName)

        if let deviceModel = deviceModelCode(fromTokens: archiveTokens) {
            return deviceModel
        }

        for token in archiveTokens {
            if let modelCode = modelCode(fromFirmwareBuildToken: token) {
                return modelCode
            }
        }

        return nil
    }

    static func firmwareBootloaderRevision(from archiveName: String) -> Int? {
        let archiveTokens = tokens(from: archiveName)
        guard let modelCode = firmwareModelCode(from: archiveName) else { return nil }

        for token in archiveTokens where token.hasPrefix(modelCode) {
            let suffix = String(token.dropFirst(modelCode.count))
            if let revision = bootloaderRevisionCode(fromBuildSuffix: suffix) {
                return revision
            }
        }

        return nil
    }

    static func firmwareBuildCode(from name: String) -> String? {
        let archiveTokens = tokens(from: name)
        guard let modelCode = firmwareModelCode(from: name) else { return nil }

        for token in archiveTokens where token.hasPrefix(modelCode) {
            let suffix = String(token.dropFirst(modelCode.count))
            if bootloaderRevisionCode(fromBuildSuffix: suffix) != nil {
                return token
            }
        }

        return nil
    }

    static func regionCode(from sourceName: String) -> String? {
        let sourceTokens = tokens(from: sourceName)
        guard let modelIndex = sourceTokens.firstIndex(where: { normalizedDeviceModelCode($0) != nil }) else {
            return nil
        }
        let regionIndex = sourceTokens.index(after: modelIndex)
        guard regionIndex < sourceTokens.endIndex else { return nil }

        let region = sourceTokens[regionIndex]
        guard region.count == 3, region.allSatisfy(\.isLetter) else { return nil }
        return region
    }

    static func deviceModelCode(from text: String?) -> String? {
        guard let text else { return nil }
        return deviceModelCode(fromTokens: tokens(from: text))
    }

    static func normalizedDeviceModelCode(_ value: String) -> String? {
        var sanitized = asciiLettersAndDigits(from: value)
        if sanitized.hasPrefix("SM") {
            sanitized.removeFirst(2)
        }
        guard isPlausibleModelCode(sanitized) else { return nil }
        return sanitized
    }

    static func formattedDeviceModelInput(_ value: String) -> String {
        let uppercased = value.uppercased()
        let allowedCharacters = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_ ")
        return String(uppercased.filter { allowedCharacters.contains($0) }.prefix(12))
    }

    static func formattedBootloaderRevisionInput(_ value: String) -> String {
        let allowedCharacters = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
        return String(value.uppercased().filter { allowedCharacters.contains($0) }.prefix(2))
    }

    static func bootloaderRevisionCode(from value: String) -> Int? {
        let sanitized = asciiLettersAndDigits(from: value)
        guard !sanitized.isEmpty else { return nil }
        if let numericValue = Int(sanitized) {
            return numericValue
        }
        guard sanitized.count == 1, let character = sanitized.first else { return nil }
        return bootloaderRevisionValue(from: character)
    }

    static func bootloaderRevisionText(_ value: Int) -> String {
        if value < 10 {
            return String(value)
        }

        let scalarValue = UInt8(ascii: "A") + UInt8(value - 10)
        return String(UnicodeScalar(scalarValue))
    }

    private static func deviceModelCode(fromTokens tokens: [String]) -> String? {
        for index in tokens.indices {
            let token = tokens[index]
            if token == "SM", let nextIndex = tokens.index(index, offsetBy: 1, limitedBy: tokens.endIndex - 1) {
                if let modelCode = normalizedDeviceModelCode("SM\(tokens[nextIndex])") {
                    return modelCode
                }
            }

            if token.hasPrefix("SM"), let modelCode = normalizedDeviceModelCode(token) {
                return modelCode
            }
        }

        return nil
    }

    private static func modelCode(fromFirmwareBuildToken token: String) -> String? {
        if let modelCode = normalizedDeviceModelCode(token) {
            return modelCode
        }

        guard token.count >= 6 else { return nil }
        let characters = Array(token)
        guard characters[0].isLetter else { return nil }
        guard characters[1].isNumber, characters[2].isNumber, characters[3].isNumber else { return nil }

        let suffix = String(characters.dropFirst(4))
        if suffix.hasPrefix("U1"), characters.count >= 6 {
            return String(characters.prefix(6))
        }
        if suffix.hasPrefix("XX") {
            return String(characters.prefix(4))
        }

        let modelCode = String(characters.prefix(5))
        return isPlausibleModelCode(modelCode) ? modelCode : nil
    }

    private static func bootloaderRevisionCode(fromBuildSuffix suffix: String) -> Int? {
        let characters = Array(suffix)
        guard characters.count >= 5 else { return nil }

        return bootloaderRevisionValue(from: characters[characters.count - 5])
    }

    private static func bootloaderRevisionValue(from character: Character) -> Int? {
        if character.isNumber, let value = Int(String(character)) {
            return value
        }

        guard let ascii = character.asciiValue, ascii >= UInt8(ascii: "A"), ascii <= UInt8(ascii: "Z") else {
            return nil
        }

        return Int(ascii - UInt8(ascii: "A")) + 10
    }

    private static func tokens(from text: String) -> [String] {
        text.uppercased().split { character in
            !character.isLetter && !character.isNumber
        }
        .map(String.init)
    }

    private static func asciiLettersAndDigits(from value: String) -> String {
        let allowedCharacters = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
        return String(value.uppercased().filter { allowedCharacters.contains($0) })
    }

    private static func isPlausibleModelCode(_ value: String) -> Bool {
        let characters = Array(value)
        guard (4...6).contains(characters.count) else { return false }
        guard characters[0].isLetter else { return false }
        guard characters[1].isNumber, characters[2].isNumber, characters[3].isNumber else { return false }
        return characters.dropFirst(4).allSatisfy { $0.isLetter || $0.isNumber }
    }
}

enum FirmwareArchiveError: Error, LocalizedError, Equatable {
    case unreadableFile(String)
    case invalidTarHeader(offset: UInt64)
    case invalidEntrySize(name: String)

    var errorDescription: String? {
        switch self {
        case .unreadableFile(let reason):
            return "Archive firmware illisible : \(reason)"
        case .invalidTarHeader(let offset):
            return "En-tête TAR invalide à l'offset \(offset)."
        case .invalidEntrySize(let name):
            return "Taille TAR invalide pour \(name)."
        }
    }
}

enum SamsungFirmwareArchiveReader {
    private static let blockSize = 512

    static func readArchive(
        url: URL,
        slot: FirmwareSlot,
        progressHandler: ((Double) -> Void)? = nil
    ) throws -> FirmwareArchive {
        let didAccess = url.startAccessingSecurityScopedResource()
        defer {
            if didAccess {
                url.stopAccessingSecurityScopedResource()
            }
        }

        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: url)
        } catch {
            throw FirmwareArchiveError.unreadableFile((error as? LocalizedError)?.errorDescription ?? String(describing: error))
        }
        defer { try? handle.close() }

        var entries: [FirmwareArchiveEntry] = []
        var pendingLongName: String?
        var offset: UInt64 = 0
        let fileSize = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        let totalSize = UInt64(max(fileSize, 0))
        progressHandler?(0)

        while true {
            try handle.seek(toOffset: offset)
            let header = handle.readData(ofLength: blockSize)
            guard header.count == blockSize else { break }
            if header.allSatisfy({ $0 == 0 }) { break }

            guard let entryName = tarName(from: header), !entryName.isEmpty else {
                throw FirmwareArchiveError.invalidTarHeader(offset: offset)
            }
            guard let entrySize = tarSize(from: header) else {
                throw FirmwareArchiveError.invalidEntrySize(name: entryName)
            }

            let typeFlag = header[156]
            let dataOffset = offset + UInt64(blockSize)
            let fullName = pendingLongName ?? entryName
            pendingLongName = nil

            if typeFlag == UInt8(ascii: "L") {
                try handle.seek(toOffset: dataOffset)
                let longNameData = handle.readData(ofLength: Int(entrySize))
                pendingLongName = String(decoding: longNameData.prefix { $0 != 0 }, as: UTF8.self)
            } else if typeFlag == 0 || typeFlag == UInt8(ascii: "0") {
                entries.append(
                    FirmwareArchiveEntry(
                        path: fullName,
                        size: entrySize,
                        dataOffset: dataOffset
                    )
                )
            }

            offset = dataOffset + paddedSize(for: entrySize)
            if totalSize > 0 {
                progressHandler?(min(Double(offset) / Double(totalSize), 1))
            }
        }

        progressHandler?(1)
        return FirmwareArchive(
            slot: slot,
            url: url,
            entries: entries,
            downloadListImageNames: readDownloadListImageNames(from: handle, entries: entries)
        )
    }

    private static func readDownloadListImageNames(
        from handle: FileHandle,
        entries: [FirmwareArchiveEntry]
    ) -> Set<String>? {
        guard let listEntry = entries.first(where: { $0.fileName.lowercased() == "download-list.txt" }),
              listEntry.size > 0, listEntry.size <= 1_048_576 else {
            return nil
        }

        guard (try? handle.seek(toOffset: listEntry.dataOffset)) != nil else { return nil }
        let data = handle.readData(ofLength: Int(listEntry.size))
        guard data.count == Int(listEntry.size) else { return nil }

        let names = Set(
            String(decoding: data, as: UTF8.self)
                .split(whereSeparator: \.isNewline)
                .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
                .filter { !$0.isEmpty }
        )
        return names.isEmpty ? nil : names
    }

    private static func tarName(from header: Data) -> String? {
        let name = stringField(header, range: 0..<100)
        let prefix = stringField(header, range: 345..<500)

        if !prefix.isEmpty {
            return "\(prefix)/\(name)"
        }
        return name
    }

    private static func tarSize(from header: Data) -> UInt64? {
        let sizeField = Array(header[124..<136])

        // Encodage GNU base-256 (bit haut du premier octet) utilisé pour les
        // entrées >= 8 Gio, comme super.img non compressé dans certains AP.
        if let firstByte = sizeField.first, firstByte & 0x80 != 0 {
            var value = UInt64(firstByte & 0x7F)
            for byte in sizeField.dropFirst() {
                guard value <= (UInt64.max >> 8) else { return nil }
                value = (value << 8) | UInt64(byte)
            }
            return value
        }

        let field = stringField(header, range: 124..<136)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !field.isEmpty else { return 0 }
        return UInt64(field, radix: 8)
    }

    private static func stringField(_ data: Data, range: Range<Int>) -> String {
        let bytes = data[range]
        let endIndex = bytes.firstIndex(of: 0) ?? bytes.endIndex
        return String(decoding: bytes[..<endIndex], as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func paddedSize(for size: UInt64) -> UInt64 {
        let remainder = size % UInt64(blockSize)
        return remainder == 0 ? size : size + UInt64(blockSize) - remainder
    }
}

enum FirmwareBundleImportError: Error, LocalizedError {
    case unsupportedSource(String)
    case extractionFailed(String)
    case noArchivesFound(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedSource(let name):
            return "\(name) : selectionner un ZIP firmware Samsung ou un dossier extrait."
        case .extractionFailed(let reason):
            return "Extraction du ZIP impossible : \(reason)"
        case .noArchivesFound(let name):
            return "\(name) : aucun fichier BL/AP/CP/CSC/HOME_CSC .tar.md5 trouvé."
        }
    }
}

struct FirmwareBundleImportResult {
    var archives: [FirmwareArchive]
    var temporaryDirectory: URL?
}

struct FirmwareImportProgress: Equatable {
    var message: String
    var progress: Double
    var isComplete: Bool
    var isFailed: Bool

    init(
        message: String,
        progress: Double,
        isComplete: Bool = false,
        isFailed: Bool = false
    ) {
        self.message = message
        self.progress = min(max(progress, 0), 1)
        self.isComplete = isComplete
        self.isFailed = isFailed
    }
}

enum FirmwareBundleImporter {
    static func importArchives(
        from sourceURL: URL,
        progressHandler: ((String) -> Void)? = nil,
        importProgressHandler: ((FirmwareImportProgress) -> Void)? = nil
    ) throws -> FirmwareBundleImportResult {
        importProgressHandler?(
            FirmwareImportProgress(message: "Ouverture du firmware", progress: 0.02)
        )
        let didAccess = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if didAccess {
                sourceURL.stopAccessingSecurityScopedResource()
            }
        }

        let sourceDirectory: URL
        let temporaryDirectory: URL?
        if isDirectory(sourceURL) {
            sourceDirectory = sourceURL
            temporaryDirectory = nil
            importProgressHandler?(
                FirmwareImportProgress(message: "Recherche des archives", progress: 0.18)
            )
        } else if sourceURL.pathExtension.lowercased() == "zip" {
            let extractionDirectory = FileManager.default.temporaryDirectory
                .appendingPathComponent("AndroidFLASH-Firmware-\(UUID().uuidString)", isDirectory: true)
            do {
                try FileManager.default.createDirectory(at: extractionDirectory, withIntermediateDirectories: true)
                try extractZip(
                    sourceURL,
                    to: extractionDirectory,
                    progressHandler: progressHandler,
                    importProgressHandler: importProgressHandler
                )
                importProgressHandler?(
                    FirmwareImportProgress(message: "Recherche des archives", progress: 0.32)
                )
            } catch {
                try? FileManager.default.removeItem(at: extractionDirectory)
                throw error
            }
            sourceDirectory = extractionDirectory
            temporaryDirectory = extractionDirectory
        } else {
            throw FirmwareBundleImportError.unsupportedSource(sourceURL.lastPathComponent)
        }

        let archiveURLs = findFirmwareArchiveURLs(in: sourceDirectory)
        guard !archiveURLs.isEmpty else {
            if let temporaryDirectory {
                try? FileManager.default.removeItem(at: temporaryDirectory)
            }
            throw FirmwareBundleImportError.noArchivesFound(sourceURL.lastPathComponent)
        }

        var archiveWorkItems: [(url: URL, slot: FirmwareSlot)] = []
        var loadedSlots: Set<FirmwareSlot> = []
        for archiveURL in archiveURLs {
            guard let slot = slot(forArchiveName: archiveURL.lastPathComponent),
                  loadedSlots.insert(slot).inserted else {
                continue
            }
            archiveWorkItems.append((archiveURL, slot))
        }

        do {
            var archives: [FirmwareArchive] = []
            let analysisStartProgress = temporaryDirectory == nil ? 0.22 : 0.36
            let analysisProgressSpan = temporaryDirectory == nil ? 0.74 : 0.60
            let archiveCount = max(archiveWorkItems.count, 1)

            for (index, item) in archiveWorkItems.enumerated() {
                let archiveURL = item.url
                let slot = item.slot
                let itemStartProgress = analysisStartProgress
                    + (Double(index) / Double(archiveCount)) * analysisProgressSpan
                let itemProgressSpan = analysisProgressSpan / Double(archiveCount)

                progressHandler?("Analyse firmware \(slot.rawValue) : \(archiveURL.lastPathComponent)")
                importProgressHandler?(
                    FirmwareImportProgress(message: "Analyse \(slot.rawValue)", progress: itemStartProgress)
                )
                let archive = try SamsungFirmwareArchiveReader.readArchive(url: archiveURL, slot: slot)
                archives.append(archive)
                progressHandler?("\(slot.rawValue) analysé : \(archive.entries.count) entrées TAR.")
                importProgressHandler?(
                    FirmwareImportProgress(
                        message: "\(slot.rawValue) analysé",
                        progress: itemStartProgress + itemProgressSpan
                    )
                )
            }

            guard !archives.isEmpty else {
                throw FirmwareBundleImportError.noArchivesFound(sourceURL.lastPathComponent)
            }

            importProgressHandler?(
                FirmwareImportProgress(message: "Validation du firmware", progress: 0.98)
            )
            return FirmwareBundleImportResult(
                archives: archives.sorted { lhs, rhs in
                    (FirmwareSlot.allCases.firstIndex(of: lhs.slot) ?? 0) < (FirmwareSlot.allCases.firstIndex(of: rhs.slot) ?? 0)
                },
                temporaryDirectory: temporaryDirectory
            )
        } catch {
            if let temporaryDirectory {
                try? FileManager.default.removeItem(at: temporaryDirectory)
            }
            throw error
        }
    }

    private static func extractZip(
        _ sourceURL: URL,
        to destinationURL: URL,
        progressHandler: ((String) -> Void)?,
        importProgressHandler: ((FirmwareImportProgress) -> Void)?
    ) throws {
        progressHandler?("Extraction ZIP : \(sourceURL.lastPathComponent)")
        importProgressHandler?(
            FirmwareImportProgress(message: "Préparation du ZIP", progress: 0.04)
        )

        let localZipURL = destinationURL.appendingPathComponent(sourceURL.lastPathComponent)
        try copyFile(sourceURL, to: localZipURL) { progress in
            importProgressHandler?(
                FirmwareImportProgress(
                    message: "Préparation du ZIP",
                    progress: 0.04 + 0.08 * progress
                )
            )
        }
        defer { try? FileManager.default.removeItem(at: localZipURL) }

        let expectedExtractedSize = max(fileSize(of: localZipURL), 1)
        importProgressHandler?(
            FirmwareImportProgress(message: "Extraction du ZIP", progress: 0.12)
        )

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-x", "-k", localZipURL.path, destinationURL.path]

        do {
            try process.run()
            while process.isRunning {
                Thread.sleep(forTimeInterval: 0.2)
                let extractedSize = extractedRegularFileSize(in: destinationURL, excluding: localZipURL)
                let extractionProgress = min(Double(extractedSize) / Double(expectedExtractedSize), 0.96)
                importProgressHandler?(
                    FirmwareImportProgress(
                        message: "Extraction du ZIP",
                        progress: 0.12 + 0.18 * extractionProgress
                    )
                )
            }
            process.waitUntilExit()
        } catch {
            throw FirmwareBundleImportError.extractionFailed(String(describing: error))
        }

        guard process.terminationStatus == 0 else {
            throw FirmwareBundleImportError.extractionFailed("ditto a retourné le code \(process.terminationStatus).")
        }

        importProgressHandler?(
            FirmwareImportProgress(message: "Extraction terminée", progress: 0.30)
        )
    }

    private static func copyFile(
        _ sourceURL: URL,
        to destinationURL: URL,
        progressHandler: ((Double) -> Void)? = nil
    ) throws {
        let input = try FileHandle(forReadingFrom: sourceURL)
        defer { try? input.close() }

        FileManager.default.createFile(atPath: destinationURL.path, contents: nil)
        let output = try FileHandle(forWritingTo: destinationURL)
        defer { try? output.close() }

        let totalSize = fileSize(of: sourceURL)
        var copiedSize: UInt64 = 0
        progressHandler?(0)

        while true {
            let data = input.readData(ofLength: 4 * 1024 * 1024)
            guard !data.isEmpty else { break }

            output.write(data)
            copiedSize += UInt64(data.count)

            if totalSize > 0 {
                progressHandler?(min(Double(copiedSize) / Double(totalSize), 1))
            }
        }

        progressHandler?(1)
    }

    private static func fileSize(of url: URL) -> UInt64 {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        return UInt64(max(size, 0))
    }

    private static func extractedRegularFileSize(in directoryURL: URL, excluding excludedURL: URL) -> UInt64 {
        guard let enumerator = FileManager.default.enumerator(
            at: directoryURL,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else {
            return 0
        }

        let excludedPath = excludedURL.standardizedFileURL.path
        return enumerator.reduce(UInt64(0)) { total, item in
            guard let url = item as? URL,
                  url.standardizedFileURL.path != excludedPath,
                  let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                  values.isRegularFile == true else {
                return total
            }

            return total + UInt64(max(values.fileSize ?? 0, 0))
        }
    }

    private static func findFirmwareArchiveURLs(in directoryURL: URL) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: directoryURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        return enumerator.compactMap { item -> URL? in
            guard let url = item as? URL else { return nil }
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey]), values.isRegularFile == true else {
                return nil
            }
            let name = url.lastPathComponent.lowercased()
            guard name.hasSuffix(".tar.md5") || name.hasSuffix(".tar") else {
                return nil
            }
            return slot(forArchiveName: url.lastPathComponent) == nil ? nil : url
        }
        .sorted { lhs, rhs in
            let leftSlot = slot(forArchiveName: lhs.lastPathComponent)
            let rightSlot = slot(forArchiveName: rhs.lastPathComponent)
            let leftIndex = leftSlot.flatMap { FirmwareSlot.allCases.firstIndex(of: $0) } ?? 0
            let rightIndex = rightSlot.flatMap { FirmwareSlot.allCases.firstIndex(of: $0) } ?? 0
            if leftIndex == rightIndex {
                return lhs.lastPathComponent < rhs.lastPathComponent
            }
            return leftIndex < rightIndex
        }
    }

    private static func slot(forArchiveName name: String) -> FirmwareSlot? {
        let uppercasedName = name.uppercased()
        if uppercasedName.hasPrefix("HOME_CSC_") { return .homeCSC }
        if uppercasedName.hasPrefix("BL_") { return .bl }
        if uppercasedName.hasPrefix("AP_") { return .ap }
        if uppercasedName.hasPrefix("CP_") { return .cp }
        if uppercasedName.hasPrefix("CSC_") { return .csc }
        return nil
    }

    private static func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }
}

enum FirmwarePayloadError: Error, LocalizedError, Equatable {
    case invalidLZ4Magic(String)
    case unsupportedLZ4Frame(String)
    case truncatedLZ4Frame(String)
    case invalidLZ4Block(String)
    case decompressionFailed(String)
    case externalLZ4Failed(String)
    case temporaryFileFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidLZ4Magic(let name):
            return "\(name) : format LZ4 invalide."
        case .unsupportedLZ4Frame(let reason):
            return "Frame LZ4 non supportee : \(reason)"
        case .truncatedLZ4Frame(let name):
            return "\(name) : données LZ4 incomplètes."
        case .invalidLZ4Block(let reason):
            return "Bloc LZ4 invalide : \(reason)"
        case .decompressionFailed(let reason):
            return "Décompression LZ4 impossible : \(reason)"
        case .externalLZ4Failed(let reason):
            return "Décompression LZ4 native impossible : \(reason)"
        case .temporaryFileFailed(let reason):
            return "Fichier temporaire impossible : \(reason)"
        }
    }
}

struct PreparedFirmwarePayloads {
    var mappings: [FirmwareMapping]
    var temporaryURLs: [URL]

    func cleanup() {
        for url in temporaryURLs {
            try? FileManager.default.removeItem(at: url)
        }
    }
}

enum FirmwarePayloadPreparer {
    static func prepare(
        mappings: [FirmwareMapping],
        preservesCompressedLZ4: Bool,
        requiresStandaloneFiles: Bool = false,
        progressHandler: ((String) -> Void)? = nil
    ) throws -> PreparedFirmwarePayloads {
        let containsCompressedPayloads = mappings.contains {
            $0.entry.fileName.lowercased().hasSuffix(".lz4")
        }

        guard containsCompressedPayloads || requiresStandaloneFiles else {
            return PreparedFirmwarePayloads(mappings: mappings, temporaryURLs: [])
        }

        if preservesCompressedLZ4 && !requiresStandaloneFiles {
            progressHandler?("Mode Odin LZ4 direct : les images .lz4 sont envoyées sans décompression locale.")
            return PreparedFirmwarePayloads(mappings: mappings, temporaryURLs: [])
        }

        if containsCompressedPayloads && !preservesCompressedLZ4 {
            progressHandler?("Mode Odin compatible : le bootloader ne déclare pas LZ4, décompression locale avant transfert.")
        }

        var preparedMappings: [FirmwareMapping] = []
        var temporaryURLs: [URL] = []

        do {
            for mapping in mappings {
                guard mapping.entry.fileName.lowercased().hasSuffix(".lz4") else {
                    if requiresStandaloneFiles {
                        let prepared = try extractStandaloneMapping(mapping)
                        preparedMappings.append(prepared.mapping)
                        temporaryURLs.append(prepared.temporaryURL)
                    } else {
                        preparedMappings.append(mapping)
                    }
                    continue
                }

                if preservesCompressedLZ4 {
                    let prepared = try extractStandaloneMapping(mapping)
                    preparedMappings.append(prepared.mapping)
                    temporaryURLs.append(prepared.temporaryURL)
                    continue
                }

                let prepared: (mapping: FirmwareMapping, temporaryURL: URL)
                if let lz4ExecutableURL = LZ4CommandLineDecoder.findExecutable() {
                    do {
                        progressHandler?("Décompression LZ4 native : \(mapping.slot.rawValue)/\(mapping.entry.fileName).")
                        var lastLoggedPercent = -1
                        prepared = try prepareLZ4MappingWithCommandLine(
                            mapping,
                            executableURL: lz4ExecutableURL
                        ) { consumedBytes, totalBytes in
                            guard totalBytes > 0 else { return }
                            let percent = min(100, Int((Double(consumedBytes) / Double(totalBytes)) * 100))
                            guard percent == 100 || percent >= lastLoggedPercent + 10 else { return }
                            lastLoggedPercent = percent
                            progressHandler?("Décompression \(mapping.entry.fileName) : \(percent)% lus.")
                        }
                    } catch {
                        progressHandler?(
                            "Décompression LZ4 native indisponible pour \(mapping.entry.fileName) : \(error.localizedDescription). Fallback Swift."
                        )
                        prepared = try prepareLZ4MappingWithSwiftFallback(mapping, progressHandler: progressHandler)
                    }
                } else {
                    prepared = try prepareLZ4MappingWithSwiftFallback(mapping, progressHandler: progressHandler)
                }

                preparedMappings.append(prepared.mapping)
                temporaryURLs.append(prepared.temporaryURL)
                progressHandler?(
                    "Image preparee : \(prepared.mapping.entry.fileName), \(ByteCountFormatter.string(fromByteCount: Int64(clamping: prepared.mapping.entry.size), countStyle: .file))."
                )
            }

            return PreparedFirmwarePayloads(
                mappings: preparedMappings,
                temporaryURLs: temporaryURLs
            )
        } catch {
            for url in temporaryURLs {
                try? FileManager.default.removeItem(at: url)
            }
            throw error
        }
    }

    private static func prepareLZ4MappingWithSwiftFallback(
        _ mapping: FirmwareMapping,
        progressHandler: ((String) -> Void)?
    ) throws -> (mapping: FirmwareMapping, temporaryURL: URL) {
        progressHandler?("Décompression LZ4 Swift : \(mapping.slot.rawValue)/\(mapping.entry.fileName).")
        var lastLoggedPercent = -1
        return try prepareLZ4Mapping(mapping) { consumedBytes, totalBytes, decodedBytes in
            guard totalBytes > 0 else { return }
            let percent = min(100, Int((Double(consumedBytes) / Double(totalBytes)) * 100))
            guard percent == 100 || percent >= lastLoggedPercent + 10 else { return }
            lastLoggedPercent = percent
            progressHandler?(
                "Décompression \(mapping.entry.fileName) : \(percent)% lus, \(ByteCountFormatter.string(fromByteCount: Int64(clamping: decodedBytes), countStyle: .file)) préparés."
            )
        }
    }

    private static func extractStandaloneMapping(
        _ mapping: FirmwareMapping
    ) throws -> (mapping: FirmwareMapping, temporaryURL: URL) {
        let didAccess = mapping.archiveURL.startAccessingSecurityScopedResource()
        defer {
            if didAccess {
                mapping.archiveURL.stopAccessingSecurityScopedResource()
            }
        }

        let outputName = mapping.entry.fileName
        let temporaryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("AndroidFLASH-\(UUID().uuidString)-\(outputName)")

        guard FileManager.default.createFile(atPath: temporaryURL.path, contents: nil) else {
            throw FirmwarePayloadError.temporaryFileFailed("création de \(temporaryURL.path) refusée.")
        }

        do {
            let input = try FileHandle(forReadingFrom: mapping.archiveURL)
            defer { try? input.close() }

            let output = try FileHandle(forWritingTo: temporaryURL)
            defer { try? output.close() }

            try input.seek(toOffset: mapping.entry.dataOffset)
            var remainingBytes = mapping.entry.size
            let chunkSize = 4 * 1024 * 1024

            while remainingBytes > 0 {
                let count = Int(min(UInt64(chunkSize), remainingBytes))
                let chunk = input.readData(ofLength: count)
                guard chunk.count == count else {
                    throw FirmwarePayloadError.temporaryFileFailed(
                        "extraction incomplète de \(mapping.entry.fileName) : \(chunk.count)/\(count) octets."
                    )
                }
                output.write(chunk)
                remainingBytes -= UInt64(chunk.count)
            }

            var preparedMapping = mapping
            preparedMapping.archiveURL = temporaryURL
            preparedMapping.entry = FirmwareArchiveEntry(
                path: outputName,
                size: mapping.entry.size,
                dataOffset: 0
            )
            return (preparedMapping, temporaryURL)
        } catch {
            try? FileManager.default.removeItem(at: temporaryURL)
            throw error
        }
    }

    private static func prepareLZ4MappingWithCommandLine(
        _ mapping: FirmwareMapping,
        executableURL: URL,
        progressHandler: ((UInt64, UInt64) -> Void)? = nil
    ) throws -> (mapping: FirmwareMapping, temporaryURL: URL) {
        let didAccess = mapping.archiveURL.startAccessingSecurityScopedResource()
        defer {
            if didAccess {
                mapping.archiveURL.stopAccessingSecurityScopedResource()
            }
        }

        let outputName = String(mapping.entry.fileName.dropLast(4))
        let temporaryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("AndroidFLASH-\(UUID().uuidString)-\(outputName)")

        guard FileManager.default.createFile(atPath: temporaryURL.path, contents: nil) else {
            throw FirmwarePayloadError.temporaryFileFailed("création de \(temporaryURL.path) refusée.")
        }

        do {
            let input = try FileHandle(forReadingFrom: mapping.archiveURL)
            defer { try? input.close() }

            let output = try FileHandle(forWritingTo: temporaryURL)
            defer { try? output.close() }

            let inputPipe = Pipe()
            let errorPipe = Pipe()
            let process = Process()
            process.executableURL = executableURL
            process.arguments = ["-d", "-c", "-"]
            process.standardInput = inputPipe
            process.standardOutput = output
            process.standardError = errorPipe

            do {
                try process.run()
            } catch {
                throw FirmwarePayloadError.externalLZ4Failed(String(describing: error))
            }

            try input.seek(toOffset: mapping.entry.dataOffset)
            var remainingBytes = mapping.entry.size
            var consumedBytes: UInt64 = 0
            let chunkSize = 4 * 1024 * 1024
            let pipeWriter = inputPipe.fileHandleForWriting

            while remainingBytes > 0 {
                let count = Int(min(UInt64(chunkSize), remainingBytes))
                let chunk = input.readData(ofLength: count)
                guard chunk.count == count else {
                    try? pipeWriter.close()
                    throw FirmwarePayloadError.temporaryFileFailed(
                        "lecture incomplète de \(mapping.entry.fileName) : \(chunk.count)/\(count) octets."
                    )
                }

                pipeWriter.write(chunk)
                remainingBytes -= UInt64(chunk.count)
                consumedBytes += UInt64(chunk.count)
                progressHandler?(consumedBytes, mapping.entry.size)
            }

            try pipeWriter.close()
            process.waitUntilExit()
            let errorOutput = String(
                decoding: errorPipe.fileHandleForReading.readDataToEndOfFile(),
                as: UTF8.self
            )
            .trimmingCharacters(in: .whitespacesAndNewlines)

            guard process.terminationStatus == 0 else {
                throw FirmwarePayloadError.externalLZ4Failed(
                    errorOutput.isEmpty ? "lz4 a retourné le code \(process.terminationStatus)." : errorOutput
                )
            }

            let outputSize = try FileManager.default
                .attributesOfItem(atPath: temporaryURL.path)[.size] as? NSNumber
            let decodedSize = outputSize?.uint64Value ?? 0

            var preparedMapping = mapping
            preparedMapping.archiveURL = temporaryURL
            preparedMapping.entry = FirmwareArchiveEntry(
                path: outputName,
                size: decodedSize,
                dataOffset: 0
            )
            return (preparedMapping, temporaryURL)
        } catch {
            try? FileManager.default.removeItem(at: temporaryURL)
            throw error
        }
    }

    private static func prepareLZ4Mapping(
        _ mapping: FirmwareMapping,
        progressHandler: ((UInt64, UInt64, UInt64) -> Void)? = nil
    ) throws -> (mapping: FirmwareMapping, temporaryURL: URL) {
        let didAccess = mapping.archiveURL.startAccessingSecurityScopedResource()
        defer {
            if didAccess {
                mapping.archiveURL.stopAccessingSecurityScopedResource()
            }
        }

        let outputName = String(mapping.entry.fileName.dropLast(4))
        let temporaryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("AndroidFLASH-\(UUID().uuidString)-\(outputName)")

        guard FileManager.default.createFile(atPath: temporaryURL.path, contents: nil) else {
            throw FirmwarePayloadError.temporaryFileFailed("création de \(temporaryURL.path) refusée.")
        }

        do {
            let input = try FileHandle(forReadingFrom: mapping.archiveURL)
            defer { try? input.close() }

            let output = try FileHandle(forWritingTo: temporaryURL)
            defer { try? output.close() }

            let decodedSize = try LZ4FrameDecoder.decodeFrame(
                from: input,
                offset: mapping.entry.dataOffset,
                length: mapping.entry.size,
                name: mapping.entry.fileName,
                to: output,
                progressHandler: progressHandler
            )

            var preparedMapping = mapping
            preparedMapping.archiveURL = temporaryURL
            preparedMapping.entry = FirmwareArchiveEntry(
                path: outputName,
                size: decodedSize,
                dataOffset: 0
            )
            return (preparedMapping, temporaryURL)
        } catch {
            try? FileManager.default.removeItem(at: temporaryURL)
            throw error
        }
    }
}

enum LZ4FrameDecoder {
    private static let magicNumber: UInt32 = 0x184D2204
    private static let endMarkSize = 4
    private static let dictionaryLimit = 64 * 1024

    @discardableResult
    static func decodeFrame(
        from handle: FileHandle,
        offset: UInt64,
        length: UInt64,
        name: String,
        to output: FileHandle,
        progressHandler: ((UInt64, UInt64, UInt64) -> Void)? = nil
    ) throws -> UInt64 {
        var reader = BoundedFileReader(handle: handle, offset: offset, length: length)

        let magic = try reader.readUInt32(name: name)
        guard magic == magicNumber else {
            throw FirmwarePayloadError.invalidLZ4Magic(name)
        }

        let flags = try reader.readByte(name: name)
        let blockDescriptor = try reader.readByte(name: name)
        guard flags & 0xC0 == 0x40 else {
            throw FirmwarePayloadError.unsupportedLZ4Frame("version invalide dans \(name).")
        }

        let usesIndependentBlocks = flags & 0x20 != 0
        let hasBlockChecksum = flags & 0x10 != 0
        let hasContentSize = flags & 0x08 != 0
        let hasContentChecksum = flags & 0x04 != 0
        let hasDictionaryID = flags & 0x01 != 0
        guard flags & 0x02 == 0 else {
            throw FirmwarePayloadError.unsupportedLZ4Frame("bit réservé activé dans \(name).")
        }

        let maximumBlockSize = try maximumBlockSize(from: blockDescriptor, name: name)
        if hasContentSize {
            _ = try reader.readData(count: 8, name: name)
        }
        if hasDictionaryID {
            _ = try reader.readData(count: 4, name: name)
        }
        _ = try reader.readByte(name: name) // Checksum d'en-tete.

        var decodedByteCount: UInt64 = 0
        var dictionary = Data()

        while reader.remainingBytes >= UInt64(endMarkSize) {
            let blockSizeField = try reader.readUInt32(name: name)
            if blockSizeField == 0 {
                if hasContentChecksum {
                    _ = try reader.readData(count: 4, name: name)
                }
                return decodedByteCount
            }

            let isUncompressedBlock = blockSizeField & 0x8000_0000 != 0
            let blockSize = Int(blockSizeField & 0x7FFF_FFFF)
            guard blockSize > 0 else {
                throw FirmwarePayloadError.invalidLZ4Block("\(name) contient un bloc vide inattendu.")
            }
            guard blockSize <= Int(reader.remainingBytes) else {
                throw FirmwarePayloadError.truncatedLZ4Frame(name)
            }

            let blockData = try reader.readData(count: blockSize, name: name)
            let decodedBlock: Data
            if isUncompressedBlock {
                guard blockData.count <= maximumBlockSize else {
                    throw FirmwarePayloadError.invalidLZ4Block("\(name) depasse la taille maximale de bloc.")
                }
                decodedBlock = blockData
            } else {
                decodedBlock = try decodeRawBlock(
                    blockData,
                    maximumOutputSize: maximumBlockSize,
                    dictionary: usesIndependentBlocks ? Data() : dictionary
                )
            }

            output.write(decodedBlock)
            decodedByteCount += UInt64(decodedBlock.count)
            progressHandler?(reader.currentOffset - offset, length, decodedByteCount)
            if usesIndependentBlocks {
                dictionary.removeAll(keepingCapacity: true)
            } else {
                dictionary.append(decodedBlock)
                if dictionary.count > dictionaryLimit {
                    dictionary.removeFirst(dictionary.count - dictionaryLimit)
                }
            }

            if hasBlockChecksum {
                _ = try reader.readData(count: 4, name: name)
            }
        }

        throw FirmwarePayloadError.truncatedLZ4Frame(name)
    }

    private static func maximumBlockSize(from descriptor: UInt8, name: String) throws -> Int {
        switch (descriptor >> 4) & 0x07 {
        case 4: return 64 * 1024
        case 5: return 256 * 1024
        case 6: return 1 * 1024 * 1024
        case 7: return 4 * 1024 * 1024
        default:
            throw FirmwarePayloadError.unsupportedLZ4Frame("taille de bloc invalide dans \(name).")
        }
    }

    private static func decodeRawBlock(
        _ data: Data,
        maximumOutputSize: Int,
        dictionary: Data
    ) throws -> Data {
        let input = Array(data)
        var index = 0
        var output: [UInt8] = []
        output.reserveCapacity(min(maximumOutputSize, max(data.count * 2, 64)))

        while index < input.count {
            let token = input[index]
            index += 1

            var literalLength = Int(token >> 4)
            if literalLength == 15 {
                literalLength += try readExtendedLength(from: input, index: &index)
            }

            guard index + literalLength <= input.count else {
                throw FirmwarePayloadError.invalidLZ4Block("longueur de litteraux hors limites.")
            }
            output.append(contentsOf: input[index..<index + literalLength])
            index += literalLength
            guard output.count <= maximumOutputSize else {
                throw FirmwarePayloadError.invalidLZ4Block("bloc decode trop grand.")
            }

            if index == input.count {
                break
            }

            guard index + 2 <= input.count else {
                throw FirmwarePayloadError.invalidLZ4Block("offset de copie incomplet.")
            }
            let offset = Int(input[index]) | (Int(input[index + 1]) << 8)
            index += 2
            guard offset > 0 else {
                throw FirmwarePayloadError.invalidLZ4Block("offset de copie nul.")
            }

            var matchLength = Int(token & 0x0F) + 4
            if token & 0x0F == 15 {
                matchLength += try readExtendedLength(from: input, index: &index)
            }

            try appendMatch(
                offset: offset,
                length: matchLength,
                output: &output,
                dictionary: dictionary,
                maximumOutputSize: maximumOutputSize
            )
        }

        return Data(output)
    }

    private static func readExtendedLength(from input: [UInt8], index: inout Int) throws -> Int {
        var length = 0
        while true {
            guard index < input.count else {
                throw FirmwarePayloadError.invalidLZ4Block("longueur étendue incomplète.")
            }
            let value = Int(input[index])
            index += 1
            length += value
            if value != 255 {
                return length
            }
        }
    }

    private static func appendMatch(
        offset: Int,
        length: Int,
        output: inout [UInt8],
        dictionary: Data,
        maximumOutputSize: Int
    ) throws {
        for _ in 0..<length {
            let sourceIndex = output.count - offset
            let byte: UInt8
            if sourceIndex >= 0 {
                byte = output[sourceIndex]
            } else {
                let dictionaryIndex = dictionary.count + sourceIndex
                guard dictionaryIndex >= 0 && dictionaryIndex < dictionary.count else {
                    throw FirmwarePayloadError.invalidLZ4Block("reference de dictionnaire hors limites.")
                }
                byte = dictionary[dictionaryIndex]
            }
            output.append(byte)
            guard output.count <= maximumOutputSize else {
                throw FirmwarePayloadError.invalidLZ4Block("bloc decode trop grand.")
            }
        }
    }
}

enum LZ4CommandLineDecoder {
    static func findExecutable() -> URL? {
        executableCandidates().first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    private static func executableCandidates() -> [URL] {
        var candidates: [URL] = []

        let environmentPath = ProcessInfo.processInfo.environment["PATH"] ?? ""
        for directory in environmentPath.split(separator: ":") {
            candidates.append(URL(fileURLWithPath: String(directory)).appendingPathComponent("lz4"))
        }

        candidates.append(contentsOf: [
            URL(fileURLWithPath: "/opt/homebrew/bin/lz4"),
            URL(fileURLWithPath: "/usr/local/bin/lz4"),
            URL(fileURLWithPath: "/opt/local/bin/lz4")
        ])

        var seenPaths: Set<String> = []
        return candidates.filter { seenPaths.insert($0.path).inserted }
    }
}

private struct BoundedFileReader {
    let handle: FileHandle
    let endOffset: UInt64
    var currentOffset: UInt64

    var remainingBytes: UInt64 {
        endOffset - currentOffset
    }

    init(handle: FileHandle, offset: UInt64, length: UInt64) {
        self.handle = handle
        self.currentOffset = offset
        self.endOffset = offset + length
    }

    mutating func readByte(name: String) throws -> UInt8 {
        let data = try readData(count: 1, name: name)
        guard let byte = data.first else {
            throw FirmwarePayloadError.truncatedLZ4Frame(name)
        }
        return byte
    }

    mutating func readUInt32(name: String) throws -> UInt32 {
        let data = try readData(count: 4, name: name)
        let bytes = Array(data)
        return UInt32(bytes[0]) |
            UInt32(bytes[1]) << 8 |
            UInt32(bytes[2]) << 16 |
            UInt32(bytes[3]) << 24
    }

    mutating func readData(count: Int, name: String) throws -> Data {
        guard count >= 0 && UInt64(count) <= remainingBytes else {
            throw FirmwarePayloadError.truncatedLZ4Frame(name)
        }

        try handle.seek(toOffset: currentOffset)
        let data = handle.readData(ofLength: count)
        guard data.count == count else {
            throw FirmwarePayloadError.truncatedLZ4Frame(name)
        }
        currentOffset += UInt64(count)
        return data
    }
}

enum FirmwareMapper {
    private static let partitionAliasesByImageName: [String: [String]] = [
        "modem": ["md1img"],
        "radio": ["md1img"],
        "preloader": ["bootloader"]
    ]

    private static let directHeimdallPartitions: Set<String> = [
        "bootloader", "lk", "param", "up_param", "efuse", "vbmeta",
        "boot", "recovery", "super", "userdata", "dpm_1", "dtbo",
        "gz1", "spmfw", "scp1", "sspm_1", "tee1", "tzar",
        "mcupm_1", "pi_img", "vbmeta_system", "vbmeta_vendor",
        "md1img", "misc", "md_udc", "spu", "cache", "omr", "prism", "optics"
    ]

    private static let directHeimdallPartitionAliasesByImageName: [String: String] = [
        "dpm-verified": "dpm_1",
        "dpm_verified": "dpm_1",
        "gz-verified": "gz1",
        "gz_verified": "gz1",
        "lk-verified": "lk",
        "lk_verified": "lk",
        "mcupm-verified": "mcupm_1",
        "mcupm_verified": "mcupm_1",
        "pi_img-verified": "pi_img",
        "pi_img_verified": "pi_img",
        "scp-verified": "scp1",
        "scp_verified": "scp1",
        "spmfw-verified": "spmfw",
        "spmfw_verified": "spmfw",
        "sspm-verified": "sspm_1",
        "sspm_verified": "sspm_1",
        "tee-verified": "tee1",
        "tee_verified": "tee1"
    ]

    static func validate(
        archives: [FirmwareArchive],
        pitEntries: [PitEntry],
        allowsDirectPartitionNames: Bool = false
    ) -> FirmwareValidationReport {
        let usesDirectPartitionNames = pitEntries.isEmpty && allowsDirectPartitionNames
        let flashablePartitions = pitEntries.filter(\.isFlashable)
        let partitionLookup = makePartitionLookup(from: flashablePartitions)

        var mappings: [FirmwareMapping] = []
        var unmatchedEntries: [FirmwareUnmatchedEntry] = []
        var warnings: [String] = []
        var skippedDuplicateArchiveSlots: Set<FirmwareSlot> = []
        var seenArchivePaths: [String: FirmwareSlot] = [:]

        if archives.contains(where: { $0.slot == .csc }) && archives.contains(where: { $0.slot == .homeCSC }) {
            warnings.append("CSC et HOME_CSC selectionnes : choisir un seul des deux avant le flash reel.")
        }

        for archive in archives {
            let path = archive.url.path
            if let firstSlot = seenArchivePaths[path] {
                warnings.append("\(archive.slot.rawValue) : meme archive que \(firstSlot.rawValue), elle est ignoree dans la validation pour eviter un double comptage.")
                skippedDuplicateArchiveSlots.insert(archive.slot)
            } else {
                seenArchivePaths[path] = archive.slot
            }
        }

        for archive in archives.sorted(by: { $0.slot.rawValue < $1.slot.rawValue }) {
            if skippedDuplicateArchiveSlots.contains(archive.slot) {
                continue
            }

            if archive.entries.isEmpty {
                warnings.append("\(archive.slot.rawValue) : aucune image trouvée dans \(archive.displayName).")
                continue
            }

            var seenMappingIDs: Set<String> = []
            var matchedInArchive = 0
            for (entryIndex, entry) in archive.entries.enumerated() {
                let partition: PitEntry?
                if usesDirectPartitionNames {
                    partition = directHeimdallPartition(for: entry)
                } else {
                    partition = partitionCandidates(for: entry)
                        .compactMap { partitionLookup[$0] }
                        .first
                }

                guard let partition else {
                    unmatchedEntries.append(
                        FirmwareUnmatchedEntry(
                            slot: archive.slot,
                            archiveName: archive.displayName,
                            entry: entry
                        )
                    )
                    continue
                }
                let mappingID = "\(archive.slot.rawValue):\(entry.path)->\(partition.partitionName)"
                guard seenMappingIDs.insert(mappingID).inserted else { continue }

                matchedInArchive += 1
                mappings.append(
                    FirmwareMapping(
                        slot: archive.slot,
                        archiveName: archive.displayName,
                        archiveURL: archive.url,
                        archiveEntryIndex: entryIndex,
                        entry: entry,
                        partition: partition
                    )
                )
            }

            if matchedInArchive == 0 {
                warnings.append("\(archive.slot.rawValue) : aucune entree ne correspond au PIT actuel.")
            }
        }

        var errors: [String] = []
        if pitEntries.isEmpty && !archives.isEmpty && !allowsDirectPartitionNames {
            warnings.append("Lire le PIT avant de valider un firmware.")
        }
        if archives.isEmpty {
            warnings.append("Aucune archive firmware selectionnee.")
        }
        warnings.append(contentsOf: duplicatePartitionWarnings(in: mappings))
        errors.append(contentsOf: criticalUnmatchedImageErrors(in: unmatchedEntries))

        return FirmwareValidationReport(
            mappings: mappings.sorted { lhs, rhs in
                let leftSlotIndex = FirmwareSlot.allCases.firstIndex(of: lhs.slot) ?? 0
                let rightSlotIndex = FirmwareSlot.allCases.firstIndex(of: rhs.slot) ?? 0
                if leftSlotIndex == rightSlotIndex {
                    return lhs.archiveEntryIndex < rhs.archiveEntryIndex
                }
                return leftSlotIndex < rightSlotIndex
            },
            unmatchedEntries: unmatchedEntries.sorted { lhs, rhs in
                let leftSlotIndex = FirmwareSlot.allCases.firstIndex(of: lhs.slot) ?? 0
                let rightSlotIndex = FirmwareSlot.allCases.firstIndex(of: rhs.slot) ?? 0
                if leftSlotIndex == rightSlotIndex {
                    return lhs.entry.fileName < rhs.entry.fileName
                }
                return leftSlotIndex < rightSlotIndex
            },
            warnings: warnings,
            errors: errors
        )
    }

    private static func makePartitionLookup(from entries: [PitEntry]) -> [String: PitEntry] {
        var lookup: [String: PitEntry] = [:]

        for entry in entries {
            add(entry, key: entry.partitionName, to: &lookup)
            add(entry, key: FirmwareArchiveEntry.normalizeImageName(entry.partitionName), to: &lookup)

            if !entry.flashFilename.isEmpty {
                add(entry, key: entry.flashFilename, to: &lookup)
                add(entry, key: FirmwareArchiveEntry.normalizeImageName(entry.flashFilename), to: &lookup)
            }
        }

        return lookup
    }

    private static func directHeimdallPartition(for entry: FirmwareArchiveEntry) -> PitEntry? {
        for candidate in partitionCandidates(for: entry) {
            let partitionName = directHeimdallPartitionAliasesByImageName[candidate] ?? candidate
            guard directHeimdallPartitions.contains(partitionName) else { continue }

            return PitEntry(
                binaryType: 0,
                deviceType: 0,
                identifier: 0,
                attributes: 0,
                updateAttributes: 0,
                blockSizeOrOffset: 0,
                blockCount: 0,
                fileOffset: 0,
                fileSize: 0,
                partitionName: partitionName,
                flashFilename: entry.fileName,
                fotaFilename: ""
            )
        }

        return nil
    }

    private static func add(_ entry: PitEntry, key: String, to lookup: inout [String: PitEntry]) {
        let normalizedKey = key.lowercased()
        guard !normalizedKey.isEmpty, lookup[normalizedKey] == nil else { return }
        lookup[normalizedKey] = entry
    }

    private static func partitionCandidates(for entry: FirmwareArchiveEntry) -> [String] {
        let normalizedName = entry.normalizedPartitionCandidate
        let fileName = entry.fileName.lowercased()
        let underscoreName = normalizedName.replacingOccurrences(of: "-", with: "_")

        var candidates: [String] = []
        appendCandidate(fileName, to: &candidates)
        appendCandidate(normalizedName, to: &candidates)
        appendCandidate(underscoreName, to: &candidates)

        for alias in partitionAliasesByImageName[normalizedName] ?? [] {
            appendCandidate(alias, to: &candidates)
        }

        return candidates
    }

    private static func appendCandidate(_ candidate: String, to candidates: inout [String]) {
        let normalizedCandidate = candidate.lowercased()
        guard !normalizedCandidate.isEmpty, !candidates.contains(normalizedCandidate) else { return }
        candidates.append(normalizedCandidate)
    }

    private static func duplicatePartitionWarnings(in mappings: [FirmwareMapping]) -> [String] {
        let groupedMappings = Dictionary(grouping: mappings, by: { $0.partition.partitionName })
        return groupedMappings
            .filter { $0.value.count > 1 }
            .map { partitionName, mappings in
                let sources = mappings
                    .sorted {
                        let leftSlotIndex = FirmwareSlot.allCases.firstIndex(of: $0.slot) ?? 0
                        let rightSlotIndex = FirmwareSlot.allCases.firstIndex(of: $1.slot) ?? 0
                        if leftSlotIndex == rightSlotIndex {
                            return $0.archiveEntryIndex < $1.archiveEntryIndex
                        }
                        return leftSlotIndex < rightSlotIndex
                    }
                    .map { "\($0.slot.rawValue)/\($0.entry.fileName)" }
                    .joined(separator: ", ")
                return "\(partitionName) : plusieurs images ciblent la meme partition (\(sources))."
            }
            .sorted()
    }

    private static func criticalUnmatchedImageErrors(in entries: [FirmwareUnmatchedEntry]) -> [String] {
        let criticalEntries = entries.filter { $0.entry.isFlashImageCandidate }
        guard !criticalEntries.isEmpty else { return [] }

        let listedEntries = criticalEntries
            .prefix(6)
            .map { "\($0.slot.rawValue)/\($0.entry.fileName)" }
            .joined(separator: ", ")
        let extraCount = criticalEntries.count - min(criticalEntries.count, 6)
        let suffix = extraCount > 0 ? " (+\(extraCount))" : ""
        return [
            "Images firmware non associées à une partition : \(listedEntries)\(suffix). Flash bloqué pour éviter un package partiel."
        ]
    }
}
