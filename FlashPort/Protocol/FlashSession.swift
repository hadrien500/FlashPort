import Foundation

/// Etat de progression communique a l'interface utilisateur.
enum FlashSessionState: Equatable {
    case idle
    case preparingFirmware
    case connecting
    case handshaking
    case readingPIT
    case flashing(partition: String, progress: Double)
    case finishing
    case completed
    case failed(String)
}

enum OdinProtocolError: Error, LocalizedError {
    case transportFailure(context: String, reason: String)
    case responseTooShort(context: String, expected: Int, actual: Int)
    case unexpectedResponseType(context: String, expected: UInt32, actual: UInt32)
    case unexpectedResponseValue(context: String, expected: UInt32, actual: UInt32)
    case invalidPitSize(UInt32)
    case incompletePitPart(index: Int, expected: Int, actual: Int)
    case fileTooLarge(context: String, size: UInt64)
    case incompleteFirmwarePart(context: String, expected: Int, actual: Int)
    case binaryRejected(context: String, code: UInt32)

    var errorDescription: String? {
        switch self {
        case .transportFailure(let context, let reason):
            return "\(context) : \(reason)"
        case .responseTooShort(let context, let expected, let actual):
            return "\(context) : réponse trop courte (\(actual)/\(expected) octets)."
        case .unexpectedResponseType(let context, let expected, let actual):
            if actual == UInt32.max {
                return "\(context) : le bootloader a refusé la séquence (0xFFFFFFFF). Cause probable : downgrade bloqué par Samsung, firmware d'un mauvais modèle, ou image incompatible."
            }
            return "\(context) : type de réponse inattendu, attendu 0x\(String(expected, radix: 16, uppercase: true)), reçu 0x\(String(actual, radix: 16, uppercase: true))."
        case .unexpectedResponseValue(let context, let expected, let actual):
            return "\(context) : valeur de réponse inattendue, attendu \(expected), reçu \(actual)."
        case .invalidPitSize(let size):
            return "Taille PIT invalide ou trop grande : \(size) octets."
        case .incompletePitPart(let index, let expected, let actual):
            return "Bloc PIT #\(index) incomplet : \(actual)/\(expected) octets reçus."
        case .fileTooLarge(let context, let size):
            return "\(context) : fichier trop grand pour ce paquet Odin 32 bits (\(size) octets)."
        case .incompleteFirmwarePart(let context, let expected, let actual):
            return "\(context) : bloc firmware incomplet (\(actual)/\(expected) octets lus)."
        case .binaryRejected(let context, let code):
            return "\(context) : le bootloader a refusé le binaire (code 0x\(String(code, radix: 16, uppercase: true))). Binaire non officiel sur bootloader verrouillé ? Un recovery custom (TWRP) exige le déverrouillage OEM du bootloader."
        }
    }
}

struct FirmwareFlashProgress: Equatable {
    var mapping: FirmwareMapping
    var bytesSentForEntry: UInt64
    var totalBytesForEntry: UInt64
    var bytesSentOverall: UInt64
    var totalBytesOverall: UInt64

    var entryProgress: Double {
        guard totalBytesForEntry > 0 else { return 0 }
        return Double(bytesSentForEntry) / Double(totalBytesForEntry)
    }

    var overallProgress: Double {
        guard totalBytesOverall > 0 else { return 0 }
        return Double(bytesSentOverall) / Double(totalBytesOverall)
    }
}

/// Orchestre une session complète de flash Odin sur un terminal connecté.
///
/// Séquence : handshake -> ouverture de session -> déclaration du type de
/// peripheriques -> transfert PIT (optionnel selon confirmation utilisateur)
/// -> pour chaque partition selectionnee : begin flash, envoi des blocs de
/// données, end flash -> fin de session -> redémarrage.
final class FlashSession {

    private let device: USBDevice
    private(set) var state: FlashSessionState = .idle
    private var fileTransferPacketSize = OdinProtocol.defaultFilePartSize
    private var fileTransferSequenceMaxLength = OdinProtocol.defaultFileTransferSequenceMaxLength
    private var fileTransferSequenceTimeout = OdinProtocol.defaultFileTransferSequenceTimeout
    private var supportsCompressedFileTransfer = false

    var canSendCompressedFirmware: Bool {
        supportsCompressedFileTransfer
    }

    init(device: USBDevice) {
        self.device = device
    }

    /// Etablit le handshake initial ODIN/LOKE.
    func handshake(maxAttempts: Int = 3) throws {
        state = .handshaking

        var lastFailure = "aucune tentative effectuee"
        let attemptCount = max(1, maxAttempts)

        for attempt in 1...attemptCount {
            do {
                try device.discardPendingData()
                try device.send(Data(OdinProtocol.handshakeRequest))
                let response = try device.receive(maxLength: 4)
                guard Array(response) == OdinProtocol.handshakeResponse else {
                    lastFailure = "tentative \(attempt) : réponse reçue \(hexDescription(response)), attendu LOKE."
                    continue
                }
                return
            } catch {
                lastFailure = "tentative \(attempt) : \(localizedReason(for: error))"
            }

            if attempt < attemptCount {
                Thread.sleep(forTimeInterval: 0.35 * Double(attempt))
            }
        }

        state = .failed("Handshake Odin impossible")
        throw OdinProtocolError.transportFailure(
            context: "Handshake Odin",
            reason: lastFailure
        )
    }

    /// Ouvre une session Odin et negocie la taille des blocs de fichier si le
    /// terminal l'accepte.
    @discardableResult
    func beginSession() throws -> UInt32 {
        let packet = SessionCommandPacket(
            controlType: OdinProtocol.ControlType.session.rawValue,
            request: OdinProtocol.SessionRequest.beginSession.rawValue,
            payload: [OdinProtocol.requestedProtocolVersion]
        )
        try device.send(packet.serialize())
        let protocolResponse = try receiveResponse(
            expectedType: .session,
            context: "Ouverture de session Odin"
        )

        supportsCompressedFileTransfer = protocolResponse & OdinProtocol.compressedTransferSupportFlag != 0

        if protocolResponse != 0 {
            fileTransferPacketSize = OdinProtocol.negotiatedFilePartSize
            fileTransferSequenceMaxLength = OdinProtocol.negotiatedFileTransferSequenceMaxLength
            fileTransferSequenceTimeout = OdinProtocol.negotiatedFileTransferSequenceTimeout

            let filePartSizePacket = SessionCommandPacket(
                controlType: OdinProtocol.ControlType.session.rawValue,
                request: OdinProtocol.SessionRequest.filePartSize.rawValue,
                payload: [UInt32(OdinProtocol.negotiatedFilePartSize)]
            )
            try device.send(filePartSizePacket.serialize())
            let response = try receiveResponse(
                expectedType: .session,
                context: "Negociation taille des blocs"
            )
            guard response == 0 else {
                throw OdinProtocolError.unexpectedResponseValue(
                    context: "Negociation taille des blocs",
                    expected: 0,
                    actual: response
                )
            }
        }

        return protocolResponse
    }

    func flashFirmware(
        mappings: [FirmwareMapping],
        rebootAfterFlash: Bool,
        eraseNANDBeforeFlash: Bool = false,
        keepSessionOpenAfterFlash: Bool = false,
        progressHandler: ((String) -> Void)? = nil,
        flashProgressHandler: ((FirmwareFlashProgress) -> Void)? = nil
    ) throws {
        guard !mappings.isEmpty else { return }

        let orderedMappings = mappings.sorted { lhs, rhs in
            let leftSlotIndex = FirmwareSlot.allCases.firstIndex(of: lhs.slot) ?? 0
            let rightSlotIndex = FirmwareSlot.allCases.firstIndex(of: rhs.slot) ?? 0
            if leftSlotIndex == rightSlotIndex {
                return lhs.archiveEntryIndex < rhs.archiveEntryIndex
            }
            return leftSlotIndex < rightSlotIndex
        }
        state = .connecting
        progressHandler?("Handshake Odin (3 tentatives max).")
        try handshake()
        progressHandler?("Handshake ODIN/LOKE valide.")

        progressHandler?("Ouverture session Odin.")
        let defaultPacketSize = try beginSession()
        progressHandler?("Session Odin ouverte, réponse protocole : \(Self.hex(defaultPacketSize)).")

        try flashFirmwareInCurrentSession(
            mappings: orderedMappings,
            rebootAfterFlash: rebootAfterFlash,
            eraseNANDBeforeFlash: eraseNANDBeforeFlash,
            keepSessionOpenAfterFlash: keepSessionOpenAfterFlash,
            progressHandler: progressHandler,
            flashProgressHandler: flashProgressHandler
        )
    }

    func flashFirmwareInCurrentSession(
        mappings: [FirmwareMapping],
        rebootAfterFlash: Bool,
        eraseNANDBeforeFlash: Bool = false,
        keepSessionOpenAfterFlash: Bool = false,
        progressHandler: ((String) -> Void)? = nil,
        flashProgressHandler: ((FirmwareFlashProgress) -> Void)? = nil
    ) throws {
        let orderedMappings = mappings.sorted { lhs, rhs in
            let leftSlotIndex = FirmwareSlot.allCases.firstIndex(of: lhs.slot) ?? 0
            let rightSlotIndex = FirmwareSlot.allCases.firstIndex(of: rhs.slot) ?? 0
            if leftSlotIndex == rightSlotIndex {
                return lhs.archiveEntryIndex < rhs.archiveEntryIndex
            }
            return leftSlotIndex < rightSlotIndex
        }
        try flashOrderedMappingsInCurrentSession(
            orderedMappings,
            rebootAfterFlash: rebootAfterFlash,
            eraseNANDBeforeFlash: eraseNANDBeforeFlash,
            keepSessionOpenAfterFlash: keepSessionOpenAfterFlash,
            progressHandler: progressHandler,
            flashProgressHandler: flashProgressHandler
        )
    }

    private func flashOrderedMappingsInCurrentSession(
        _ orderedMappings: [FirmwareMapping],
        rebootAfterFlash: Bool,
        eraseNANDBeforeFlash: Bool,
        keepSessionOpenAfterFlash: Bool,
        progressHandler: ((String) -> Void)?,
        flashProgressHandler: ((FirmwareFlashProgress) -> Void)?
    ) throws {
        guard !orderedMappings.isEmpty else { return }

        var shouldEndSessionOnExit = true
        defer {
            if shouldEndSessionOnExit {
                try? endSession(reboot: false)
            }
        }

        if eraseNANDBeforeFlash {
            try eraseNAND(progressHandler: progressHandler)
        }

        let totalBytes = orderedMappings.reduce(UInt64(0)) { $0 + $1.entry.size }
        try sendTotalTransferSize(totalBytes)
        progressHandler?("Taille totale annoncee : \(ByteCountFormatter.string(fromByteCount: Int64(clamping: totalBytes), countStyle: .file)).")

        var bytesSentOverall: UInt64 = 0
        for (mappingIndex, mapping) in orderedMappings.enumerated() {
            let destination = mapping.partition.binaryType == 1
                ? OdinProtocol.FileTransferDestination.modem
                : OdinProtocol.FileTransferDestination.phone
            state = .flashing(partition: mapping.partition.partitionName, progress: 0)
            progressHandler?("Flash \(mapping.partition.partitionName) depuis \(mapping.slot.rawValue)/\(mapping.entry.fileName).")

            try flashEntry(
                mapping,
                destination: destination,
                bytesSentOverall: &bytesSentOverall,
                totalBytesOverall: totalBytes,
                progressHandler: progressHandler,
                flashProgressHandler: flashProgressHandler
            )
            progressHandler?("\(mapping.partition.partitionName) terminé.")

            let partitionDelay = interPartitionDelay(after: mapping)
            if mappingIndex < orderedMappings.count - 1 && partitionDelay > 0 {
                progressHandler?("Pause Odin avant la partition suivante.")
                Thread.sleep(forTimeInterval: partitionDelay)
            }
        }

        state = .finishing
        if keepSessionOpenAfterFlash && !rebootAfterFlash {
            shouldEndSessionOnExit = false
            state = .completed
            progressHandler?("Session Odin conservee ouverte pour Quitter Download.")
            return
        }

        progressHandler?("Fermeture session Odin.")
        do {
            try endSession(reboot: rebootAfterFlash)
        } catch {
            shouldEndSessionOnExit = false
            state = .completed
            progressHandler?("Avertissement fermeture session : \(localizedReason(for: error))")
            progressHandler?("Images transférées et confirmées avant l'avertissement de fermeture.")
            return
        }
        shouldEndSessionOnExit = false
        state = .completed
        progressHandler?(rebootAfterFlash ? "Session terminée, redémarrage demandé." : "Session terminée sans redémarrage automatique.")
    }

    /// Télécharge et parse la table PIT du terminal. Cette opération est en
    /// lecture seule et ne modifie pas le téléphone.
    func readPitFile(progressHandler: ((String) -> Void)? = nil, closeSession: Bool = true) throws -> PitFile {
        state = .readingPIT
        progressHandler?("Ouverture session Odin.")
        let defaultPacketSize = try beginSession()
        progressHandler?("Session Odin ouverte, réponse protocole : \(Self.hex(defaultPacketSize)).")

        let pitData = try downloadPitData(progressHandler: progressHandler)
        let pitFile = try PitFile.parse(pitData)

        if closeSession {
            progressHandler?("Fermeture session Odin.")
            do {
                try endSession()
            } catch {
                progressHandler?("Avertissement fermeture session : \(localizedReason(for: error))")
            }
        } else {
            progressHandler?("Session Odin conservee ouverte pour le flash.")
        }

        state = .completed
        return pitFile
    }

    /// Envoie l'option Odin "NAND Erase", equivalent pratique d'un effacement
    /// userdata sur les bootloaders qui supportent cette commande.
    func eraseNAND(progressHandler: ((String) -> Void)? = nil) throws {
        state = .flashing(partition: "Erase NAND", progress: 0)
        progressHandler?("Erase NAND : commande Odin envoyée.")

        let packet = SessionCommandPacket(
            controlType: OdinProtocol.ControlType.session.rawValue,
            request: OdinProtocol.SessionRequest.eraseUserData.rawValue,
            payload: []
        )
        try device.send(packet.serialize())

        let response = try receiveResponse(
            expectedType: .session,
            context: "Erase NAND",
            timeout: OdinProtocol.eraseUserDataTimeout
        )
        guard response == 0 else {
            throw OdinProtocolError.unexpectedResponseValue(
                context: "Erase NAND",
                expected: 0,
                actual: response
            )
        }

        state = .flashing(partition: "Erase NAND", progress: 1)
        progressHandler?("Erase NAND terminé.")
    }

    func rebootFromDownloadMode(progressHandler: ((String) -> Void)? = nil) throws {
        state = .connecting
        progressHandler?("Sortie Download Mode : handshake Odin.")
        try handshake()
        progressHandler?("Handshake ODIN/LOKE valide.")

        progressHandler?("Ouverture session Odin.")
        let defaultPacketSize = try beginSession()
        progressHandler?("Session Odin ouverte, réponse protocole : \(Self.hex(defaultPacketSize)).")

        try rebootFromCurrentSession(progressHandler: progressHandler)
    }

    func rebootFromResumedDownloadMode(progressHandler: ((String) -> Void)? = nil) throws {
        state = .finishing
        progressHandler?("Sortie Download Mode : reprise session Odin sans handshake.")
        do {
            try rebootCurrentSessionDirectly(progressHandler: progressHandler)
        } catch {
            progressHandler?("Sortie Download Mode : commande directe refusée, tentative fin de session.")
            try rebootFromCurrentSession(progressHandler: progressHandler)
        }
    }

    func rebootFromCurrentSession(progressHandler: ((String) -> Void)? = nil) throws {
        state = .finishing
        progressHandler?("Sortie Download Mode : redémarrage demandé.")
        try endSession(reboot: true)
        state = .completed
        progressHandler?("Commande de redémarrage envoyée.")
    }

    func sendRebootCommandWithoutHandshake(progressHandler: ((String) -> Void)? = nil) throws {
        state = .finishing
        progressHandler?("Sortie Download Mode : commande reboot directe.")
        try sendRebootPacket(expectResponse: false)
        state = .completed
        progressHandler?("Commande de redémarrage envoyée.")
    }

    /// Exécute la séquence complète pour la liste de FlashJob fournie.
    func run(jobs: [FlashJob], progressHandler: @escaping (FlashSessionState) -> Void) {
        do {
            state = .connecting
            progressHandler(state)
            try device.open()

            try handshake()
            progressHandler(state)

            try beginSession()

            for job in jobs {
                guard let url = job.fileURL else { continue }
                state = .flashing(partition: job.partitionName, progress: 0)
                progressHandler(state)
                try flashPartition(job: job, fileURL: url, progressHandler: progressHandler)
            }

            state = .finishing
            progressHandler(state)
            try endSession()

            state = .completed
            progressHandler(state)
        } catch {
            let reason = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
            state = .failed(reason)
            progressHandler(state)
        }
    }

    private func flashPartition(job: FlashJob, fileURL: URL, progressHandler: @escaping (FlashSessionState) -> Void) throws {
        // Séquence par partition : commande begin flash (avec taille totale),
        // envoi des blocs de fileHandle en respectant sessionPacketSize ou
        // la taille de segment negociee, commande end flash.
        //
        // Lecture par blocs pour éviter de charger l'image complète en
        // mémoire (les images AP peuvent dépasser plusieurs gigaoctets).
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }

        let totalSize = job.fileSize
        var sent: Int64 = 0
        let chunkSize = 131072 // 128 Ko, taille de segment a confirmer

        while true {
            let chunk = handle.readData(ofLength: chunkSize)
            if chunk.isEmpty { break }
            try device.send(chunk)
            sent += Int64(chunk.count)
            let progress = totalSize > 0 ? Double(sent) / Double(totalSize) : 0
            state = .flashing(partition: job.partitionName, progress: progress)
            progressHandler(state)
        }
    }

    private func sendTotalTransferSize(_ totalBytes: UInt64) throws {
        try device.send(totalTransferSizePacket(totalBytes))

        let response = try receiveResponse(
            expectedType: .session,
            context: "Declaration taille totale"
        )
        guard response == 0 else {
            throw OdinProtocolError.unexpectedResponseValue(
                context: "Declaration taille totale",
                expected: 0,
                actual: response
            )
        }
    }

    private func totalTransferSizePacket(_ totalBytes: UInt64) -> Data {
        var data = Data()
        Self.appendUInt32(OdinProtocol.ControlType.session.rawValue, to: &data)
        Self.appendUInt32(OdinProtocol.SessionRequest.totalBytes.rawValue, to: &data)
        Self.appendUInt64(totalBytes, to: &data)
        if data.count < OdinProtocol.sessionPacketSize {
            data.append(Data(repeating: 0, count: OdinProtocol.sessionPacketSize - data.count))
        }
        return data
    }

    private func flashEntry(
        _ mapping: FirmwareMapping,
        destination: OdinProtocol.FileTransferDestination,
        bytesSentOverall: inout UInt64,
        totalBytesOverall: UInt64,
        progressHandler: ((String) -> Void)?,
        flashProgressHandler: ((FirmwareFlashProgress) -> Void)?
    ) throws {
        let didAccess = mapping.archiveURL.startAccessingSecurityScopedResource()
        defer {
            if didAccess {
                mapping.archiveURL.stopAccessingSecurityScopedResource()
            }
        }

        let handle = try FileHandle(forReadingFrom: mapping.archiveURL)
        defer { try? handle.close() }
        try handle.seek(toOffset: mapping.entry.dataOffset)

        let fileSize = mapping.entry.size
        let usesCompressedTransfer = mapping.entry.fileName.lowercased().hasSuffix(".lz4")
        if usesCompressedTransfer && !supportsCompressedFileTransfer {
            throw OdinProtocolError.transportFailure(
                context: mapping.partition.partitionName,
                reason: "le bootloader n'annonce pas le support du transfert LZ4 compresse"
            )
        }
        if usesCompressedTransfer {
            progressHandler?("Transfert LZ4 compresse actif pour \(mapping.partition.partitionName).")
        }

        try beginFileTransfer(compressed: usesCompressedTransfer)

        let packetSize = UInt64(fileTransferPacketSize)
        let sequenceCapacity = UInt64(fileTransferSequenceMaxLength) * packetSize
        let sequenceCount = Int((fileSize + sequenceCapacity - 1) / sequenceCapacity)
        let sequenceLogStride = max(1, sequenceCount / 10)
        let partialPacketByteCount = fileSize % packetSize
        var bytesSentForEntry: UInt64 = 0

        for sequenceIndex in 0..<sequenceCount {
            let isLastSequence = sequenceIndex == sequenceCount - 1
            let shouldLogSequenceDetails = sequenceCount <= 12
                || sequenceIndex == 0
                || isLastSequence
                || (sequenceIndex + 1).isMultiple(of: sequenceLogStride)
            let remainingBytes = fileSize - UInt64(sequenceIndex) * sequenceCapacity
            let sequenceSize = Int(min(UInt64(fileTransferSequenceMaxLength), (remainingBytes + packetSize - 1) / packetSize))
            let sequenceTotalByteCount = UInt32(sequenceSize * fileTransferPacketSize)

            if shouldLogSequenceDetails {
                progressHandler?("Séquence \(sequenceIndex + 1)/\(sequenceCount) pour \(mapping.partition.partitionName) : \(sequenceSize) blocs.")
            }
            try beginFileTransferSequence(byteCount: sequenceTotalByteCount, compressed: usesCompressedTransfer)

            for filePartIndex in 0..<sequenceSize {
                let chunk = try readFirmwarePacket(
                    from: handle,
                    mapping: mapping,
                    bytesSentForEntry: bytesSentForEntry
                )
                let sendEmptyBefore = filePartIndex != 0

                try sendFirmwarePacketWithRetry(
                    chunk,
                    expectedPartIndex: UInt32(filePartIndex),
                    emptyTransferBefore: sendEmptyBefore,
                    context: "\(mapping.partition.partitionName) bloc \(filePartIndex + 1)/\(sequenceSize)"
                )

                let usefulByteCount = min(packetSize, fileSize - bytesSentForEntry)
                bytesSentForEntry += usefulByteCount
                bytesSentOverall += usefulByteCount
                let progress = FirmwareFlashProgress(
                    mapping: mapping,
                    bytesSentForEntry: bytesSentForEntry,
                    totalBytesForEntry: fileSize,
                    bytesSentOverall: bytesSentOverall,
                    totalBytesOverall: totalBytesOverall
                )
                state = .flashing(partition: mapping.partition.partitionName, progress: progress.overallProgress)
                flashProgressHandler?(progress)
            }

            let sequenceEffectiveByteCount: UInt32
            if isLastSequence && partialPacketByteCount != 0 {
                sequenceEffectiveByteCount = UInt32((sequenceSize - 1) * fileTransferPacketSize) + UInt32(partialPacketByteCount)
            } else {
                sequenceEffectiveByteCount = sequenceTotalByteCount
            }

            if shouldLogSequenceDetails {
                progressHandler?(
                    "Fin séquence \(mapping.partition.partitionName) : \(sequenceEffectiveByteCount) octets, destination \(destination.rawValue), deviceType \(mapping.partition.deviceType), identifiant \(mapping.partition.identifier), EOF \(isLastSequence ? 1 : 0)."
                )
            }
            try endFileTransferSequence(
                byteCount: sequenceEffectiveByteCount,
                destination: destination,
                deviceType: mapping.partition.deviceType,
                fileIdentifier: mapping.partition.identifier,
                isLastSequence: isLastSequence,
                context: mapping.partition.partitionName,
                compressed: usesCompressedTransfer
            )
        }
    }

    private func interPartitionDelay(after mapping: FirmwareMapping) -> TimeInterval {
        let largePartitionThreshold = UInt64(512 * 1024 * 1024)
        if mapping.entry.size >= largePartitionThreshold {
            return OdinProtocol.largePartitionFlashDelay
        }
        return OdinProtocol.interPartitionFlashDelay
    }

    private func beginFileTransfer(compressed: Bool) throws {
        let packet = SessionCommandPacket(
            controlType: OdinProtocol.ControlType.fileTransfer.rawValue,
            request: compressed
                ? OdinProtocol.FileTransferRequest.compressedFlash.rawValue
                : OdinProtocol.FileTransferRequest.flash.rawValue,
            payload: []
        )
        try device.send(packet.serialize())
        _ = try receiveResponse(
            expectedType: .fileTransfer,
            context: "Initialisation transfert fichier"
        )
    }

    private func beginFileTransferSequence(byteCount: UInt32, compressed: Bool) throws {
        let packet = SessionCommandPacket(
            controlType: OdinProtocol.ControlType.fileTransfer.rawValue,
            request: compressed
                ? OdinProtocol.FileTransferRequest.compressedPart.rawValue
                : OdinProtocol.FileTransferRequest.part.rawValue,
            payload: [byteCount]
        )
        try device.send(packet.serialize())
        _ = try receiveResponse(
            expectedType: .fileTransfer,
            context: "Début séquence transfert fichier"
        )
    }

    private func sendFirmwarePacketWithRetry(
        _ packet: Data,
        expectedPartIndex: UInt32,
        emptyTransferBefore: Bool,
        context: String
    ) throws {
        var lastError: Error?

        for attempt in 0..<5 {
            do {
                try sendPacket(packet, emptyTransferBefore: emptyTransferBefore)
                let receivedPartIndex = try receiveSendFilePartResponse(context: context)
                guard receivedPartIndex == expectedPartIndex else {
                    throw OdinProtocolError.unexpectedResponseValue(
                        context: context,
                        expected: expectedPartIndex,
                        actual: receivedPartIndex
                    )
                }
                return
            } catch {
                lastError = error
                if attempt < 4 {
                    Thread.sleep(forTimeInterval: 0.25 * Double(attempt + 1))
                }
            }
        }

        throw lastError ?? OdinProtocolError.transportFailure(context: context, reason: "échec inconnu")
    }

    private func endFileTransferSequence(
        byteCount: UInt32,
        destination: OdinProtocol.FileTransferDestination,
        deviceType: UInt32,
        fileIdentifier: UInt32,
        isLastSequence: Bool,
        context: String,
        compressed: Bool
    ) throws {
        var payload: [UInt32] = [
            destination.rawValue,
            byteCount,
            0,
            deviceType
        ]

        switch destination {
        case .phone:
            payload.append(fileIdentifier)
            payload.append(isLastSequence ? 1 : 0)
        case .modem:
            payload.append(isLastSequence ? 1 : 0)
        }

        let packet = SessionCommandPacket(
            controlType: OdinProtocol.ControlType.fileTransfer.rawValue,
            request: compressed
                ? OdinProtocol.FileTransferRequest.compressedEnd.rawValue
                : OdinProtocol.FileTransferRequest.end.rawValue,
            payload: payload
        )
        try sendPacket(packet.serialize(), emptyTransferBefore: true, emptyTransferAfter: true)
        let responseValue = try receiveResponse(
            expectedType: .fileTransfer,
            context: "Fin séquence \(context)",
            timeout: isLastSequence
                ? max(fileTransferSequenceTimeout, OdinProtocol.finalSequenceTimeout)
                : fileTransferSequenceTimeout
        )

        // Convention Odin : 0 = accepté. Un code non nul ici signale un refus
        // du binaire par le bootloader (ex. image non signée Samsung sur
        // bootloader verrouillé), que les données aient été transférées ou non.
        guard responseValue == 0 else {
            throw OdinProtocolError.binaryRejected(context: context, code: responseValue)
        }
    }

    private func readFirmwarePacket(
        from handle: FileHandle,
        mapping: FirmwareMapping,
        bytesSentForEntry: UInt64
    ) throws -> Data {
        let remainingBytes = mapping.entry.size - bytesSentForEntry
        let bytesToRead = Int(min(UInt64(fileTransferPacketSize), remainingBytes))
        let chunk = handle.readData(ofLength: bytesToRead)
        guard chunk.count == bytesToRead else {
            throw OdinProtocolError.incompleteFirmwarePart(
                context: mapping.entry.fileName,
                expected: bytesToRead,
                actual: chunk.count
            )
        }

        if chunk.count == fileTransferPacketSize {
            return chunk
        }

        var paddedChunk = chunk
        paddedChunk.append(Data(repeating: 0, count: fileTransferPacketSize - chunk.count))
        return paddedChunk
    }

    private func sendPacket(_ data: Data, emptyTransferBefore: Bool = false, emptyTransferAfter: Bool = false) throws {
        if emptyTransferBefore {
            try? device.send(Data())
        }

        try device.send(data)

        if emptyTransferAfter {
            try? device.send(Data())
        }
    }

    private func endSession(reboot: Bool = false) throws {
        let packet = SessionCommandPacket(
            controlType: OdinProtocol.ControlType.endSession.rawValue,
            request: OdinProtocol.EndSessionRequest.end.rawValue,
            payload: []
        )
        try device.send(packet.serialize())
        _ = try receiveResponse(
            expectedType: .endSession,
            context: "Fin de session Odin",
            timeout: OdinProtocol.endSessionTimeout
        )

        if reboot {
            let rebootPacket = SessionCommandPacket(
                controlType: OdinProtocol.ControlType.endSession.rawValue,
                request: OdinProtocol.EndSessionRequest.reboot.rawValue,
                payload: []
            )
            try device.send(rebootPacket.serialize())
        }
    }

    private func rebootCurrentSessionDirectly(progressHandler: ((String) -> Void)? = nil) throws {
        try sendRebootPacket(expectResponse: false)
        state = .completed
        progressHandler?("Commande de redémarrage envoyée.")
    }

    private func sendRebootPacket(expectResponse: Bool) throws {
        let rebootPacket = SessionCommandPacket(
            controlType: OdinProtocol.ControlType.endSession.rawValue,
            request: OdinProtocol.EndSessionRequest.reboot.rawValue,
            payload: []
        )
        try device.send(rebootPacket.serialize())

        if expectResponse {
            _ = try receiveResponse(
                expectedType: .endSession,
                context: "Redemarrage du terminal"
            )
        }
    }

    private func downloadPitData(progressHandler: ((String) -> Void)? = nil) throws -> Data {
        progressHandler?("Demande taille PIT.")
        let dumpRequest = SessionCommandPacket(
            controlType: OdinProtocol.ControlType.pitFile.rawValue,
            request: OdinProtocol.PitRequest.dump.rawValue,
            payload: []
        )
        try device.send(dumpRequest.serialize())

        let pitSize = try receiveResponse(
            expectedType: .pitFile,
            context: "Taille PIT"
        )
        guard pitSize > 0 && pitSize <= UInt32(OdinProtocol.maximumPitFileSize) else {
            throw OdinProtocolError.invalidPitSize(pitSize)
        }

        let transferCount = Int((pitSize + UInt32(OdinProtocol.pitFilePartSize) - 1) / UInt32(OdinProtocol.pitFilePartSize))
        progressHandler?("Taille PIT reçue : \(pitSize) octets, \(transferCount) blocs.")
        var pitData = Data()
        pitData.reserveCapacity(Int(pitSize))

        for partIndex in 0..<transferCount {
            progressHandler?("Reception bloc PIT \(partIndex + 1)/\(transferCount).")
            let partRequest = SessionCommandPacket(
                controlType: OdinProtocol.ControlType.pitFile.rawValue,
                request: OdinProtocol.PitRequest.part.rawValue,
                payload: [UInt32(partIndex)]
            )
            try device.send(partRequest.serialize())

            let remaining = Int(pitSize) - pitData.count
            let expectedLength = min(OdinProtocol.pitFilePartSize, remaining)
            let part: Data
            do {
                part = try device.receive(maxLength: expectedLength)
            } catch {
                throw OdinProtocolError.transportFailure(
                    context: "Reception bloc PIT \(partIndex + 1)/\(transferCount)",
                    reason: localizedReason(for: error)
                )
            }
            guard part.count == expectedLength else {
                throw OdinProtocolError.incompletePitPart(
                    index: partIndex,
                    expected: expectedLength,
                    actual: part.count
                )
            }
            pitData.append(part)
        }

        let endTransferRequest = SessionCommandPacket(
            controlType: OdinProtocol.ControlType.pitFile.rawValue,
            request: OdinProtocol.PitRequest.endTransfer.rawValue,
            payload: []
        )
        try device.send(endTransferRequest.serialize())
        progressHandler?("Confirmation fin transfert PIT.")
        _ = try receiveResponse(
            expectedType: .pitFile,
            context: "Fin du transfert PIT"
        )

        return pitData
    }

    private func receiveResponse(
        expectedType: OdinProtocol.ControlType,
        context: String,
        timeout: TimeInterval? = nil
    ) throws -> UInt32 {
        try receiveResponse(
            expectedResponseType: expectedType.rawValue,
            context: context,
            timeout: timeout
        )
    }

    private func receiveSendFilePartResponse(context: String) throws -> UInt32 {
        try receiveResponse(
            expectedResponseType: OdinProtocol.ResponseType.sendFilePart.rawValue,
            context: context,
            timeout: nil
        )
    }

    private func receiveResponse(
        expectedResponseType: UInt32,
        context: String,
        timeout: TimeInterval?
    ) throws -> UInt32 {
        let response: Data
        do {
            response = try device.receive(maxLength: OdinProtocol.responsePacketSize, timeout: timeout)
        } catch {
            throw OdinProtocolError.transportFailure(
                context: context,
                reason: localizedReason(for: error)
            )
        }
        guard response.count >= OdinProtocol.responsePacketSize else {
            throw OdinProtocolError.responseTooShort(
                context: context,
                expected: OdinProtocol.responsePacketSize,
                actual: response.count
            )
        }

        let bytes = Array(response)
        let responseType = readUInt32(bytes, at: 0)
        guard responseType == expectedResponseType else {
            throw OdinProtocolError.unexpectedResponseType(
                context: context,
                expected: expectedResponseType,
                actual: responseType
            )
        }

        return readUInt32(bytes, at: 4)
    }

    private func localizedReason(for error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? String(describing: error)
    }

    private func hexDescription(_ data: Data) -> String {
        guard !data.isEmpty else { return "aucune donnee" }
        return data.map { String(format: "%02X", $0) }.joined(separator: " ")
    }

    private func readUInt32(_ bytes: [UInt8], at offset: Int) -> UInt32 {
        UInt32(bytes[offset]) |
        UInt32(bytes[offset + 1]) << 8 |
        UInt32(bytes[offset + 2]) << 16 |
        UInt32(bytes[offset + 3]) << 24
    }

    private static func appendUInt32(_ value: UInt32, to data: inout Data) {
        var littleEndian = value.littleEndian
        withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
    }

    private static func appendUInt64(_ value: UInt64, to data: inout Data) {
        var littleEndian = value.littleEndian
        withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
    }

    private static func hex(_ value: UInt32) -> String {
        String(format: "0x%X", value)
    }
}
