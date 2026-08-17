import AppKit
import Foundation
import Observation
import UserNotifications

enum FlashBackend: String, CaseIterable, Identifiable {
    case heimdall
    case nativeSwift

    var id: String { rawValue }

    var title: String {
        switch self {
        case .heimdall:
            return "Heimdall (externe)"
        case .nativeSwift:
            return "Natif (Swift)"
        }
    }
}

enum CompletedOperation: Equatable {
    case odinTest
    case pitRead
    case exitDownloadMode
    case flash
}

struct FlashHistoryEntry: Identifiable, Codable, Equatable {
    var id: String
    var date: Date
    var result: String
    var firmwareName: String
    var deviceName: String
    var backendName: String
    var selectedImageCount: Int
    var selectedSize: UInt64
    var dataModeTitle: String
    var detail: String
}

@MainActor
@Observable
final class FlashViewModel {

    private static let knownCustomRecoveryDeviceNamesByCodename: [String: String] = [
        "a13ve": "Galaxy A13 4G Mediatek",
        "a22x": "Galaxy A22 5G"
    ]

    private static let knownCustomRecoveryCodenamesByModelCode: [String: Set<String>] = [
        "A226B": ["a22x"]
    ]
    private static let maximumLogLineCount = 4_000
    private static let flashHistoryDefaultsKey = "FlashPort.flashHistoryEntries"
    private static let maximumFlashHistoryCount = 30
    private static let flashBackendDefaultsKey = "FlashPort.flashBackend"
    private static let rebootAfterFlashDefaultsKey = "FlashPort.rebootAfterFlash"
    private static let firmwareDataModeDefaultsKey = "FlashPort.firmwareDataMode"

    var jobs: [FlashJob] = StandardPartition.allCases.map {
        FlashJob(partitionName: $0.rawValue, fileURL: nil)
    }
    var state: FlashSessionState = .idle
    var logLines: [String] = []
    var isDeviceConnected = false
    var isSearchingDownloadModeDevice = true
    var connectedDeviceDescription: String?
    var pitEntries: [PitEntry] = []
    var firmwareArchives: [FirmwareArchive] = []
    var firmwareMappings: [FirmwareMapping] = []
    var firmwareUnmatchedEntries: [FirmwareUnmatchedEntry] = []
    var firmwareWarnings: [String] = []
    var firmwareErrors: [String] = []
    var selectedFirmwareMappingIDs: Set<String> = []
    var firmwareDataMode: FirmwareDataMode = .preserve
    var importedFirmwareSourceName: String?
    var isImportingFirmware = false
    var realFlashConfirmation = ""
    var rebootAfterFlash = true
    var nandEraseBeforeFlash = false
    var flashBackend: FlashBackend = .nativeSwift
    var expectedDeviceModelCode = ""
    var currentBootloaderRevision = ""
    var detectedDeviceModelCode: String?
    var firmwareModelCodes: [String] = []
    var firmwareBootloaderRevisions: [Int] = []
    var firmwarePackageMetadata: FirmwarePackageMetadata = .empty
    var firmwareCompatibilitySummary = "Modèle firmware non détecté."
    var firmwareCompatibilityWarnings: [String] = []
    var firmwareCompatibilityErrors: [String] = []
    var firmwareImportProgress: FirmwareImportProgress?
    var completedOperation: CompletedOperation?
    var isReadingPitBeforeFlash = false
    var flashHistoryEntries: [FlashHistoryEntry] = []
    var flashRemainingTimeText: String?

    @ObservationIgnored
    private var session: FlashSession?

    @ObservationIgnored
    private var activeDevice: USBDevice?

    @ObservationIgnored
    private var hasReusableOdinSession = false

    @ObservationIgnored
    private var availableFirmwareArchives: [FirmwareArchive] = []

    @ObservationIgnored
    private var importedTemporaryDirectories: [URL] = []

    @ObservationIgnored
    private var lastPreparationReportSignature: String?

    @ObservationIgnored
    private var deviceDetectionTask: Task<Void, Never>?

    @ObservationIgnored
    private var automaticDeviceMissCount = 0

    @ObservationIgnored
    private var flashActivityToken: NSObjectProtocol?

    init() {
        loadFlashHistory()
        loadPersistedSettings()
        cleanupStaleTemporaryFiles()
    }

    deinit {
        deviceDetectionTask?.cancel()
        for directory in importedTemporaryDirectories {
            try? FileManager.default.removeItem(at: directory)
        }
    }

    var canTestOdinConnection: Bool {
        isDeviceConnected && !isBusy
    }

    var canReadPit: Bool {
        isDeviceConnected && pitEntries.isEmpty && !isBusy && !hasReusableOdinSession
    }

    var canExitDownloadMode: Bool {
        guard !isBusy, !hasCustomRecoveryFlashSelection else { return false }
        return isDeviceConnected
            || hasReusableOdinSession
            || USBDevice.findDownloadModeDevice() != nil
    }

    var canStartFlash: Bool {
        canPrepareFlashSelection
            && !selectedFirmwareMappings.isEmpty
            && selectedDuplicatePartitionNames.isEmpty
            && !hasIncompatibleUserdataSelection
    }

    var canStartRealFlash: Bool {
        canStartFlash
            && (!requiresHeimdallForCurrentFlash || isHeimdallAvailable)
    }

    var canStartRealFlashOrPrepare: Bool {
        canStartRealFlash || canReadPitBeforeRealFlash
    }

    var canReadPitBeforeRealFlash: Bool {
        flashBackend == .nativeSwift
            && !hasLoadedPit
            && canReadPit
            && !firmwareArchives.isEmpty
            && firmwareCompatibilityErrors.isEmpty
            && !hasExclusiveCscConflict
    }

    var hasOpenOdinSession: Bool {
        hasReusableOdinSession
    }

    var heimdallExecutableURL: URL? {
        HeimdallFlashRunner.findExecutable()
    }

    var isHeimdallAvailable: Bool {
        heimdallExecutableURL != nil
    }

    var heimdallInstallWarningText: String? {
        guard !isHeimdallAvailable else { return nil }
        if flashBackend == .heimdall && hasCustomRecoveryFlashSelection {
            return nil
        }
        if flashBackend == .heimdall {
            return "Heimdall est introuvable. Installe Heimdall/libusb ou repasse sur le moteur Natif (Swift) dans les paramètres avancés."
        }
        return nil
    }

    var flashBackendStatusText: String {
        switch flashBackend {
        case .heimdall:
            if let executableURL = heimdallExecutableURL {
                return "Backend Heimdall externe : \(executableURL.path). La table de partitions peut être lue automatiquement."
            }
            return "Heimdall introuvable : installe-le, ou choisis le moteur Natif (Swift)."
        case .nativeSwift:
            return "Moteur natif Swift : USB bulk rapide quand macOS l'autorise, port série USB en secours."
        }
    }

    var firmwareMappingSourceName: String {
        if hasLoadedPit {
            return "PIT"
        }
        if flashBackend == .heimdall {
            return "Heimdall"
        }
        return "PIT"
    }

    var hasFirmwareMappingSource: Bool {
        hasLoadedPit || flashBackend == .heimdall
    }

    var selectedFirmwareMappings: [FirmwareMapping] {
        firmwareMappings.filter { selectedFirmwareMappingIDs.contains($0.id) }
    }

    var selectedFlashSize: UInt64 {
        selectedFirmwareMappings.reduce(UInt64(0)) { $0 + $1.entry.size }
    }

    var hasCustomRecoveryFlashSelection: Bool {
        isCustomRecoveryFlashSelection(selectedFirmwareMappings)
    }

    var canEnableRebootAfterFlash: Bool {
        !hasCustomRecoveryFlashSelection
    }

    var customRecoveryBootNoticeText: String? {
        guard hasCustomRecoveryFlashSelection else { return nil }

        let bootNotice = "TWRP détecté : garde le redémarrage automatique désactivé. Après le flash, quitte Download puis maintiens Volume Haut + Power jusqu'à l'écran TWRP. Si Android démarre, le recovery stock peut revenir."
        guard let compatibilityWarning = customRecoveryCompatibilityWarnings(for: selectedFirmwareMappings).first else {
            return bootNotice
        }

        return "\(compatibilityWarning) \(bootNotice)"
    }

    var preserveDataModeWarningText: String? {
        guard firmwareDataMode == .preserve, !firmwareArchives.isEmpty else { return nil }
        return "Sans effacement : FlashPort exclut userdata et utilise HOME_CSC, mais Android peut encore demander une réinitialisation si les anciennes données ne peuvent plus être montées."
    }

    var selectionWarnings: [String] {
        var warnings: [String] = []

        if canPrepareFlashSelection && selectedFirmwareMappings.isEmpty {
            warnings.append("Sélectionner au moins une image à flasher.")
        }

        for partitionName in selectedDuplicatePartitionNames {
            warnings.append("\(partitionName) : plusieurs images sélectionnées pour la même partition.")
        }

        if nandEraseBeforeFlash {
            warnings.append("Erase NAND : userdata sera efface via Odin avant le flash.")
        }

        let hasUserdataMapping = firmwareMappings.contains { $0.partition.partitionName == "userdata" }
        let hasSelectedUserdata = selectedFirmwareMappings.contains { $0.partition.partitionName == "userdata" }

        if hasSelectedUserdata {
            if firmwareDataMode == .erase {
                if flashBackend == .heimdall {
                    warnings.append("userdata : le flash réel basculera en Swift natif pour garder une seule session Odin.")
                } else {
                    warnings.append("userdata : transfert volumineux ; l'envoi peut prendre du temps.")
                }
            } else {
                warnings.append("userdata : sélection incompatible avec le mode Sans effacement.")
            }
        } else if firmwareDataMode == .erase && hasUserdataMapping {
            if flashBackend == .heimdall {
                warnings.append("Effacer données : le flash réel utilisera Swift natif en session unique pour finaliser userdata correctement.")
            } else {
                warnings.append("Effacer données : sélectionner userdata pour formater les données via Swift/Odin.")
            }
        }

        if let preserveDataModeWarningText {
            warnings.append(preserveDataModeWarningText)
        }

        if hasCustomRecoveryFlashSelection {
            warnings.append("Bootloader : le flash d'un binaire non officiel (TWRP) échoue si le bootloader est verrouillé. Active « Déverrouillage OEM » puis déverrouille le bootloader (Download Mode, appui long Volume Haut — efface les données) avant de flasher.")
            warnings.append("TWRP/recovery custom : ne démarre pas Android après le flash ; démarre directement en recovery.")
            warnings.append(contentsOf: customRecoveryCompatibilityWarnings(for: selectedFirmwareMappings))
        }

        if flashBackend == .heimdall && requiresNativeSwiftForCustomRecovery(selectedFirmwareMappings) {
            warnings.append("Recovery custom/TWRP : le flash réel utilisera Swift natif pour cibler le nom PIT exact.")
        }

        if flashBackend == .heimdall && containsHeimdallOversizedImage(selectedFirmwareMappings) {
            warnings.append("super : plus de 4 Go une fois décompressé ; le flash réel utilisera la session Swift native (Heimdall tronque au-delà de 4 Go).")
        }

        let disallowedSelectedNames = selectedFirmwareMappings
            .filter { !isAllowedByDownloadList($0) }
            .map { "\($0.slot.rawValue)/\($0.entry.fileName)" }
        if !disallowedSelectedNames.isEmpty {
            warnings.append("Hors download-list Odin : \(disallowedSelectedNames.joined(separator: ", ")). Odin ne flashe pas ces images avec ce firmware ; les envoyer peut déclencher une réinitialisation des données.")
        }

        return warnings
    }

    var hasLoadedPit: Bool {
        !pitEntries.isEmpty
    }

    var normalizedExpectedDeviceModelCode: String? {
        FirmwareCompatibilityValidator.normalizedDeviceModelCode(expectedDeviceModelCode)
    }

    var normalizedCurrentBootloaderRevision: Int? {
        FirmwareCompatibilityValidator.bootloaderRevisionCode(from: currentBootloaderRevision)
    }

    func startAutomaticDeviceDetection() {
        guard deviceDetectionTask == nil else { return }
        appendLog("Recherche automatique du terminal Download Mode.")
        deviceDetectionTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                self.refreshAutomaticDeviceDetection()
                try? await Task.sleep(nanoseconds: 1_500_000_000)
            }
        }
    }

    func stopAutomaticDeviceDetection() {
        deviceDetectionTask?.cancel()
        deviceDetectionTask = nil
        isSearchingDownloadModeDevice = false
    }

    func checkDeviceConnection() {
        if hasReusableOdinSession, let activeDevice {
            applyDeviceConnection(activeDevice, logResult: false, automatic: false)
            appendLog("Terminal détecté : \(activeDevice.displayName) (session Odin ouverte).")
            return
        }

        let device = USBDevice.findDownloadModeDevice()
        applyDeviceConnection(device, logResult: true, automatic: false)
    }

    func setFile(_ url: URL, for partitionName: String) {
        guard let index = jobs.firstIndex(where: { $0.partitionName == partitionName }) else { return }
        jobs[index].fileURL = url
        appendLog("Fichier assigné à la partition \(partitionName) : \(url.lastPathComponent)")
    }

    func firmwareArchive(for slot: FirmwareSlot) -> FirmwareArchive? {
        firmwareArchives.first { $0.slot == slot }
    }

    func importFirmwareBundle(_ url: URL) {
        isImportingFirmware = true
        state = .idle
        completedOperation = nil
        isReadingPitBeforeFlash = false
        firmwareImportProgress = FirmwareImportProgress(
            message: "Ouverture du firmware",
            progress: 0.02
        )
        appendLog("Import firmware complet : \(url.lastPathComponent)")

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let appendProgress: (String) -> Void = { [weak self] line in
                DispatchQueue.main.async { [weak self] in
                    self?.appendLog(line)
                }
            }
            let updateImportProgress: (FirmwareImportProgress) -> Void = { [weak self] progress in
                DispatchQueue.main.async { [weak self] in
                    self?.firmwareImportProgress = progress
                }
            }

            do {
                let result = try FirmwareBundleImporter.importArchives(
                    from: url,
                    progressHandler: appendProgress,
                    importProgressHandler: updateImportProgress
                )

                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.replaceTemporaryImportDirectory(with: result.temporaryDirectory)
                    self.availableFirmwareArchives = result.archives
                    self.importedFirmwareSourceName = url.lastPathComponent
                    self.applyActiveFirmwareArchives(autoSelect: true)
                    self.firmwareImportProgress = FirmwareImportProgress(
                        message: "Firmware chargé",
                        progress: 1,
                        isComplete: true
                    )
                    self.isImportingFirmware = false
                    self.appendLog("Import firmware terminé : \(result.archives.count) archives reconnues.")
                }
            } catch {
                let reason = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.firmwareImportProgress = FirmwareImportProgress(
                        message: "Échec import firmware",
                        progress: 0,
                        isFailed: true
                    )
                    self.isImportingFirmware = false
                    self.appendLog("Échec import firmware : \(reason)")
                }
            }
        }
    }

    /// Importe un recovery personnalisé (TWRP) et ses images associées
    /// (vbmeta…) : accepte un ou plusieurs fichiers .img/.img.lz4/.tar/.tar.md5
    /// ou un dossier. Chaque image est mappée sur sa partition et le tout
    /// remplace la sélection firmware en cours.
    func importRecoveryImages(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        isImportingFirmware = true
        state = .idle
        completedOperation = nil
        isReadingPitBeforeFlash = false
        firmwareImportProgress = FirmwareImportProgress(
            message: "Analyse du recovery",
            progress: 0.2
        )
        let sourceName = urls.count == 1
            ? urls[0].lastPathComponent
            : "\(urls.count) fichiers recovery"
        appendLog("Import recovery personnalisé : \(sourceName)")

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                let prepared = try RecoveryImageImporter.makeArchive(from: urls)
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.replaceTemporaryImportDirectory(with: prepared.temporaryDirectory)
                    self.availableFirmwareArchives = [prepared.archive]
                    self.importedFirmwareSourceName = sourceName
                    self.applyActiveFirmwareArchives(autoSelect: true)
                    self.firmwareImportProgress = FirmwareImportProgress(
                        message: "Recovery chargé",
                        progress: 1,
                        isComplete: true
                    )
                    self.isImportingFirmware = false
                    let targets = prepared.archive.entries.map(\.fileName).joined(separator: ", ")
                    self.appendLog("Recovery prêt : \(targets).")
                    self.appendLog("TWRP : redémarrage automatique désactivé. Après le flash, quitte Download puis maintiens Volume Haut + Power jusqu'à TWRP.")
                    self.appendLog("Rappel : le flash d'un binaire non officiel exige un bootloader déverrouillé (Déverrouillage OEM).")
                }
            } catch {
                let reason = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.firmwareImportProgress = FirmwareImportProgress(
                        message: "Échec import recovery",
                        progress: 0,
                        isFailed: true
                    )
                    self.isImportingFirmware = false
                    self.appendLog("Échec import recovery : \(reason)")
                }
            }
        }
    }

    func setFirmwareArchive(_ url: URL, for slot: FirmwareSlot) {
        isImportingFirmware = true
        state = .idle
        completedOperation = nil
        isReadingPitBeforeFlash = false
        firmwareImportProgress = FirmwareImportProgress(
            message: "Analyse \(slot.rawValue)",
            progress: 0.02
        )
        appendLog("Analyse firmware \(slot.rawValue) : \(url.lastPathComponent)")

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                let hasValidMd5 = try FirmwareMd5Verifier.verify(url: url) { progress in
                    DispatchQueue.main.async { [weak self] in
                        self?.firmwareImportProgress = FirmwareImportProgress(
                            message: "Vérification MD5 \(slot.rawValue)",
                            progress: progress * 0.5
                        )
                    }
                }
                if hasValidMd5 {
                    DispatchQueue.main.async { [weak self] in
                        self?.appendLog("\(slot.rawValue) : somme MD5 valide.")
                    }
                }

                let archive = try SamsungFirmwareArchiveReader.readArchive(url: url, slot: slot) { progress in
                    DispatchQueue.main.async { [weak self] in
                        self?.firmwareImportProgress = FirmwareImportProgress(
                            message: "Analyse \(slot.rawValue)",
                            progress: 0.5 + progress * 0.5
                        )
                    }
                }
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.replaceAvailableFirmwareArchive(archive, autoSelect: true)
                    self.firmwareImportProgress = FirmwareImportProgress(
                        message: "\(slot.rawValue) chargé",
                        progress: 1,
                        isComplete: true
                    )
                    self.isImportingFirmware = false
                    self.appendLog("\(slot.rawValue) analysé : \(archive.entries.count) entrées TAR.")
                }
            } catch {
                let reason = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.removeFirmwareArchive(for: slot)
                    self.firmwareImportProgress = FirmwareImportProgress(
                        message: "Échec analyse \(slot.rawValue)",
                        progress: 0,
                        isFailed: true
                    )
                    self.isImportingFirmware = false
                    self.appendLog("Échec analyse \(slot.rawValue) : \(reason)")
                }
            }
        }
    }

    func removeFirmwareArchive(for slot: FirmwareSlot) {
        availableFirmwareArchives.removeAll { $0.slot == slot }
        applyActiveFirmwareArchives(autoSelect: true)
        appendLog("Archive \(slot.rawValue) retiree.")
    }

    func clearFirmwareBundle() {
        for directory in importedTemporaryDirectories {
            try? FileManager.default.removeItem(at: directory)
        }
        importedTemporaryDirectories.removeAll()
        availableFirmwareArchives.removeAll()
        firmwareArchives.removeAll()
        firmwareMappings.removeAll()
        firmwareUnmatchedEntries.removeAll()
        firmwareWarnings.removeAll()
        firmwareErrors.removeAll()
        firmwareModelCodes.removeAll()
        firmwareBootloaderRevisions.removeAll()
        firmwarePackageMetadata = .empty
        firmwareCompatibilityWarnings.removeAll()
        firmwareCompatibilityErrors.removeAll()
        firmwareCompatibilitySummary = "Modèle firmware non détecté."
        selectedFirmwareMappingIDs.removeAll()
        importedFirmwareSourceName = nil
        firmwareImportProgress = nil
        completedOperation = nil
        isReadingPitBeforeFlash = false
        realFlashConfirmation = ""
        lastPreparationReportSignature = nil
        appendLog("Firmware retire : selectionne un nouveau ZIP ou dossier.")
    }

    /// Remet l'application dans son état d'accueil pour enchaîner un nouveau
    /// flash : firmware retiré, sélection vidée, journal effacé, session Odin
    /// éventuelle fermée. La détection automatique du téléphone continue.
    var canResetSession: Bool {
        if isBusy { return false }
        return importedFirmwareSourceName != nil
            || !availableFirmwareArchives.isEmpty
            || !firmwareArchives.isEmpty
            || !logLines.isEmpty
            || completedOperation != nil
            || hasReusableOdinSession
            || {
                if case .idle = state { return false }
                return true
            }()
    }

    func resetForNewFlash() {
        guard !isBusy else {
            appendLog("Réinitialisation impossible : une opération est en cours.")
            return
        }

        releaseReusableOdinSession()
        clearFirmwareBundle()
        pitEntries.removeAll()
        jobs = StandardPartition.allCases.map { FlashJob(partitionName: $0.rawValue, fileURL: nil) }
        state = .idle
        completedOperation = nil
        isReadingPitBeforeFlash = false
        flashRemainingTimeText = nil
        realFlashConfirmation = ""
        lastPreparationReportSignature = nil
        logLines.removeAll()
        appendLog("Page réinitialisée : prêt pour un nouveau flash.")
    }

    func setFirmwareDataMode(_ mode: FirmwareDataMode) {
        guard firmwareDataMode != mode else { return }
        resetCompletedOperation()
        firmwareDataMode = mode
        applyActiveFirmwareArchives(autoSelect: true)
        appendLog("Mode données utilisateur : \(mode.title).")
        persistSettings()
        if let preserveDataModeWarningText {
            appendLog(preserveDataModeWarningText)
        }
    }

    func setNandEraseBeforeFlash(_ enabled: Bool) {
        guard nandEraseBeforeFlash != enabled else { return }
        resetCompletedOperation()
        nandEraseBeforeFlash = enabled
        realFlashConfirmation = ""
        lastPreparationReportSignature = nil
        appendLog(enabled ? "Erase NAND activé." : "Erase NAND désactivé.")
    }

    func setRebootAfterFlash(_ enabled: Bool) {
        if enabled && hasCustomRecoveryFlashSelection {
            rebootAfterFlash = false
            appendLog("TWRP : redémarrage automatique bloqué. Après le flash, quitte Download puis maintiens Volume Haut + Power pour lancer TWRP.")
            return
        }

        guard rebootAfterFlash != enabled else { return }
        resetCompletedOperation()
        rebootAfterFlash = enabled
        realFlashConfirmation = ""
        lastPreparationReportSignature = nil
        appendLog(enabled ? "Redémarrage après flash activé." : "Redémarrage après flash désactivé.")
        persistSettings()
    }

    func setFlashBackend(_ backend: FlashBackend) {
        guard flashBackend != backend else { return }
        resetCompletedOperation()
        flashBackend = backend
        refreshFirmwareValidation()
        if !firmwareMappings.isEmpty {
            selectRecommendedFirmwareMappings()
        }
        appendLog("Backend flash : \(backend.title).")
        persistSettings()
    }

    func setExpectedDeviceModelCode(_ modelCode: String) {
        let formattedModelCode = FirmwareCompatibilityValidator.formattedDeviceModelInput(modelCode)
        guard expectedDeviceModelCode != formattedModelCode else { return }
        expectedDeviceModelCode = formattedModelCode
        refreshFirmwareValidation()
    }

    func setCurrentBootloaderRevision(_ revision: String) {
        let formattedRevision = FirmwareCompatibilityValidator.formattedBootloaderRevisionInput(revision)
        guard currentBootloaderRevision != formattedRevision else { return }
        currentBootloaderRevision = formattedRevision
        refreshFirmwareValidation()
    }

    func setFirmwareMappingSelection(_ mappingID: String, isSelected: Bool) {
        if isSelected {
            resetCompletedOperation()
            selectedFirmwareMappingIDs.insert(mappingID)
        } else {
            resetCompletedOperation()
            selectedFirmwareMappingIDs.remove(mappingID)
        }
        realFlashConfirmation = ""
        lastPreparationReportSignature = nil
        enforceCustomRecoveryRebootPolicy()
    }

    func selectRecommendedFirmwareMappings() {
        resetCompletedOperation()
        var selectedIDs: Set<String> = []
        var selectedPartitions: Set<String> = []
        var downloadListExcludedNames: [String] = []

        for mapping in firmwareMappings {
            if !isAllowedByDownloadList(mapping) {
                downloadListExcludedNames.append("\(mapping.slot.rawValue)/\(mapping.entry.fileName)")
                continue
            }

            if mapping.partition.partitionName == "userdata" {
                if firmwareDataMode == .preserve || flashBackend == .heimdall {
                    continue
                }
            }

            if selectedPartitions.insert(mapping.partition.partitionName).inserted {
                selectedIDs.insert(mapping.id)
            }
        }

        selectedFirmwareMappingIDs = selectedIDs
        if !downloadListExcludedNames.isEmpty {
            appendLog("Exclusion download-list Odin : \(downloadListExcludedNames.joined(separator: ", ")). Odin ne flashe pas ces images avec ce package ; les envoyer peut casser le montage des données.")
        }
        realFlashConfirmation = ""
        lastPreparationReportSignature = nil
        enforceCustomRecoveryRebootPolicy()
        if firmwareMappings.contains(where: { $0.partition.partitionName == "userdata" }) {
            if firmwareDataMode == .erase {
                if flashBackend == .heimdall {
                    appendLog("Sélection sans doublon : \(selectedIDs.count) images, userdata ajouté automatiquement au flash Swift natif en mode effacement.")
                } else {
                    appendLog("Sélection sans doublon : \(selectedIDs.count) images, userdata inclus pour effacer les données.")
                }
            } else {
                appendLog("Sélection sans doublon : \(selectedIDs.count) images, userdata exclu ; aucun effacement volontaire demandé.")
                if let preserveDataModeWarningText {
                    appendLog(preserveDataModeWarningText)
                }
            }
        } else {
            appendLog("Sélection sans doublon : \(selectedIDs.count) images.")
        }
        if hasCustomRecoveryFlashSelection {
            appendLog("TWRP détecté : laisse Redémarrer après flash désactivé, puis démarre directement en recovery après la sortie Download.")
        }
    }

    func selectSmallCscFirmwareMappings() {
        resetCompletedOperation()
        let allowedPartitions: Set<String> = ["cache", "omr", "optics"]
        selectedFirmwareMappingIDs = Set(
            firmwareMappings
                .filter { $0.slot == .csc && allowedPartitions.contains($0.partition.partitionName) }
                .map(\.id)
        )
        realFlashConfirmation = ""
        lastPreparationReportSignature = nil
        enforceCustomRecoveryRebootPolicy()
        appendLog("Sélection CSC petites partitions : \(selectedFirmwareMappingIDs.count) images.")
    }

    func selectUserdataOnlyFirmwareMapping() {
        resetCompletedOperation()
        guard hasLoadedPit else {
            appendLog("Sélection userdata seul impossible : lire le PIT avant le flash natif.")
            appendLog("Heimdall bloque souvent sur userdata ; ce mode de secours utilise le moteur natif Swift.")
            return
        }

        if flashBackend != .nativeSwift {
            flashBackend = .nativeSwift
            refreshFirmwareValidation()
        }

        guard let mapping = firmwareMappings.first(where: { $0.partition.partitionName == "userdata" }) else {
            appendLog("Sélection userdata seul impossible : aucune image userdata ne correspond au PIT.")
            return
        }

        selectedFirmwareMappingIDs = [mapping.id]
        realFlashConfirmation = ""
        lastPreparationReportSignature = nil
        enforceCustomRecoveryRebootPolicy()
        appendLog("Sélection userdata seul : 1 image. Backend Natif (Swift) actif ; utile si Recovery est inaccessible.")
    }

    func clearFirmwareMappingSelection() {
        resetCompletedOperation()
        selectedFirmwareMappingIDs.removeAll()
        realFlashConfirmation = ""
        lastPreparationReportSignature = nil
        enforceCustomRecoveryRebootPolicy()
        appendLog("Sélection flash effacée.")
    }

    func testOdinConnection() {
        guard let device = USBDevice.findDownloadModeDevice() else {
            appendLog("Impossible de tester Odin : aucun terminal connecté.")
            return
        }

        let flashSession = FlashSession(device: device)
        session = flashSession
        state = .connecting
        completedOperation = nil
        isReadingPitBeforeFlash = false
        appendLog("Test de connexion Odin.")

        DispatchQueue.global(qos: .userInitiated).async { [weak self, flashSession, device] in
            do {
                try device.open()
                let transportDescription = device.transportDescription
                let transportNotes = device.transportNotes
                defer { device.close() }
                try flashSession.handshake()

                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    state = .completed
                    completedOperation = .odinTest
                    activeDevice = nil
                    session = nil
                    hasReusableOdinSession = false
                    appendLog("Transport ouvert : \(transportDescription).")
                    for note in transportNotes {
                        appendLog("Info transport : \(note)")
                    }
                    appendLog("Handshake ODIN/LOKE valide.")
                }
            } catch {
                let reason = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    completedOperation = nil
                    activeDevice = nil
                    session = nil
                    hasReusableOdinSession = false
                    state = .failed(reason)
                    appendLog("Échec du test Odin : \(reason)")
                }
            }
        }
    }

    func exitDownloadMode() {
        guard canExitDownloadMode else {
            appendLog("Sortie Download Mode impossible : aucun terminal disponible ou opération en cours.")
            return
        }

        let reusableSession: FlashSession?
        let reusableDevice: USBDevice?
        let useReusableSession: Bool
        let previousState = state
        let previousCompletedOperation = completedOperation

        if hasReusableOdinSession, let existingSession = session, let existingDevice = activeDevice {
            reusableSession = existingSession
            reusableDevice = existingDevice
            useReusableSession = true
        } else if let newDevice = USBDevice.findDownloadModeDevice() {
            reusableSession = nil
            reusableDevice = nil
            connectedDeviceDescription = newDevice.displayName
            useReusableSession = false
        } else {
            isDeviceConnected = false
            connectedDeviceDescription = nil
            appendLog("Sortie Download Mode impossible : aucun terminal connecté.")
            return
        }

        state = .finishing
        completedOperation = nil
        isReadingPitBeforeFlash = false
        isSearchingDownloadModeDevice = false
        appendLog("Sortie Download Mode demandee.")
        if hasCustomRecoveryFlashSelection {
            appendLog("TWRP : maintiens Volume Haut + Power pendant le redémarrage. Si Android Recovery apparaît, reflashe TWRP et recommence sans laisser Android démarrer.")
        }

        DispatchQueue.global(qos: .userInitiated).async { [weak self, reusableSession, reusableDevice, useReusableSession, previousState, previousCompletedOperation] in
            let appendProgress: (String) -> Void = { [weak self] line in
                DispatchQueue.main.async { [weak self] in
                    self?.appendLog(line)
                }
            }

            do {
                if useReusableSession, let reusableSession, let reusableDevice {
                    appendProgress("Session Odin PIT reutilisee : pas de nouveau handshake.")
                    try reusableSession.rebootFromCurrentSession(progressHandler: appendProgress)
                    reusableDevice.close()
                } else {
                    try rebootFreshDownloadModeDevice(progressHandler: appendProgress)
                }

                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    state = .completed
                    completedOperation = .exitDownloadMode
                    isDeviceConnected = false
                    connectedDeviceDescription = nil
                    updateDetectedDeviceModel(from: nil)
                    activeDevice = nil
                    session = nil
                    hasReusableOdinSession = false
                    automaticDeviceMissCount = 0
                    isSearchingDownloadModeDevice = true
                    appendLog("Terminal sorti du mode Download.")
                }
            } catch {
                let reason = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
                DispatchQueue.main.async { [weak self] in
                    reusableDevice?.close()
                    guard let self else { return }
                    state = previousState
                    completedOperation = previousCompletedOperation
                    activeDevice = nil
                    session = nil
                    hasReusableOdinSession = false
                    isSearchingDownloadModeDevice = !isDeviceConnected
                    appendLog("Sortie Download Mode non confirmée : \(reason)")
                    appendLog("Le flash précédent reste terminé. Si le téléphone reste en Download Mode, maintiens Volume bas + Power pour redémarrer manuellement.")
                }
            }
        }
    }

    func readPit() {
        readPit(startFlashAfterLoad: false)
    }

    private func readPit(startFlashAfterLoad: Bool) {
        guard pitEntries.isEmpty else {
            if startFlashAfterLoad {
                startRealFlash()
            } else {
                appendLog("PIT déjà chargé : relance le terminal en mode Download pour le relire.")
            }
            return
        }

        guard let device = USBDevice.findDownloadModeDevice() else {
            let message = startFlashAfterLoad
                ? "Flash réel bloqué : impossible de lire le PIT automatiquement, aucun terminal connecté."
                : "Impossible de lire le PIT : aucun terminal connecté."
            appendLog(message)
            return
        }

        let flashSession = FlashSession(device: device)
        session = flashSession
        state = .readingPIT
        completedOperation = nil
        isReadingPitBeforeFlash = startFlashAfterLoad
        appendLog(startFlashAfterLoad ? "Lecture PIT automatique avant flash." : "Lecture PIT demandee.")

        DispatchQueue.global(qos: .userInitiated).async { [weak self, flashSession, device] in
            let appendProgress: (String) -> Void = { [weak self] line in
                DispatchQueue.main.async { [weak self] in
                    self?.appendLog(line)
                }
            }

            do {
                try device.open()
                let transportDescription = device.transportDescription
                appendProgress("Transport ouvert : \(transportDescription).")
                for note in device.transportNotes {
                    appendProgress("Info transport : \(note)")
                }
                if !device.supportsUSBZeroLengthPackets {
                    appendProgress("Avertissement transport : le port série USB ne garantit pas les transferts USB vides utilisés par Odin.")
                }
                appendProgress("Handshake Odin (3 tentatives max).")
                try flashSession.handshake()
                appendProgress("Handshake ODIN/LOKE valide.")
                let pitFile = try flashSession.readPitFile(progressHandler: appendProgress, closeSession: false)

                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.activeDevice = device
                    self.session = flashSession
                    self.hasReusableOdinSession = true
                    self.isDeviceConnected = true
                    self.isSearchingDownloadModeDevice = false
                    self.connectedDeviceDescription = device.displayName
                    self.updateDetectedDeviceModel(from: device)
                    self.pitEntries = pitFile.entries.filter(\.isFlashable)
                    self.jobs = pitFile.entries
                        .filter(\.isFlashable)
                        .map { FlashJob(partitionName: $0.partitionName, fileURL: nil) }
                    self.refreshFirmwareValidation()
                    if !self.firmwareArchives.isEmpty {
                        self.selectRecommendedFirmwareMappings()
                    }
                    self.appendLog("PIT reçu : \(pitFile.entries.count) partitions.")
                    self.appendLog("Session Odin prête : flashe sans relire le PIT ni débrancher le câble.")
                    self.appendLog("Partitions PIT : \(pitFile.entries.map(\.partitionName).filter { !$0.isEmpty }.joined(separator: ", "))")
                    if startFlashAfterLoad {
                        self.state = .idle
                        self.completedOperation = nil
                        self.appendLog("PIT chargé automatiquement : démarrage du flash.")
                        self.startRealFlash()
                    } else {
                        self.state = .completed
                        self.completedOperation = .pitRead
                        self.isReadingPitBeforeFlash = false
                    }
                }
            } catch {
                device.close()
                let reason = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    completedOperation = nil
                    isReadingPitBeforeFlash = false
                    state = .failed(reason)
                    activeDevice = nil
                    session = nil
                    hasReusableOdinSession = false
                    appendLog("Échec lecture PIT : \(reason)")
                }
            }
        }
    }

    func startFlash() {
        guard canStartFlash else {
            appendLog("Préparation flash impossible : vérifier le PIT, la sélection et les avertissements bloquants.")
            for warning in selectionWarnings {
                appendLog("Sélection : \(warning)")
            }
            return
        }

        let mappings = selectedFirmwareMappings
        let totalSize = mappings.reduce(UInt64(0)) { $0 + $1.entry.size }
        let signature = preparationReportSignature(totalSize: totalSize)

        if lastPreparationReportSignature == signature {
            appendLog("Préparation flash déjà validée : \(mappings.count) images sélectionnées, \(ByteCountFormatter.string(fromByteCount: Int64(clamping: totalSize), countStyle: .file)).")
            return
        }

        lastPreparationReportSignature = signature
        appendLog("Préparation flash validée : \(mappings.count) images sélectionnées, \(ByteCountFormatter.string(fromByteCount: Int64(clamping: totalSize), countStyle: .file)).")
        appendLog("Aucune écriture envoyée : utiliser le bouton Flasher pour lancer le flash réel.")
        for warning in selectionWarnings {
            appendLog("Note : \(warning)")
        }
        if flashBackend == .heimdall && !hasLoadedPit {
            appendLog("Mode Heimdall : le PIT sera lu par Heimdall pendant le flash.")
        }
        if mappings.contains(where: { $0.entry.fileName.lowercased().hasSuffix(".lz4") }) {
            appendLog("Préparation : le mode LZ4 sera choisi automatiquement selon la réponse Odin du téléphone.")
        }

        for mapping in mappings {
            appendLog("\(mapping.slot.rawValue) : \(mapping.entry.fileName) -> \(mapping.partition.partitionName)")
        }

        if !firmwareUnmatchedEntries.isEmpty {
            appendLog("Images ignorees car absentes du PIT actuel : \(firmwareUnmatchedEntries.count).")
            for entry in firmwareUnmatchedEntries {
                appendLog("\(entry.slot.rawValue) ignore : \(entry.entry.fileName)")
            }
        }
    }

    func startRealFlash() {
        if canReadPitBeforeRealFlash {
            appendLog("Mode compatible Swift : lecture PIT automatique avant flash.")
            readPit(startFlashAfterLoad: true)
            return
        }

        guard canStartRealFlash else {
            appendLog("Flash réel bloqué : vérifier le PIT, le firmware et la sélection.")
            for error in firmwareErrors {
                appendLog("Firmware : \(error)")
            }
            for warning in selectionWarnings {
                appendLog("Sélection : \(warning)")
            }
            if requiresHeimdallForCurrentFlash && !isHeimdallAvailable {
                appendLog("Flash Heimdall bloqué : Heimdall/libusb introuvable. Installe Heimdall ou choisis Natif (Swift) dans les paramètres avancés.")
            }
            return
        }

        var mappings = selectedFirmwareMappings
        let shouldEraseNAND = nandEraseBeforeFlash
        let isCustomRecoveryFlash = isCustomRecoveryFlashSelection(mappings)
        let mustEraseUserdataInNativeSession = flashBackend == .heimdall
            && firmwareDataMode == .erase
            && firmwareMappings.contains { $0.partition.partitionName == "userdata" }
        let mustFlashCustomRecoveryInNativeSession = flashBackend == .heimdall
            && requiresNativeSwiftForCustomRecovery(mappings)
        let mustFlashOversizedInNativeSession = flashBackend == .heimdall
            && containsHeimdallOversizedImage(mappings)
        if isCustomRecoveryFlash && rebootAfterFlash {
            rebootAfterFlash = false
            appendLog("TWRP : redémarrage automatique désactivé pour éviter la restauration du recovery stock.")
        }
        let shouldReboot = rebootAfterFlash
        let mustUseNativeSession = shouldEraseNAND
            || mustEraseUserdataInNativeSession
            || mustFlashCustomRecoveryInNativeSession
            || mustFlashOversizedInNativeSession
        let shouldKeepSessionOpenAfterFlash = !shouldReboot && !isCustomRecoveryFlash

        if mustUseNativeSession {
            if flashBackend == .heimdall && !hasLoadedPit {
                if mustFlashOversizedInNativeSession {
                    appendLog("Image de plus de 4 Go (super) : Heimdall 1.4.2 tronque au-delà de 4 Go. Lecture PIT automatique pour flasher en session Swift native.")
                } else if mustFlashCustomRecoveryInNativeSession {
                    appendLog("Recovery custom/TWRP : lecture PIT automatique pour cibler la partition exacte en Swift natif.")
                } else if shouldEraseNAND {
                    appendLog("Erase NAND : lecture PIT automatique pour exécuter une session Swift native.")
                } else {
                    appendLog("Mode Effacer données : lecture PIT automatique pour finaliser userdata en session Swift native.")
                }
                readPit(startFlashAfterLoad: true)
                return
            }

            if mustEraseUserdataInNativeSession {
                if let userdataMapping = firmwareMappings.first(where: { $0.partition.partitionName == "userdata" }),
                   !mappings.contains(where: { $0.id == userdataMapping.id }) {
                    mappings.append(userdataMapping)
                }

                appendLog("Mode Effacer données : bascule vers Swift natif en session unique pour éviter le reboot Recovery après Heimdall.")
            }

            if shouldEraseNAND {
                appendLog("Erase NAND : commande Odin envoyée avant les images ; backend Swift natif utilisé.")
            }
            if mustFlashCustomRecoveryInNativeSession {
                appendLog("Recovery custom/TWRP : backend Swift natif utilisé pour éviter le mapping PIT interne de Heimdall.")
            }
            if mustFlashOversizedInNativeSession {
                appendLog("super > 4 Go : session Swift native utilisée, Heimdall 1.4.2 tronque les fichiers au-delà de 4 Go.")
            }
            if isCustomRecoveryFlash {
                appendLog("TWRP : après le flash, ne laisse pas Android démarrer. Quitte Download puis maintiens Volume Haut + Power jusqu'à TWRP.")
            }
        } else if flashBackend == .heimdall {
            releaseReusableOdinSession(logMessage: "Session Odin PIT fermée pour libérer l'USB avant Heimdall.")
            startHeimdallRealFlash(mappings: mappings, shouldReboot: shouldReboot)
            return
        }

        let flashSession: FlashSession
        let device: USBDevice
        let useReusableSession: Bool
        let preserveCompressedLZ4: Bool

        if hasReusableOdinSession, let reusableSession = session, let reusableDevice = activeDevice {
            flashSession = reusableSession
            device = reusableDevice
            useReusableSession = true
            preserveCompressedLZ4 = reusableSession.canSendCompressedFirmware
        } else if let newDevice = USBDevice.findDownloadModeDevice() {
            flashSession = FlashSession(device: newDevice)
            device = newDevice
            session = flashSession
            useReusableSession = false
            preserveCompressedLZ4 = false
            appendLog("Aucune session Odin reutilisable : handshake complet requis.")
        } else {
            appendLog("Impossible de flasher : aucun terminal connecté.")
            return
        }

        state = .preparingFirmware
        completedOperation = nil
        isReadingPitBeforeFlash = false
        flashRemainingTimeText = nil
        appendLog("FLASH REEL DEMARRE : \(mappings.count) images seront envoyees au terminal.")
        beginFlashActivity()
        requestFlashNotificationAuthorization()

        DispatchQueue.global(qos: .userInitiated).async { [weak self, flashSession, device, mappings, shouldReboot, shouldEraseNAND, useReusableSession, preserveCompressedLZ4, isCustomRecoveryFlash, shouldKeepSessionOpenAfterFlash] in
            var shouldCloseDevice = true
            var lastLoggedOverallPercent = -1
            var completedEntryIDs: Set<String> = []
            var entryStartDates: [String: Date] = [:]

            let remainingTimeText: (FirmwareFlashProgress) -> String? = { progress in
                let now = Date()
                let startDate = entryStartDates[progress.mapping.id] ?? now
                entryStartDates[progress.mapping.id] = startDate

                let elapsed = now.timeIntervalSince(startDate)
                guard elapsed > 2, progress.bytesSentForEntry > 0 else {
                    return nil
                }

                let bytesPerSecond = Double(progress.bytesSentForEntry) / elapsed
                guard bytesPerSecond > 0 else {
                    return nil
                }

                let remainingBytes = progress.totalBytesForEntry - progress.bytesSentForEntry
                let remainingSeconds = Double(remainingBytes) / bytesPerSecond
                return Self.formatDuration(remainingSeconds)
            }

            let appendProgress: (String) -> Void = { [weak self] line in
                DispatchQueue.main.async { [weak self] in
                    self?.appendLog(line)
                }
            }

            let updateProgress: (FirmwareFlashProgress) -> Void = { [weak self] progress in
                let percent = Int(progress.overallProgress * 100)
                let entryPercent = Int(progress.entryProgress * 100)
                let didCompleteEntry = entryPercent == 100 && completedEntryIDs.insert(progress.mapping.id).inserted
                let shouldLogPercent = didCompleteEntry || percent >= lastLoggedOverallPercent + 5 || percent == 100
                if shouldLogPercent {
                    lastLoggedOverallPercent = percent
                }

                DispatchQueue.main.async { [weak self] in
                    let remaining = remainingTimeText(progress)
                    self?.state = .flashing(
                        partition: progress.mapping.partition.partitionName,
                        progress: progress.overallProgress
                    )
                    self?.flashRemainingTimeText = remaining
                    if shouldLogPercent {
                        let etaText = remaining.map { ", reste environ \($0)" } ?? ""
                        self?.appendLog(
                            "Progression flash : \(percent)% (\(progress.mapping.partition.partitionName) \(entryPercent)%\(etaText))."
                        )
                    }
                }
            }

            do {
                let orderedOriginalMappings = mappings.sorted { lhs, rhs in
                    let leftSlotIndex = FirmwareSlot.allCases.firstIndex(of: lhs.slot) ?? 0
                    let rightSlotIndex = FirmwareSlot.allCases.firstIndex(of: rhs.slot) ?? 0
                    if leftSlotIndex == rightSlotIndex {
                        return lhs.archiveEntryIndex < rhs.archiveEntryIndex
                    }
                    return leftSlotIndex < rightSlotIndex
                }

                let preparedPayloads = try FirmwarePayloadPreparer.prepare(
                    mappings: orderedOriginalMappings,
                    preservesCompressedLZ4: preserveCompressedLZ4,
                    progressHandler: appendProgress
                )
                defer { preparedPayloads.cleanup() }

                if !useReusableSession {
                    DispatchQueue.main.async { [weak self] in
                        self?.state = .connecting
                    }
                }

                if !useReusableSession {
                    try device.open()
                }
                defer {
                    if shouldCloseDevice {
                        device.close()
                    }
                }
                appendProgress("Transport ouvert : \(device.transportDescription).")
                for note in device.transportNotes {
                    appendProgress("Info transport : \(note)")
                }
                let supportsUSBZeroLengthPackets = device.supportsUSBZeroLengthPackets
                if !supportsUSBZeroLengthPackets {
                    appendProgress("Avertissement transport : le port série USB ne garantit pas les transferts USB vides utilisés par Odin.")
                    appendProgress("Mode Odin compatible : session de flash unique via port série USB.")
                }

                if useReusableSession {
                    appendProgress("Session Odin PIT reutilisee : pas de nouveau handshake.")
                    try flashSession.flashFirmwareInCurrentSession(
                        mappings: preparedPayloads.mappings,
                        rebootAfterFlash: shouldReboot,
                        eraseNANDBeforeFlash: shouldEraseNAND,
                        keepSessionOpenAfterFlash: shouldKeepSessionOpenAfterFlash,
                        progressHandler: appendProgress,
                        flashProgressHandler: updateProgress
                    )
                } else {
                    appendProgress("Handshake Odin (3 tentatives max).")
                    try flashSession.handshake()
                    appendProgress("Handshake ODIN/LOKE valide.")
                    appendProgress("Ouverture session Odin.")
                    let defaultPacketSize = try flashSession.beginSession()
                    appendProgress("Session Odin ouverte, réponse protocole : \(String(format: "0x%X", defaultPacketSize)).")
                    if flashSession.canSendCompressedFirmware != preserveCompressedLZ4 {
                        appendProgress("Info Odin : capacité LZ4 différente de la préparation initiale, le mode préparé reste conservé pour cette session.")
                    }
                    try flashSession.flashFirmwareInCurrentSession(
                        mappings: preparedPayloads.mappings,
                        rebootAfterFlash: shouldReboot,
                        eraseNANDBeforeFlash: shouldEraseNAND,
                        keepSessionOpenAfterFlash: shouldKeepSessionOpenAfterFlash,
                        progressHandler: appendProgress,
                        flashProgressHandler: updateProgress
                    )
                }

                if shouldKeepSessionOpenAfterFlash {
                    shouldCloseDevice = false
                }

                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    state = .completed
                    completedOperation = .flash
                    flashRemainingTimeText = nil
                    if shouldKeepSessionOpenAfterFlash {
                        activeDevice = device
                        session = flashSession
                        hasReusableOdinSession = true
                        isDeviceConnected = true
                        isSearchingDownloadModeDevice = false
                        connectedDeviceDescription = device.displayName
                        appendLog("Flash terminé. Session Odin ouverte : Quitter Download peut redémarrer le téléphone.")
                    } else {
                        activeDevice = nil
                        session = nil
                        hasReusableOdinSession = false
                        appendLog("Flash terminé.")
                        if isCustomRecoveryFlash {
                            appendLog("TWRP : quitte Download manuellement puis maintiens immédiatement Volume Haut + Power. Si Android Recovery apparaît, reflashe TWRP sans laisser Android démarrer.")
                        }
                    }
                    endFlashActivity()
                    postFlashCompletionNotification(success: true, detail: "Le firmware a été envoyé au téléphone avec succès.")
                    recordFlashHistory(result: "Succès", detail: "Flash Swift terminé.", engineName: FlashBackend.nativeSwift.title)
                }
            } catch {
                let reason = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    completedOperation = nil
                    isReadingPitBeforeFlash = false
                    flashRemainingTimeText = nil
                    state = .failed(reason)
                    activeDevice = nil
                    session = nil
                    hasReusableOdinSession = false
                    appendLog("Échec flash réel : \(reason)")
                    appendLog(userFacingFlashFailureSummary(for: reason))
                    if !useReusableSession {
                        appendLog("Si le handshake échoue après une lecture PIT précédente, remets le téléphone en mode Download puis relis le PIT avant de flasher.")
                    }
                    endFlashActivity()
                    postFlashCompletionNotification(success: false, detail: reason)
                    recordFlashHistory(result: "Échec", detail: reason, engineName: FlashBackend.nativeSwift.title)
                }
            }
        }
    }

    private func startHeimdallRealFlash(mappings: [FirmwareMapping], shouldReboot: Bool) {
        guard let heimdallURL = HeimdallFlashRunner.findExecutable() else {
            let reason = "Heimdall/libusb introuvable"
            completedOperation = nil
            state = .failed(reason)
            appendLog("Flash Heimdall indisponible : Heimdall/libusb introuvable.")
            appendLog("Téléchargement Heimdall : https://glassechidna.com.au/heimdall/")
            appendLog("Installe Heimdall puis relance le flash, ou choisis Natif (Swift) dans Paramètres avancés.")
            recordFlashHistory(result: "Échec", detail: reason)
            return
        }

        state = .flashing(partition: "Heimdall/libusb", progress: 0)
        completedOperation = nil
        isReadingPitBeforeFlash = false
        flashRemainingTimeText = nil
        appendLog("FLASH HEIMDALL DEMARRE : \(mappings.count) images seront envoyees au terminal.")
        appendLog("Heimdall : \(heimdallURL.path)")
        beginFlashActivity()
        requestFlashNotificationAuthorization()

        DispatchQueue.global(qos: .userInitiated).async { [weak self, heimdallURL, mappings, shouldReboot] in
            let appendProgress: (String) -> Void = { [weak self] line in
                DispatchQueue.main.async { [weak self] in
                    self?.appendLog(line)
                }
            }
            let updateProgress: (String, Double) -> Void = { [weak self] partition, progress in
                DispatchQueue.main.async { [weak self] in
                    self?.state = .flashing(partition: partition, progress: progress)
                }
            }

            do {
                let preparedPayloads = try FirmwarePayloadPreparer.prepare(
                    mappings: Self.orderedFirmwareMappings(mappings),
                    preservesCompressedLZ4: false,
                    requiresStandaloneFiles: true,
                    progressHandler: appendProgress
                )
                defer { preparedPayloads.cleanup() }

                try HeimdallFlashRunner.flashWithAutomaticResume(
                    executableURL: heimdallURL,
                    mappings: preparedPayloads.mappings,
                    rebootAfterFlash: shouldReboot,
                    progressHandler: appendProgress,
                    flashProgressHandler: updateProgress
                )

                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    state = .completed
                    completedOperation = .flash
                    flashRemainingTimeText = nil
                    activeDevice = nil
                    session = nil
                    hasReusableOdinSession = false
                    appendLog("Flash Heimdall terminé.")
                    endFlashActivity()
                    postFlashCompletionNotification(success: true, detail: "Le firmware a été envoyé au téléphone avec succès.")
                    recordFlashHistory(result: "Succès", detail: "Flash Heimdall terminé.", engineName: FlashBackend.heimdall.title)
                }
            } catch {
                let reason = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    completedOperation = nil
                    flashRemainingTimeText = nil
                    state = .failed(reason)
                    activeDevice = nil
                    session = nil
                    hasReusableOdinSession = false
                    appendLog("Échec flash Heimdall : \(reason)")
                    appendLog(userFacingFlashFailureSummary(for: reason))
                    appendLog("Aucun fallback automatique vers le moteur natif : un flash peut être partiel après un échec Heimdall.")
                    endFlashActivity()
                    postFlashCompletionNotification(success: false, detail: reason)
                    recordFlashHistory(result: "Échec", detail: reason, engineName: FlashBackend.heimdall.title)
                }
            }
        }
    }

    private func appendLog(_ line: String) {
        logLines.append(line)
        let overflowCount = logLines.count - Self.maximumLogLineCount
        if overflowCount > 0 {
            logLines.removeFirst(overflowCount)
        }
    }

    func sessionReportText() -> String {
        var lines: [String] = []
        lines.append("FlashPort - rapport de session")
        lines.append("Date : \(Self.reportDateFormatter.string(from: Date()))")
        lines.append("")
        lines.append("Résumé")
        lines.append("- État : \(stateReportText)")
        lines.append("- Opération terminée : \(completedOperationReportText)")
        lines.append("- Backend : \(flashBackend.title)")
        lines.append("- Mode données : \(firmwareDataMode.title)")
        if let preserveDataModeWarningText {
            lines.append("- Avertissement données : \(preserveDataModeWarningText)")
        }
        lines.append("- Redémarrage après flash : \(rebootAfterFlash ? "oui" : "non")")
        lines.append("- Erase NAND : \(nandEraseBeforeFlash ? "oui" : "non")")
        lines.append("")
        lines.append("Téléphone")
        lines.append("- Connecté : \(isDeviceConnected ? "oui" : "non")")
        lines.append("- Description : \(connectedDeviceDescription ?? "non détecté")")
        lines.append("- Modèle détecté : \(detectedDeviceModelCode ?? "non détecté")")
        lines.append("- PIT : \(pitEntries.isEmpty ? "non chargé" : "\(pitEntries.count) partitions flashables")")
        lines.append("")
        lines.append("Firmware")
        lines.append("- Source : \(importedFirmwareSourceName ?? "non importée")")
        lines.append("- Archives : \(firmwareArchives.count)")
        lines.append("- Images sélectionnées : \(selectedFirmwareMappings.count)")
        lines.append("- Taille sélectionnée : \(ByteCountFormatter.string(fromByteCount: Int64(clamping: selectedFlashSize), countStyle: .file))")
        lines.append("- Modèles firmware : \(firmwareModelCodes.isEmpty ? "non détectés" : firmwareModelCodes.joined(separator: ", "))")
        lines.append("- Binary firmware : \(firmwareBootloaderRevisions.isEmpty ? "non détecté" : firmwareBootloaderRevisions.map { FirmwareCompatibilityValidator.bootloaderRevisionText($0) }.joined(separator: ", "))")
        lines.append("")

        if !firmwareCompatibilityErrors.isEmpty {
            lines.append("Blocages firmware")
            lines.append(contentsOf: firmwareCompatibilityErrors.map { "- \($0)" })
            lines.append("")
        }
        if !firmwareCompatibilityWarnings.isEmpty {
            lines.append("Avertissements firmware")
            lines.append(contentsOf: firmwareCompatibilityWarnings.map { "- \($0)" })
            lines.append("")
        }
        if !selectionWarnings.isEmpty {
            lines.append("Avertissements sélection")
            lines.append(contentsOf: selectionWarnings.map { "- \($0)" })
            lines.append("")
        }

        if !selectedFirmwareMappings.isEmpty {
            lines.append("Images sélectionnées")
            for mapping in selectedFirmwareMappings {
                lines.append("- \(mapping.slot.rawValue) \(mapping.entry.fileName) -> \(mapping.partition.partitionName)")
            }
            lines.append("")
        }

        lines.append("Journal")
        if logLines.isEmpty {
            lines.append("- Aucun log")
        } else {
            lines.append(contentsOf: logLines)
        }

        return lines.joined(separator: "\n")
    }

    func pitExportText() -> String {
        var lines: [String] = []
        lines.append("FlashPort - export PIT")
        lines.append("Date : \(Self.reportDateFormatter.string(from: Date()))")
        lines.append("Téléphone : \(connectedDeviceDescription ?? "non détecté")")
        lines.append("Partitions : \(pitEntries.count)")
        lines.append("")
        lines.append("partition,file,device,type,offset,size")
        for entry in pitEntries {
            lines.append([
                entry.partitionName,
                entry.flashFilename,
                "\(entry.deviceType)",
                "\(entry.binaryType)",
                "\(entry.blockSizeOrOffset)",
                "\(entry.blockCount)"
            ].joined(separator: ","))
        }
        return lines.joined(separator: "\n")
    }

    private func recordFlashHistory(result: String, detail: String, engineName: String? = nil) {
        let entry = FlashHistoryEntry(
            id: UUID().uuidString,
            date: Date(),
            result: result,
            firmwareName: importedFirmwareSourceName ?? firmwareArchives.map(\.displayName).joined(separator: ", "),
            deviceName: connectedDeviceDescription ?? detectedDeviceModelCode ?? "Téléphone non identifié",
            backendName: engineName ?? flashBackend.title,
            selectedImageCount: selectedFirmwareMappings.count,
            selectedSize: selectedFlashSize,
            dataModeTitle: firmwareDataMode.title,
            detail: detail
        )
        flashHistoryEntries.insert(entry, at: 0)
        if flashHistoryEntries.count > Self.maximumFlashHistoryCount {
            flashHistoryEntries.removeLast(flashHistoryEntries.count - Self.maximumFlashHistoryCount)
        }
        saveFlashHistory()
    }

    private func loadPersistedSettings() {
        let defaults = UserDefaults.standard
        if let backendValue = defaults.string(forKey: Self.flashBackendDefaultsKey),
           let backend = FlashBackend(rawValue: backendValue) {
            flashBackend = backend
        }
        if defaults.object(forKey: Self.rebootAfterFlashDefaultsKey) != nil {
            rebootAfterFlash = defaults.bool(forKey: Self.rebootAfterFlashDefaultsKey)
        }
        if let dataModeValue = defaults.string(forKey: Self.firmwareDataModeDefaultsKey),
           let dataMode = FirmwareDataMode(rawValue: dataModeValue) {
            firmwareDataMode = dataMode
        }
    }

    private func persistSettings() {
        let defaults = UserDefaults.standard
        defaults.set(flashBackend.rawValue, forKey: Self.flashBackendDefaultsKey)
        defaults.set(rebootAfterFlash, forKey: Self.rebootAfterFlashDefaultsKey)
        defaults.set(firmwareDataMode.rawValue, forKey: Self.firmwareDataModeDefaultsKey)
    }

    /// Empêche la mise en veille du Mac pendant un flash : une coupure USB en
    /// plein transfert interromprait le flash.
    private func beginFlashActivity() {
        endFlashActivity()
        flashActivityToken = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .idleSystemSleepDisabled],
            reason: "Flash firmware Samsung en cours"
        )
    }

    private func endFlashActivity() {
        if let flashActivityToken {
            ProcessInfo.processInfo.endActivity(flashActivityToken)
        }
        flashActivityToken = nil
    }

    private func requestFlashNotificationAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    /// Notification locale de fin de flash, uniquement si l'app est en
    /// arrière-plan (un flash dure plusieurs minutes).
    private func postFlashCompletionNotification(success: Bool, detail: String) {
        guard !NSApplication.shared.isActive else { return }

        let content = UNMutableNotificationContent()
        content.title = success ? "Flash terminé" : "Échec du flash"
        content.body = detail
        content.sound = .default
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        )
    }

    private func loadFlashHistory() {
        guard let data = UserDefaults.standard.data(forKey: Self.flashHistoryDefaultsKey),
              let entries = try? JSONDecoder().decode([FlashHistoryEntry].self, from: data) else {
            return
        }
        flashHistoryEntries = entries
    }

    private func saveFlashHistory() {
        guard let data = try? JSONEncoder().encode(flashHistoryEntries) else { return }
        UserDefaults.standard.set(data, forKey: Self.flashHistoryDefaultsKey)
    }

    private var stateReportText: String {
        switch state {
        case .idle:
            return "Prêt"
        case .preparingFirmware:
            return "Décompression / préparation firmware"
        case .connecting:
            return "Connexion"
        case .handshaking:
            return "Handshake Odin"
        case .readingPIT:
            return "Lecture PIT"
        case .flashing(let partition, let progress):
            return "Flash \(partition) \(Int((progress * 100).rounded()))%"
        case .finishing:
            return "Finalisation"
        case .completed:
            return "Terminé"
        case .failed(let reason):
            return "Échec : \(reason)"
        }
    }

    private var completedOperationReportText: String {
        switch completedOperation {
        case .odinTest:
            return "Connexion Odin validée"
        case .pitRead:
            return "PIT chargé"
        case .exitDownloadMode:
            return "Sortie Download Mode"
        case .flash:
            return "Flash terminé"
        case .none:
            return "Aucune"
        }
    }

    private func userFacingFlashFailureSummary(for reason: String) -> String {
        let lowercasedReason = reason.lowercased()
        if lowercasedReason.contains("unable to enqueue")
            || lowercasedReason.contains("usb")
            || lowercasedReason.contains("transport") {
            return "Diagnostic : le lien USB a coupé ou le téléphone a refusé une écriture. Débranche/rebranche, remets le téléphone en Download Mode, puis réessaie avec le câble le plus direct possible."
        }
        if lowercasedReason.contains("refusé le binaire") {
            return "Diagnostic : le téléphone n'accepte que des binaires officiels Samsung. Pour flasher un recovery custom (TWRP), active « Déverrouillage OEM » dans les Options de développement, puis déverrouille le bootloader en Download Mode (appui long Volume Haut — efface toutes les données)."
        }
        if lowercasedReason.contains("0xffffffff")
            || lowercasedReason.contains("downgrade")
            || lowercasedReason.contains("incompatible") {
            return "Diagnostic : le bootloader a probablement refusé l'image. Vérifie le modèle, le binary et évite tout downgrade."
        }
        if lowercasedReason.contains("heimdall") {
            return "Diagnostic : le backend Heimdall a échoué. Exporte le rapport, puis essaie le moteur Natif (Swift) si le téléphone est encore en Download Mode."
        }
        return "Diagnostic : le flash a été interrompu avant confirmation complète. Exporte le rapport et vérifie l'état du téléphone avant toute nouvelle tentative."
    }

    private static let reportDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .medium
        return formatter
    }()

    private func resetCompletedOperation() {
        guard completedOperation != nil else { return }
        completedOperation = nil
        isReadingPitBeforeFlash = false
        if case .completed = state {
            state = .idle
        }
    }

    private func releaseReusableOdinSession(logMessage: String? = nil) {
        guard hasReusableOdinSession || activeDevice != nil || session != nil else { return }

        activeDevice?.close()
        activeDevice = nil
        session = nil
        hasReusableOdinSession = false

        if let logMessage {
            appendLog(logMessage)
        }
    }

    private var isBusy: Bool {
        if isImportingFirmware {
            return true
        }

        switch state {
        case .preparingFirmware, .connecting, .handshaking, .readingPIT, .flashing, .finishing:
            return true
        case .idle, .completed, .failed:
            return false
        }
    }

    private func replaceAvailableFirmwareArchive(_ archive: FirmwareArchive, autoSelect: Bool) {
        availableFirmwareArchives.removeAll { $0.slot == archive.slot }
        availableFirmwareArchives.append(archive)
        availableFirmwareArchives.sort { lhs, rhs in
            (FirmwareSlot.allCases.firstIndex(of: lhs.slot) ?? 0) < (FirmwareSlot.allCases.firstIndex(of: rhs.slot) ?? 0)
        }
        applyActiveFirmwareArchives(autoSelect: autoSelect)
    }

    private func applyActiveFirmwareArchives(autoSelect: Bool) {
        let activeCscSlot = firmwareDataMode.activeCscSlot
        firmwareArchives = availableFirmwareArchives.filter { archive in
            switch archive.slot {
            case .csc, .homeCSC:
                return archive.slot == activeCscSlot
            default:
                return true
            }
        }
        firmwarePackageMetadata = FirmwarePackageMetadata.scan(
            sourceName: importedFirmwareSourceName,
            archives: firmwareArchives
        )
        refreshFirmwareValidation()
        if autoSelect && hasFirmwareMappingSource && !firmwareMappings.isEmpty {
            selectRecommendedFirmwareMappings()
        }
    }

    private func replaceTemporaryImportDirectory(with directory: URL?) {
        for oldDirectory in importedTemporaryDirectories {
            try? FileManager.default.removeItem(at: oldDirectory)
        }
        importedTemporaryDirectories.removeAll()
        if let directory {
            importedTemporaryDirectories.append(directory)
        }
    }

    private func cleanupStaleTemporaryFiles() {
        let temporaryDirectory = FileManager.default.temporaryDirectory
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: temporaryDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey]
        ) else {
            return
        }

        // Ne supprimer que les restes réellement anciens : un dossier récent
        // peut être en cours d'utilisation par un import/flash en parallèle.
        let staleThreshold = Date().addingTimeInterval(-3600)

        for url in urls {
            let name = url.lastPathComponent
            let isFirmwareImport = name.hasPrefix("AndroidFLASH-Firmware-")
            let isRecoveryImport = name.hasPrefix("AndroidFLASH-Recovery-")
            let isPreparedPayload = name.hasPrefix("AndroidFLASH-") && !name.hasPrefix("AndroidFLASH-Heimdall")
            guard isFirmwareImport || isRecoveryImport || isPreparedPayload else { continue }

            let modificationDate = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            guard let modificationDate, modificationDate < staleThreshold else { continue }

            try? FileManager.default.removeItem(at: url)
        }
    }

    private func refreshFirmwareValidation() {
        let report = FirmwareMapper.validate(
            archives: firmwareArchives,
            pitEntries: pitEntries,
            allowsDirectPartitionNames: flashBackend == .heimdall
        )
        let compatibilityReport = FirmwareCompatibilityValidator.validate(
            archives: firmwareArchives,
            expectedDeviceModelInput: expectedDeviceModelCode,
            detectedDeviceModelCode: detectedDeviceModelCode,
            currentBootloaderRevisionInput: currentBootloaderRevision
        )
        firmwareMappings = report.mappings
        firmwareUnmatchedEntries = report.unmatchedEntries
        firmwareModelCodes = compatibilityReport.firmwareModelCodes
        firmwareBootloaderRevisions = compatibilityReport.firmwareBootloaderRevisions
        firmwareCompatibilityWarnings = compatibilityReport.warnings
        firmwareCompatibilityErrors = compatibilityReport.errors
        firmwareCompatibilitySummary = compatibilityReport.summary
        firmwareWarnings = report.warnings + compatibilityReport.warnings
        firmwareErrors = report.errors + compatibilityReport.errors
        selectedFirmwareMappingIDs = selectedFirmwareMappingIDs.intersection(Set(report.mappings.map(\.id)))
        enforceCustomRecoveryRebootPolicy()
        realFlashConfirmation = ""
        lastPreparationReportSignature = nil
    }

    private func refreshAutomaticDeviceDetection() {
        if hasReusableOdinSession, let activeDevice {
            isSearchingDownloadModeDevice = false
            applyDeviceConnection(activeDevice, logResult: false, automatic: true)
            return
        }

        guard !isBusy else {
            isSearchingDownloadModeDevice = false
            return
        }

        let device = USBDevice.findDownloadModeDevice()
        if let device {
            automaticDeviceMissCount = 0
            isSearchingDownloadModeDevice = false
            applyDeviceConnection(device, logResult: false, automatic: true)
        } else {
            automaticDeviceMissCount += 1
            isSearchingDownloadModeDevice = true
            if automaticDeviceMissCount >= 2 {
                applyDeviceConnection(nil, logResult: false, automatic: true)
            }
        }
    }

    private func applyDeviceConnection(_ device: USBDevice?, logResult: Bool, automatic: Bool) {
        let wasConnected = isDeviceConnected
        let previousDescription = connectedDeviceDescription
        let nextDescription = device?.displayName

        if device != nil {
            automaticDeviceMissCount = 0
        }
        isDeviceConnected = device != nil
        connectedDeviceDescription = nextDescription
        updateDetectedDeviceModel(from: device)

        if logResult {
            appendLog(device.map { "Terminal détecté : \($0.displayName)." } ?? "Aucun terminal détecté.")
            return
        }

        guard automatic else { return }

        if let nextDescription, (!wasConnected || previousDescription != nextDescription) {
            appendLog("Terminal détecté automatiquement : \(nextDescription).")
        } else if wasConnected && nextDescription == nil {
            appendLog("Terminal déconnecté : recherche automatique relancée.")
        }
    }

    private func updateDetectedDeviceModel(from device: USBDevice?) {
        let modelCode = FirmwareCompatibilityValidator.deviceModelCode(from: device?.displayName)
        guard detectedDeviceModelCode != modelCode else { return }
        detectedDeviceModelCode = modelCode
        refreshFirmwareValidation()
        if let modelCode {
            appendLog("Modèle téléphone détecté : \(modelCode).")
        }
    }

    private var canPrepareFlashSelection: Bool {
        (isDeviceConnected || hasReusableOdinSession)
            && hasFirmwareMappingSource
            && !firmwareMappings.isEmpty
            && firmwareErrors.isEmpty
            && !hasExclusiveCscConflict
            && !isBusy
    }

    private var hasExclusiveCscConflict: Bool {
        firmwareArchives.contains { $0.slot == .csc }
            && firmwareArchives.contains { $0.slot == .homeCSC }
    }

    private var hasIncompatibleUserdataSelection: Bool {
        firmwareDataMode == .preserve
            && selectedFirmwareMappings.contains { $0.partition.partitionName == "userdata" }
    }

    private var requiresNativeSwiftSessionForCurrentFlash: Bool {
        nandEraseBeforeFlash
            || (
                flashBackend == .heimdall
                    && firmwareDataMode == .erase
                    && firmwareMappings.contains { $0.partition.partitionName == "userdata" }
            )
            || (
                flashBackend == .heimdall
                    && requiresNativeSwiftForCustomRecovery(selectedFirmwareMappings)
            )
            || (
                flashBackend == .heimdall
                    && containsHeimdallOversizedImage(selectedFirmwareMappings)
            )
            || flashBackend == .nativeSwift
    }

    private var requiresHeimdallForCurrentFlash: Bool {
        flashBackend == .heimdall && !requiresNativeSwiftSessionForCurrentFlash
    }

    private func requiresNativeSwiftForCustomRecovery(_ mappings: [FirmwareMapping]) -> Bool {
        isCustomRecoveryFlashSelection(mappings)
    }

    /// Union des meta-data/download-list.txt des archives actives : quand au
    /// moins une liste existe, Odin ne flashe que les images qui y figurent.
    private var downloadListImageNames: Set<String> {
        firmwareArchives.reduce(into: Set<String>()) { result, archive in
            if let names = archive.downloadListImageNames {
                result.formUnion(names)
            }
        }
    }

    private func isAllowedByDownloadList(_ mapping: FirmwareMapping) -> Bool {
        let allowedNames = downloadListImageNames
        guard !allowedNames.isEmpty else { return true }

        var imageName = mapping.entry.fileName.lowercased()
        if imageName.hasSuffix(".lz4") {
            imageName.removeLast(4)
        }
        return allowedNames.contains(imageName)
    }

    /// Heimdall 1.4.2 stocke les tailles de fichier en 32 bits et tronque
    /// silencieusement toute image au-delà de 4 Go (super dépasse toujours
    /// cette limite une fois décompressée) : ces images exigent la session
    /// Swift native, qui gère les tailles 64 bits.
    private func containsHeimdallOversizedImage(_ mappings: [FirmwareMapping]) -> Bool {
        mappings.contains { mapping in
            mapping.partition.partitionName == "super"
                || mapping.entry.size >= UInt64(UInt32.max)
        }
    }

    private func isCustomRecoveryFlashSelection(_ mappings: [FirmwareMapping]) -> Bool {
        guard !mappings.isEmpty, mappings.count <= 3 else {
            return false
        }

        return mappings.contains { mapping in
            let partitionName = mapping.partition.partitionName.lowercased()
            let archiveName = mapping.archiveName.lowercased()
            let entryName = mapping.entry.fileName.lowercased()
            let entryCandidate = mapping.entry.normalizedPartitionCandidate

            return archiveName.contains("twrp")
                || entryName.contains("twrp")
                || partitionName == "recovery"
                || entryCandidate == "recovery"
        }
    }

    private func customRecoveryCompatibilityWarnings(for mappings: [FirmwareMapping]) -> [String] {
        let codenames = customRecoveryCodenames(in: mappings)
        guard !codenames.isEmpty else {
            return ["Fichier TWRP : vérifie que la build correspond exactement au modèle du téléphone."]
        }

        let targetModelCodes = targetModelCodesForCustomRecoveryCheck()
        var warnings: [String] = []

        for codename in codenames {
            let deviceName = Self.knownCustomRecoveryDeviceNamesByCodename[codename]
            for modelCode in targetModelCodes {
                guard let expectedCodenames = Self.knownCustomRecoveryCodenamesByModelCode[modelCode],
                      !expectedCodenames.contains(codename) else {
                    continue
                }

                let deviceText = deviceName.map { " (\($0))" } ?? ""
                warnings.append("Le fichier TWRP indique \(codename)\(deviceText), mais le modèle cible connu est \(Self.displayModelCode(modelCode)).")
            }
        }

        if warnings.isEmpty {
            let codenameList = codenames
                .map { codename in
                    if let deviceName = Self.knownCustomRecoveryDeviceNamesByCodename[codename] {
                        return "\(codename) (\(deviceName))"
                    }
                    return codename
                }
                .joined(separator: ", ")
            warnings.append("Fichier TWRP \(codenameList) : vérifie que ce codename correspond exactement au téléphone.")
        }

        return warnings
    }

    private func customRecoveryCodenames(in mappings: [FirmwareMapping]) -> [String] {
        let knownCodenames = Set(Self.knownCustomRecoveryDeviceNamesByCodename.keys)
        var codenames: Set<String> = []

        for mapping in mappings where isCustomRecoveryFlashSelection([mapping]) {
            let searchableText = "\(mapping.archiveName) \(mapping.entry.fileName)"
            for token in Self.tokens(from: searchableText) where knownCodenames.contains(token) {
                codenames.insert(token)
            }
        }

        return codenames.sorted()
    }

    private func targetModelCodesForCustomRecoveryCheck() -> [String] {
        var modelCodes: Set<String> = []

        if let normalizedExpectedDeviceModelCode {
            modelCodes.insert(normalizedExpectedDeviceModelCode)
        }
        if let detectedDeviceModelCode {
            modelCodes.insert(detectedDeviceModelCode)
        }
        for modelCode in firmwarePackageMetadata.modelCodes {
            if let normalizedModelCode = FirmwareCompatibilityValidator.normalizedDeviceModelCode(modelCode) {
                modelCodes.insert(normalizedModelCode)
            }
        }

        return modelCodes.sorted()
    }

    private static func tokens(from text: String) -> [String] {
        text
            .lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
    }

    private static func displayModelCode(_ modelCode: String) -> String {
        modelCode.hasPrefix("SM-") ? modelCode : "SM-\(modelCode)"
    }

    private func enforceCustomRecoveryRebootPolicy() {
        guard hasCustomRecoveryFlashSelection, rebootAfterFlash else { return }

        rebootAfterFlash = false
        appendLog("TWRP : redémarrage automatique désactivé pour éviter la restauration du recovery stock.")
    }

    private var selectedDuplicatePartitionNames: [String] {
        Dictionary(grouping: selectedFirmwareMappings, by: { $0.partition.partitionName })
            .filter { $0.value.count > 1 }
            .map(\.key)
            .sorted()
    }

    private func preparationReportSignature(totalSize: UInt64) -> String {
        let mappingSignature = selectedFirmwareMappings
            .map { "\($0.id):\($0.entry.size)" }
            .joined(separator: "|")
        let unmatchedSignature = firmwareUnmatchedEntries
            .map { "\($0.id):\($0.entry.size)" }
            .joined(separator: "|")
        return "\(totalSize)|\(mappingSignature)|\(unmatchedSignature)"
    }

    nonisolated private static func orderedFirmwareMappings(_ mappings: [FirmwareMapping]) -> [FirmwareMapping] {
        mappings.sorted { lhs, rhs in
            let leftSlotIndex = FirmwareSlot.allCases.firstIndex(of: lhs.slot) ?? 0
            let rightSlotIndex = FirmwareSlot.allCases.firstIndex(of: rhs.slot) ?? 0
            if leftSlotIndex == rightSlotIndex {
                return lhs.archiveEntryIndex < rhs.archiveEntryIndex
            }
            return leftSlotIndex < rightSlotIndex
        }
    }

    nonisolated private static func formatDuration(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite && seconds >= 0 else {
            return "inconnu"
        }

        let roundedSeconds = Int(seconds.rounded())
        let hours = roundedSeconds / 3600
        let minutes = (roundedSeconds % 3600) / 60
        let remainingSeconds = roundedSeconds % 60

        if hours > 0 {
            return "\(hours) h \(minutes) min"
        }
        if minutes > 0 {
            return "\(minutes) min \(remainingSeconds) s"
        }
        return "\(remainingSeconds) s"
    }
}

private enum DownloadModeRebootStrategy {
    case direct
    case resumedSession
    case freshSession
}

private func rebootFreshDownloadModeDevice(progressHandler: @escaping (String) -> Void) throws {
    var lastError: Error?

    for attempt in 1...3 {
        for strategy in [DownloadModeRebootStrategy.direct, .resumedSession, .freshSession] {
            let targetLocationID = USBDevice.findDownloadModeDevice()?.locationID

            do {
                try rebootDownloadModeDevice(strategy: strategy, progressHandler: progressHandler)
                if waitForDownloadModeExit(targetLocationID: targetLocationID, progressHandler: progressHandler) {
                    return
                }

                lastError = OdinProtocolError.transportFailure(
                    context: "Sortie Download Mode",
                    reason: "commande envoyée, mais le terminal est toujours détecté en Download Mode"
                )
            } catch {
                lastError = error
                if waitForDownloadModeExit(targetLocationID: targetLocationID, progressHandler: progressHandler) {
                    return
                }
                progressHandler(rebootRetryMessage(for: strategy))
                Thread.sleep(forTimeInterval: 0.35)
            }
        }

        if attempt < 3 {
            progressHandler("Sortie Download Mode : tentative \(attempt) échouée, nouvel essai.")
            Thread.sleep(forTimeInterval: 1.0)
        }
    }

    throw lastError ?? OdinProtocolError.transportFailure(
        context: "Sortie Download Mode",
        reason: "commande non envoyée"
    )
}

private func rebootDownloadModeDevice(
    strategy: DownloadModeRebootStrategy,
    progressHandler: @escaping (String) -> Void
) throws {
    guard let device = USBDevice.findDownloadModeDevice() else {
        throw OdinProtocolError.transportFailure(
            context: "Sortie Download Mode",
            reason: "aucun terminal Download Mode détecté"
        )
    }

    let flashSession = FlashSession(device: device)
    try device.open()
    defer { device.close() }

    progressHandler("Transport ouvert : \(device.transportDescription).")
    for note in device.transportNotes {
        progressHandler("Info transport : \(note)")
    }

    switch strategy {
    case .direct:
        try flashSession.sendRebootCommandWithoutHandshake(progressHandler: progressHandler)
    case .resumedSession:
        try flashSession.rebootFromResumedDownloadMode(progressHandler: progressHandler)
    case .freshSession:
        try flashSession.rebootFromDownloadMode(progressHandler: progressHandler)
    }
}

private func waitForDownloadModeExit(
    targetLocationID: UInt32?,
    progressHandler: @escaping (String) -> Void
) -> Bool {
    guard targetLocationID != nil else {
        return false
    }

    Thread.sleep(forTimeInterval: 0.4)

    for _ in 0..<12 {
        guard let currentDevice = USBDevice.findDownloadModeDevice() else {
            progressHandler("Terminal Download Mode déconnecté : sortie confirmée.")
            return true
        }

        if let targetLocationID, currentDevice.locationID != targetLocationID {
            progressHandler("Terminal Download Mode initial déconnecté : sortie probable.")
            return true
        }

        Thread.sleep(forTimeInterval: 0.5)
    }

    return false
}

private func rebootRetryMessage(for strategy: DownloadModeRebootStrategy) -> String {
    switch strategy {
    case .direct:
        return "Sortie Download Mode : commande directe non confirmée, essai reprise Odin."
    case .resumedSession:
        return "Sortie Download Mode : reprise Odin refusée, essai handshake classique."
    case .freshSession:
        return "Sortie Download Mode : handshake classique non confirme."
    }
}

enum HeimdallFlashError: Error, LocalizedError {
    case noMappings
    case launchFailed(String)
    case outputReadFailed(String)
    case failed(exitCode: Int32, output: String)

    var errorDescription: String? {
        switch self {
        case .noMappings:
            return "aucune image à transmettre à Heimdall."
        case .launchFailed(let reason):
            return "lancement Heimdall impossible : \(reason)"
        case .outputReadFailed(let reason):
            return "lecture de la sortie Heimdall impossible : \(reason)"
        case .failed(let exitCode, let output):
            let details = output.isEmpty ? "aucune sortie Heimdall" : output
            return "Heimdall a retourné le code \(exitCode) : \(details)"
        }
    }
}

enum HeimdallFlashRunner {
    private static let resumeRetryDelay: TimeInterval = 15

    static func findExecutable() -> URL? {
        executableCandidates().first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    static func commandArguments(
        mappings: [FirmwareMapping],
        rebootAfterFlash: Bool,
        resumePreviousSession: Bool = false
    ) -> [String] {
        var arguments = [
            "flash",
            "--stdout-errors",
            "--usb-log-level",
            "none"
        ]

        if resumePreviousSession {
            arguments.append("--resume")
        }

        for mapping in mappings {
            arguments.append("--\(mapping.partition.partitionName)")
            arguments.append(mapping.archiveURL.path)
        }

        if !rebootAfterFlash {
            arguments.append("--no-reboot")
        }

        return arguments
    }

    /// Flashe toutes les images dans une seule session Heimdall : les
    /// frontières de session (fin sans reboot puis --resume) sont la source
    /// principale d'échecs observée sur les bootloaders récents, alors que les
    /// transferts au sein d'une même session passent sans erreur. Si la session
    /// casse malgré tout en cours de route, une unique reprise --resume renvoie
    /// les images restantes (réécrire une image déjà envoyée est sans risque).
    static func flashWithAutomaticResume(
        executableURL: URL,
        mappings: [FirmwareMapping],
        rebootAfterFlash: Bool,
        progressHandler: ((String) -> Void)? = nil,
        flashProgressHandler: ((String, Double) -> Void)? = nil
    ) throws {
        guard !mappings.isEmpty else {
            throw HeimdallFlashError.noMappings
        }

        let orderedMappings = reliabilityOrderedMappings(mappings)
        if orderedMappings.map(\.id) != mappings.map(\.id) {
            let lateNames = orderedMappings
                .filter { requiresLateFlash($0) }
                .map(\.partition.partitionName)
                .joined(separator: ", ")
            progressHandler?("Ordre optimisé : \(lateNames) envoyé en dernier, pour que toutes les petites images soient confirmées avant la grosse écriture.")
        }

        do {
            try flash(
                executableURL: executableURL,
                mappings: orderedMappings,
                rebootAfterFlash: rebootAfterFlash,
                progressHandler: progressHandler,
                flashProgressHandler: flashProgressHandler
            )
        } catch let error as HeimdallFlashError {
            guard case .failed(_, let output) = error,
                  output.contains("Failed to confirm end of file transfer sequence") else {
                throw error
            }

            let remaining = remainingMappingsAfterPartialFlash(output: output, mappings: orderedMappings)
            guard !remaining.isEmpty, remaining.count < orderedMappings.count else {
                throw error
            }

            let completedCount = orderedMappings.count - remaining.count
            let remainingNames = remaining.map(\.partition.partitionName).joined(separator: ", ")
            progressHandler?("Heimdall : session interrompue après \(completedCount) images confirmées. Reprise unique dans \(Int(resumeRetryDelay)) s pour : \(remainingNames).")
            Thread.sleep(forTimeInterval: resumeRetryDelay)

            try flash(
                executableURL: executableURL,
                mappings: remaining,
                rebootAfterFlash: rebootAfterFlash,
                resumePreviousSession: true,
                progressHandler: progressHandler
            ) { partitionName, retryProgress in
                let overallProgress = (Double(completedCount) + retryProgress * Double(remaining.count)) / Double(orderedMappings.count)
                flashProgressHandler?(partitionName, overallProgress)
            }
        }
    }

    /// Place les partitions volumineuses (super, >= 1 Go) en fin de session :
    /// sur plusieurs bootloaders récents, le téléphone cesse de confirmer les
    /// séquences peu après l'écriture d'une très grosse image. En l'envoyant en
    /// dernier, plus aucune confirmation critique n'est attendue après elle
    /// (une fin de session non confirmée est tolérée).
    static func reliabilityOrderedMappings(_ mappings: [FirmwareMapping]) -> [FirmwareMapping] {
        let earlyMappings = mappings.filter { !requiresLateFlash($0) }
        let lateMappings = mappings.filter { requiresLateFlash($0) }
        return earlyMappings + lateMappings
    }

    private static let lateFlashThresholdBytes: UInt64 = 1_000_000_000

    private static func requiresLateFlash(_ mapping: FirmwareMapping) -> Bool {
        mapping.partition.partitionName == "super"
            || mapping.entry.size >= lateFlashThresholdBytes
    }

    /// Images dont la sortie Heimdall ne confirme pas l'envoi ("<partition>
    /// upload successful"), donc à renvoyer lors d'une reprise.
    static func remainingMappingsAfterPartialFlash(output: String, mappings: [FirmwareMapping]) -> [FirmwareMapping] {
        let uploadedNames = confirmedUploadedPartitionNames(in: output)
        return mappings.filter { !uploadedNames.contains($0.partition.partitionName) }
    }

    /// Retourne `true` si Heimdall s'est terminé proprement, `false` si la
    /// seule anomalie est une fin de session non confirmée (images écrites).
    @discardableResult
    static func flash(
        executableURL: URL,
        mappings: [FirmwareMapping],
        rebootAfterFlash: Bool,
        resumePreviousSession: Bool = false,
        progressHandler: ((String) -> Void)? = nil,
        flashProgressHandler: ((String, Double) -> Void)? = nil
    ) throws -> Bool {
        guard !mappings.isEmpty else {
            throw HeimdallFlashError.noMappings
        }

        let arguments = commandArguments(
            mappings: mappings,
            rebootAfterFlash: rebootAfterFlash,
            resumePreviousSession: resumePreviousSession
        )
        progressHandler?("Commande Heimdall : \(executableURL.lastPathComponent) flash \(mappings.count) partitions.")
        if resumePreviousSession {
            progressHandler?("Heimdall reprend la session précédente avec --resume.")
        }
        progressHandler?("Heimdall lance : attente de la connexion USB native.")

        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        process.currentDirectoryURL = FileManager.default.temporaryDirectory

        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = outputPipe

        let outputLock = NSLock()
        var rawOutput = ""
        var lineBuffer = ""
        var progressState = HeimdallProgressState(totalPartitions: mappings.count)

        let consumeOutput: (Data) -> Void = { data in
            guard !data.isEmpty else { return }

            let chunk = String(decoding: data, as: UTF8.self)
            var logMessages: [String] = []
            var progressUpdates: [(partition: String, progress: Double)] = []

            outputLock.lock()
            rawOutput += chunk
            lineBuffer += chunk.replacingOccurrences(of: "\r", with: "\n")

            while let newlineIndex = lineBuffer.firstIndex(of: "\n") {
                let rawLine = String(lineBuffer[..<newlineIndex])
                lineBuffer.removeSubrange(...newlineIndex)

                let line = cleanHeimdallTerminalControls(rawLine)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !line.isEmpty else { continue }

                if let partitionName = uploadingPartitionName(from: line) {
                    progressState.currentPartitionName = partitionName
                    progressUpdates.append((
                        partition: partitionName,
                        progress: progressState.overallProgress(partitionProgress: 0)
                    ))
                }

                if line.hasSuffix("upload successful") {
                    progressState.completedPartitions += 1
                    let partitionName = progressState.currentPartitionName ?? "Heimdall/libusb"
                    progressUpdates.append((
                        partition: partitionName,
                        progress: progressState.overallProgress(partitionProgress: 0)
                    ))
                    progressState.currentPartitionName = nil
                }

                if !isProgressOnlyHeimdallLine(line) {
                    logMessages.append("Heimdall : \(line)")
                }
            }

            if let percent = lastHeimdallProgressPercentage(in: chunk),
               let partitionName = progressState.currentPartitionName {
                progressUpdates.append((
                    partition: partitionName,
                    progress: progressState.overallProgress(partitionProgress: percent / 100)
                ))
            }
            outputLock.unlock()

            for message in logMessages {
                progressHandler?(message)
            }
            for update in progressUpdates {
                flashProgressHandler?(update.partition, update.progress)
            }
        }

        do {
            try process.run()
        } catch {
            throw HeimdallFlashError.launchFailed(String(describing: error))
        }

        let outputReader = outputPipe.fileHandleForReading
        do {
            while true {
                let data = try outputReader.read(upToCount: 64 * 1024) ?? Data()
                guard !data.isEmpty else { break }
                consumeOutput(data)
            }
        } catch {
            process.terminate()
            process.waitUntilExit()
            throw HeimdallFlashError.outputReadFailed(String(describing: error))
        }

        process.waitUntilExit()

        outputLock.lock()
        let pendingLine = cleanHeimdallTerminalControls(lineBuffer)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let outputText = cleanHeimdallTerminalControls(rawOutput)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        outputLock.unlock()

        if !pendingLine.isEmpty && !isProgressOnlyHeimdallLine(pendingLine) {
            progressHandler?("Heimdall : \(pendingLine)")
        }

        guard process.terminationStatus == 0 else {
            if isRecoverableSessionEndFailure(outputText: outputText, mappings: mappings) {
                progressHandler?("Heimdall : confirmation de fin de session absente, mais toutes les images du lot sont confirmées envoyées. Poursuite du flash. Si le téléphone reste en Download Mode à la fin, utilise Quitter Download.")
                return false
            }
            throw HeimdallFlashError.failed(
                exitCode: process.terminationStatus,
                output: String(outputText.suffix(3000))
            )
        }

        return true
    }

    /// "Failed to receive session end confirmation" est un échec connu et bénin
    /// des sessions Heimdall terminées sans reboot : les images sont écrites,
    /// seul l'acquittement de fin de session est perdu.
    static func isRecoverableSessionEndFailure(outputText: String, mappings: [FirmwareMapping]) -> Bool {
        let errorLines = outputText
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.hasPrefix("ERROR:") }

        guard !errorLines.isEmpty,
              errorLines.allSatisfy({ $0.contains("Failed to receive session end confirmation") }) else {
            return false
        }

        let uploadedNames = confirmedUploadedPartitionNames(in: outputText)
        return mappings.allSatisfy { uploadedNames.contains($0.partition.partitionName) }
    }

    /// Noms de partitions dont Heimdall confirme l'envoi, extraits ligne par
    /// ligne pour éviter les faux positifs entre noms préfixés (param/up_param).
    static func confirmedUploadedPartitionNames(in output: String) -> Set<String> {
        let successSuffix = " upload successful"
        var names: Set<String> = []

        for line in output.split(separator: "\n") {
            let trimmedLine = line.trimmingCharacters(in: .whitespaces)
            guard trimmedLine.hasSuffix(successSuffix) else { continue }
            let name = String(trimmedLine.dropLast(successSuffix.count))
            if !name.isEmpty {
                names.insert(name)
            }
        }

        return names
    }

    private struct HeimdallProgressState {
        let totalPartitions: Int
        var completedPartitions = 0
        var currentPartitionName: String?

        func overallProgress(partitionProgress: Double) -> Double {
            guard totalPartitions > 0 else { return 0 }
            let boundedPartitionProgress = min(max(partitionProgress, 0), 1)
            let completed = min(max(completedPartitions, 0), totalPartitions)
            return min((Double(completed) + boundedPartitionProgress) / Double(totalPartitions), 1)
        }
    }

    private static func uploadingPartitionName(from line: String) -> String? {
        let prefix = "Uploading "
        guard line.hasPrefix(prefix) else { return nil }
        return String(line.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func isProgressOnlyHeimdallLine(_ line: String) -> Bool {
        line.contains("%")
            && line.allSatisfy { character in
                character.isNumber || character == "%" || character.isWhitespace
            }
    }

    private static func lastHeimdallProgressPercentage(in text: String) -> Double? {
        var digits = ""
        var lastPercent: Double?

        for character in text {
            if character.isNumber {
                digits.append(character)
            } else if character == "%" {
                if let value = Double(digits) {
                    lastPercent = value
                }
                digits = ""
            } else if character != "\u{8}" {
                digits = ""
            }
        }

        return lastPercent
    }

    private static func cleanHeimdallTerminalControls(_ text: String) -> String {
        var scalars: [UnicodeScalar] = []

        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 8:
                if !scalars.isEmpty {
                    scalars.removeLast()
                }
            case 13:
                scalars.append("\n")
            case 9, 10, 32...UInt32.max:
                scalars.append(scalar)
            default:
                continue
            }
        }

        return String(String.UnicodeScalarView(scalars))
    }

    private static func executableCandidates() -> [URL] {
        var candidates: [URL] = []

        if let bundledExecutable = Bundle.main.url(forResource: "heimdall", withExtension: nil) {
            candidates.append(bundledExecutable)
        }

        candidates.append(contentsOf: [
            URL(fileURLWithPath: "/opt/homebrew/bin/heimdall-androidflash"),
            URL(fileURLWithPath: "/usr/local/bin/heimdall-androidflash"),
            URL(fileURLWithPath: "/private/tmp/AndroidFLASH-Heimdall/build/bin/heimdall-androidflash")
        ])

        let environmentPath = ProcessInfo.processInfo.environment["PATH"] ?? ""
        for directory in environmentPath.split(separator: ":") {
            let directoryURL = URL(fileURLWithPath: String(directory))
            candidates.append(directoryURL.appendingPathComponent("heimdall-androidflash"))
            candidates.append(directoryURL.appendingPathComponent("heimdall"))
        }

        candidates.append(contentsOf: [
            URL(fileURLWithPath: "/opt/homebrew/bin/heimdall"),
            URL(fileURLWithPath: "/usr/local/bin/heimdall"),
            URL(fileURLWithPath: "/opt/local/bin/heimdall"),
            URL(fileURLWithPath: "/Applications/heimdall-frontend.app/Contents/MacOS/heimdall"),
            URL(fileURLWithPath: "/Applications/Heimdall Frontend.app/Contents/MacOS/heimdall"),
            URL(fileURLWithPath: "/Applications/Heimdall Suite.app/Contents/MacOS/heimdall")
        ])

        var seenPaths: Set<String> = []
        return candidates.filter { seenPaths.insert($0.path).inserted }
    }

}
