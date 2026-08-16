import CryptoKit
import Foundation
import Testing
@testable import FlashPort

struct Android_FLASHTests {

    @Test func parsesPitHeaderAndSingleEntry() throws {
        let data = makePitData()

        let pitFile = try PitFile.parse(data)

        #expect(pitFile.unknown1 == 10)
        #expect(pitFile.unknown2 == 20)
        #expect(pitFile.unknown3 == 30)
        #expect(pitFile.unknown8 == 80)
        #expect(pitFile.entries.count == 1)

        let entry = try #require(pitFile.entries.first)
        #expect(entry.binaryType == 0)
        #expect(entry.deviceType == 2)
        #expect(entry.identifier == 7)
        #expect(entry.attributes == 1)
        #expect(entry.updateAttributes == 2)
        #expect(entry.blockSizeOrOffset == 4096)
        #expect(entry.blockCount == 128)
        #expect(entry.partitionName == "BOOT")
        #expect(entry.flashFilename == "boot.img")
        #expect(entry.fotaFilename == "boot.fota")
    }

    @Test func serializesPitDataWithOptionalPadding() throws {
        let entry = PitEntry(
            binaryType: 0,
            deviceType: 2,
            identifier: 7,
            attributes: 1,
            updateAttributes: 2,
            blockSizeOrOffset: 4096,
            blockCount: 128,
            fileOffset: 0,
            fileSize: 0,
            partitionName: "BOOT",
            flashFilename: "boot.img",
            fotaFilename: "boot.fota"
        )
        let pitFile = PitFile(
            unknown1: 10,
            unknown2: 20,
            unknown3: 30,
            unknown4: 40,
            unknown5: 50,
            unknown6: 60,
            unknown7: 70,
            unknown8: 80,
            entries: [entry]
        )

        let serialized = try pitFile.serialize()
        let padded = try pitFile.paddedSerialize()

        #expect(serialized.count == 160)
        #expect(padded.count == 4096)
        #expect(try PitFile.parse(serialized) == pitFile)
        #expect(try PitFile.parse(padded) == pitFile)
    }

    @Test func rejectsInvalidPitIdentifier() {
        let data = Data(repeating: 0, count: 28)
        var caughtError: PitFileError?

        do {
            _ = try PitFile.parse(data)
        } catch let error as PitFileError {
            caughtError = error
        } catch {
            caughtError = nil
        }

        #expect(caughtError == .invalidIdentifier(0))
    }

    @Test func serializesOdinControlPacketsLittleEndian() {
        let packet = SessionCommandPacket(
            controlType: OdinProtocol.ControlType.session.rawValue,
            request: OdinProtocol.SessionRequest.beginSession.rawValue,
            payload: [0x01020304]
        )

        let data = packet.serialize()

        #expect(data.count == OdinProtocol.sessionPacketSize)
        #expect(Array(data.prefix(12)) == [
            0x64, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00,
            0x04, 0x03, 0x02, 0x01
        ])
    }

    @Test func serializesFileTransferPartPacket() {
        let packet = SessionCommandPacket(
            controlType: OdinProtocol.ControlType.fileTransfer.rawValue,
            request: OdinProtocol.FileTransferRequest.part.rawValue,
            payload: [UInt32(OdinProtocol.negotiatedFilePartSize)]
        )

        let data = packet.serialize()

        #expect(data.count == OdinProtocol.sessionPacketSize)
        #expect(Array(data.prefix(12)) == [
            0x66, 0x00, 0x00, 0x00,
            0x02, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x10, 0x00
        ])
    }

    @Test func serializesCompressedFileTransferCommands() {
        let beginPacket = SessionCommandPacket(
            controlType: OdinProtocol.ControlType.fileTransfer.rawValue,
            request: OdinProtocol.FileTransferRequest.compressedFlash.rawValue,
            payload: []
        )
        let partPacket = SessionCommandPacket(
            controlType: OdinProtocol.ControlType.fileTransfer.rawValue,
            request: OdinProtocol.FileTransferRequest.compressedPart.rawValue,
            payload: [UInt32(OdinProtocol.negotiatedFilePartSize)]
        )
        let endPacket = SessionCommandPacket(
            controlType: OdinProtocol.ControlType.fileTransfer.rawValue,
            request: OdinProtocol.FileTransferRequest.compressedEnd.rawValue,
            payload: []
        )

        #expect(Array(beginPacket.serialize().prefix(8)) == [
            0x66, 0x00, 0x00, 0x00,
            0x05, 0x00, 0x00, 0x00
        ])
        #expect(Array(partPacket.serialize().prefix(8)) == [
            0x66, 0x00, 0x00, 0x00,
            0x06, 0x00, 0x00, 0x00
        ])
        #expect(Array(endPacket.serialize().prefix(8)) == [
            0x66, 0x00, 0x00, 0x00,
            0x07, 0x00, 0x00, 0x00
        ])
    }

    @Test func serializesEndPhoneFileTransferPacket() {
        let packet = SessionCommandPacket(
            controlType: OdinProtocol.ControlType.fileTransfer.rawValue,
            request: OdinProtocol.FileTransferRequest.end.rawValue,
            payload: [
                OdinProtocol.FileTransferDestination.phone.rawValue,
                1_234,
                0,
                2,
                7,
                1
            ]
        )

        let data = packet.serialize()

        #expect(data.count == OdinProtocol.sessionPacketSize)
        #expect(Array(data.prefix(32)) == [
            0x66, 0x00, 0x00, 0x00,
            0x03, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00,
            0xD2, 0x04, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00,
            0x02, 0x00, 0x00, 0x00,
            0x07, 0x00, 0x00, 0x00,
            0x01, 0x00, 0x00, 0x00
        ])
    }

    @Test func readsTarMd5FirmwareEntries() throws {
        let url = try makeTemporaryTar(entries: [
            ("boot.img.lz4", Data(repeating: 0x11, count: 4)),
            ("super.img.lz4", Data(repeating: 0x22, count: 7))
        ])
        defer { try? FileManager.default.removeItem(at: url) }

        let archive = try SamsungFirmwareArchiveReader.readArchive(url: url, slot: .ap)

        #expect(archive.slot == .ap)
        #expect(archive.entries.map(\.fileName) == ["boot.img.lz4", "super.img.lz4"])
        #expect(archive.entries.map(\.normalizedPartitionCandidate) == ["boot", "super"])
    }

    @Test func readsDownloadListImageNamesFromArchive() throws {
        let downloadList = "boot.img\nsuper.img\ncache.img\n"
        let url = try makeTemporaryTar(entries: [
            ("boot.img.lz4", Data(repeating: 0x11, count: 4)),
            ("misc.bin.lz4", Data(repeating: 0x33, count: 4)),
            ("meta-data/download-list.txt", Data(downloadList.utf8))
        ])
        defer { try? FileManager.default.removeItem(at: url) }

        let archive = try SamsungFirmwareArchiveReader.readArchive(url: url, slot: .ap)

        #expect(archive.downloadListImageNames == ["boot.img", "super.img", "cache.img"])
    }

    @Test func archiveWithoutDownloadListHasNoRestriction() throws {
        let url = try makeTemporaryTar(entries: [
            ("boot.img.lz4", Data(repeating: 0x11, count: 4))
        ])
        defer { try? FileManager.default.removeItem(at: url) }

        let archive = try SamsungFirmwareArchiveReader.readArchive(url: url, slot: .ap)

        #expect(archive.downloadListImageNames == nil)
    }

    private func makeRawTarData() -> Data {
        var data = Data()
        data.append(makeTarHeader(name: "boot.img.lz4", size: 4))
        data.append(Data(repeating: 0x11, count: 4))
        data.append(Data(repeating: 0, count: 508))
        data.append(Data(repeating: 0, count: 1024))
        return data
    }

    private func writeTemporaryTarMd5(_ data: Data) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("FlashPortTest-\(UUID().uuidString).tar.md5")
        try data.write(to: url)
        return url
    }

    @Test func verifiesTarMd5Trailer() throws {
        var content = makeRawTarData()
        let digest = Insecure.MD5.hash(data: content).map { String(format: "%02x", $0) }.joined()
        content.append(Data("\(digest)  AP_test.tar\n".utf8))

        let md5URL = try writeTemporaryTarMd5(content)
        defer { try? FileManager.default.removeItem(at: md5URL) }

        #expect(try FirmwareMd5Verifier.verify(url: md5URL) == true)
    }

    @Test func rejectsCorruptedTarMd5() throws {
        var content = makeRawTarData()
        let digest = Insecure.MD5.hash(data: content).map { String(format: "%02x", $0) }.joined()
        content[600] ^= 0xFF
        content.append(Data("\(digest)  AP_test.tar\n".utf8))

        let md5URL = try writeTemporaryTarMd5(content)
        defer { try? FileManager.default.removeItem(at: md5URL) }

        #expect(throws: FirmwareMd5Error.self) {
            try FirmwareMd5Verifier.verify(url: md5URL)
        }
    }

    @Test func skipsMd5VerificationWithoutTrailer() throws {
        let md5URL = try writeTemporaryTarMd5(makeRawTarData())
        defer { try? FileManager.default.removeItem(at: md5URL) }

        #expect(try FirmwareMd5Verifier.verify(url: md5URL) == false)
    }

    @MainActor
    @Test func recommendedSelectionHonorsOdinDownloadList() {
        func mapping(_ imageName: String, partitionName: String, index: Int) -> FirmwareMapping {
            FirmwareMapping(
                slot: .ap,
                archiveName: "AP.tar.md5",
                archiveURL: URL(fileURLWithPath: "/tmp/AP.tar.md5"),
                archiveEntryIndex: index,
                entry: FirmwareArchiveEntry(path: imageName, size: 42, dataOffset: 0),
                partition: makePitEntry(partitionName: partitionName, flashFilename: imageName)
            )
        }

        let bootMapping = mapping("boot.img.lz4", partitionName: "boot", index: 0)
        let miscMapping = mapping("misc.bin.lz4", partitionName: "misc", index: 1)
        var archive = FirmwareArchive(
            slot: .homeCSC,
            url: URL(fileURLWithPath: "/tmp/HOME_CSC.tar.md5"),
            entries: []
        )
        archive.downloadListImageNames = ["boot.img"]

        let viewModel = FlashViewModel()
        viewModel.firmwareArchives = [archive]
        viewModel.firmwareMappings = [bootMapping, miscMapping]

        viewModel.selectRecommendedFirmwareMappings()

        #expect(viewModel.selectedFirmwareMappingIDs == [bootMapping.id])
        #expect(viewModel.logLines.contains { $0.contains("Exclusion download-list Odin") && $0.contains("misc.bin.lz4") })

        viewModel.setFirmwareMappingSelection(miscMapping.id, isSelected: true)
        #expect(viewModel.selectionWarnings.contains { $0.contains("Hors download-list Odin") })
    }

    @Test func decodesLZ4FrameWithUncompressedBlock() throws {
        let payload = Data("cache image".utf8)
        let inputURL = try makeTemporaryDataFile(makeLZ4Frame(block: payload, isUncompressed: true), extension: "lz4")
        let outputURL = try makeTemporaryDataFile(Data(), extension: "img")
        defer {
            try? FileManager.default.removeItem(at: inputURL)
            try? FileManager.default.removeItem(at: outputURL)
        }

        let input = try FileHandle(forReadingFrom: inputURL)
        defer { try? input.close() }
        let output = try FileHandle(forWritingTo: outputURL)
        defer { try? output.close() }

        let decodedSize = try LZ4FrameDecoder.decodeFrame(
            from: input,
            offset: 0,
            length: UInt64(try Data(contentsOf: inputURL).count),
            name: "cache.img.lz4",
            to: output
        )

        #expect(decodedSize == UInt64(payload.count))
        #expect(try Data(contentsOf: outputURL) == payload)
    }

    @Test func decodesLZ4FrameWithCompressedBlock() throws {
        var compressedBlock = Data([0x35])
        compressedBlock.append(Data("abc".utf8))
        compressedBlock.append(contentsOf: [0x03, 0x00])
        let inputURL = try makeTemporaryDataFile(makeLZ4Frame(block: compressedBlock, isUncompressed: false), extension: "lz4")
        let outputURL = try makeTemporaryDataFile(Data(), extension: "img")
        defer {
            try? FileManager.default.removeItem(at: inputURL)
            try? FileManager.default.removeItem(at: outputURL)
        }

        let input = try FileHandle(forReadingFrom: inputURL)
        defer { try? input.close() }
        let output = try FileHandle(forWritingTo: outputURL)
        defer { try? output.close() }

        let decodedSize = try LZ4FrameDecoder.decodeFrame(
            from: input,
            offset: 0,
            length: UInt64(try Data(contentsOf: inputURL).count),
            name: "omr.img.lz4",
            to: output
        )

        let expected = Data("abcabcabcabc".utf8)
        #expect(decodedSize == UInt64(expected.count))
        #expect(try Data(contentsOf: outputURL) == expected)
    }

    @Test func keepsLZ4PayloadCompressedForOdinFlash() throws {
        let url = try makeTemporaryTar(entries: [
            ("boot.img.lz4", makeLZ4Frame(block: Data("boot".utf8), isUncompressed: true))
        ])
        defer { try? FileManager.default.removeItem(at: url) }

        let archive = try SamsungFirmwareArchiveReader.readArchive(url: url, slot: .ap)
        let entry = try #require(archive.entries.first)
        let mapping = FirmwareMapping(
            slot: .ap,
            archiveName: archive.displayName,
            archiveURL: archive.url,
            archiveEntryIndex: 0,
            entry: entry,
            partition: makePitEntry(partitionName: "boot", flashFilename: "boot.img")
        )

        let prepared = try FirmwarePayloadPreparer.prepare(
            mappings: [mapping],
            preservesCompressedLZ4: true
        )

        #expect(prepared.temporaryURLs.isEmpty)
        #expect(prepared.mappings.first?.archiveURL == url)
        #expect(prepared.mappings.first?.entry.fileName == "boot.img.lz4")
        #expect(prepared.mappings.first?.entry.size == entry.size)
        #expect(prepared.mappings.first?.entry.dataOffset == entry.dataOffset)
    }

    @Test func decompressesLZ4PayloadWhenCompressedTransferUnsupported() throws {
        let payload = Data("boot image".utf8)
        let url = try makeTemporaryTar(entries: [
            ("boot.img.lz4", makeLZ4Frame(block: payload, isUncompressed: true))
        ])
        defer { try? FileManager.default.removeItem(at: url) }

        let archive = try SamsungFirmwareArchiveReader.readArchive(url: url, slot: .ap)
        let entry = try #require(archive.entries.first)
        let mapping = FirmwareMapping(
            slot: .ap,
            archiveName: archive.displayName,
            archiveURL: archive.url,
            archiveEntryIndex: 0,
            entry: entry,
            partition: makePitEntry(partitionName: "boot", flashFilename: "boot.img")
        )

        let prepared = try FirmwarePayloadPreparer.prepare(
            mappings: [mapping],
            preservesCompressedLZ4: false
        )
        defer { prepared.cleanup() }

        let preparedMapping = try #require(prepared.mappings.first)
        #expect(prepared.temporaryURLs.count == 1)
        #expect(preparedMapping.archiveURL == prepared.temporaryURLs.first)
        #expect(preparedMapping.entry.fileName == "boot.img")
        #expect(preparedMapping.entry.size == UInt64(payload.count))
        #expect(preparedMapping.entry.dataOffset == 0)
        #expect(try Data(contentsOf: preparedMapping.archiveURL) == payload)
    }

    @Test func extractsRawTarEntryForStandaloneHeimdallPayload() throws {
        let payload = Data("param image".utf8)
        let url = try makeTemporaryTar(entries: [
            ("param.bin", payload)
        ])
        defer { try? FileManager.default.removeItem(at: url) }

        let archive = try SamsungFirmwareArchiveReader.readArchive(url: url, slot: .bl)
        let entry = try #require(archive.entries.first)
        let mapping = FirmwareMapping(
            slot: .bl,
            archiveName: archive.displayName,
            archiveURL: archive.url,
            archiveEntryIndex: 0,
            entry: entry,
            partition: makePitEntry(partitionName: "param", flashFilename: "param.bin")
        )

        let prepared = try FirmwarePayloadPreparer.prepare(
            mappings: [mapping],
            preservesCompressedLZ4: false,
            requiresStandaloneFiles: true
        )
        defer { prepared.cleanup() }

        let preparedMapping = try #require(prepared.mappings.first)
        #expect(prepared.temporaryURLs.count == 1)
        #expect(preparedMapping.archiveURL == prepared.temporaryURLs.first)
        #expect(preparedMapping.entry.fileName == "param.bin")
        #expect(preparedMapping.entry.size == UInt64(payload.count))
        #expect(preparedMapping.entry.dataOffset == 0)
        #expect(try Data(contentsOf: preparedMapping.archiveURL) == payload)
    }

    @Test func buildsHeimdallFlashCommandWithPartitionNames() {
        let imageURL = URL(fileURLWithPath: "/tmp/userdata.img")
        let mapping = FirmwareMapping(
            slot: .ap,
            archiveName: "AP.tar.md5",
            archiveURL: imageURL,
            archiveEntryIndex: 0,
            entry: FirmwareArchiveEntry(path: "userdata.img", size: 42, dataOffset: 0),
            partition: makePitEntry(partitionName: "userdata", flashFilename: "userdata.img", identifier: 54)
        )

        let arguments = HeimdallFlashRunner.commandArguments(
            mappings: [mapping],
            rebootAfterFlash: false
        )

        #expect(arguments == [
            "flash",
            "--stdout-errors",
            "--usb-log-level",
            "none",
            "--userdata",
            "/tmp/userdata.img",
            "--no-reboot"
        ])
    }

    @MainActor
    @Test func recommendedSelectionHandlesUserdataByDataMode() {
        let bootMapping = FirmwareMapping(
            slot: .ap,
            archiveName: "AP.tar.md5",
            archiveURL: URL(fileURLWithPath: "/tmp/AP.tar.md5"),
            archiveEntryIndex: 0,
            entry: FirmwareArchiveEntry(path: "boot.img.lz4", size: 42, dataOffset: 0),
            partition: makePitEntry(partitionName: "boot", flashFilename: "boot.img")
        )
        let userdataMapping = FirmwareMapping(
            slot: .ap,
            archiveName: "AP.tar.md5",
            archiveURL: URL(fileURLWithPath: "/tmp/AP.tar.md5"),
            archiveEntryIndex: 1,
            entry: FirmwareArchiveEntry(path: "userdata.img.lz4", size: 42, dataOffset: 512),
            partition: makePitEntry(partitionName: "userdata", flashFilename: "userdata.img")
        )
        let viewModel = FlashViewModel()
        viewModel.flashBackend = .heimdall
        viewModel.firmwareMappings = [bootMapping, userdataMapping]
        viewModel.firmwareDataMode = .erase

        viewModel.selectRecommendedFirmwareMappings()

        #expect(viewModel.selectedFirmwareMappingIDs == [bootMapping.id])
        #expect(viewModel.logLines.contains { $0.contains("userdata ajouté automatiquement au flash Swift natif") })
        #expect(viewModel.selectionWarnings.contains { $0.contains("Swift natif en session unique") })

        viewModel.firmwareDataMode = .preserve
        viewModel.selectRecommendedFirmwareMappings()

        #expect(viewModel.selectedFirmwareMappingIDs == [bootMapping.id])
        #expect(viewModel.logLines.contains { $0.contains("userdata exclu") })
        #expect(viewModel.selectionWarnings.isEmpty)

        viewModel.flashBackend = .nativeSwift
        viewModel.firmwareDataMode = .erase
        viewModel.selectRecommendedFirmwareMappings()

        #expect(viewModel.selectedFirmwareMappingIDs == [bootMapping.id, userdataMapping.id])
        #expect(viewModel.logLines.contains { $0.contains("userdata inclus") })
        #expect(viewModel.selectionWarnings.contains { $0.contains("l'envoi peut prendre du temps") })
    }

    @MainActor
    @Test func userdataOnlySelectionUsesNativeSwiftWithPit() throws {
        let archive = FirmwareArchive(
            slot: .ap,
            url: URL(fileURLWithPath: "/tmp/AP.tar.md5"),
            entries: [
                FirmwareArchiveEntry(path: "boot.img.lz4", size: 4, dataOffset: 512),
                FirmwareArchiveEntry(path: "userdata.img.lz4", size: 4, dataOffset: 1024)
            ]
        )
        let viewModel = FlashViewModel()
        viewModel.flashBackend = .heimdall
        viewModel.firmwareArchives = [archive]
        viewModel.pitEntries = [
            makePitEntry(partitionName: "boot", flashFilename: "boot.img"),
            makePitEntry(partitionName: "userdata", flashFilename: "userdata.img")
        ]

        viewModel.selectUserdataOnlyFirmwareMapping()

        let selectedMapping = try #require(viewModel.selectedFirmwareMappings.first)
        #expect(viewModel.flashBackend == .nativeSwift)
        #expect(viewModel.selectedFirmwareMappings.count == 1)
        #expect(selectedMapping.partition.partitionName == "userdata")
        #expect(viewModel.logLines.contains { $0.contains("Backend Natif (Swift) actif") })
    }

    @Test func buildsHeimdallFlashCommandForLargeSuperPartition() {
        let mapping = FirmwareMapping(
            slot: .ap,
            archiveName: "AP.tar.md5",
            archiveURL: URL(fileURLWithPath: "/tmp/super.img"),
            archiveEntryIndex: 0,
            entry: FirmwareArchiveEntry(path: "super.img", size: 7_020_000_000, dataOffset: 0),
            partition: makePitEntry(partitionName: "super", flashFilename: "super.img")
        )

        let arguments = HeimdallFlashRunner.commandArguments(
            mappings: [mapping],
            rebootAfterFlash: true
        )

        #expect(arguments.contains("--super"))
        #expect(arguments.contains("/tmp/super.img"))
    }

    @Test func computesRemainingMappingsAfterPartialFlash() {
        func mapping(_ partitionName: String, index: Int) -> FirmwareMapping {
            FirmwareMapping(
                slot: .ap,
                archiveName: "AP.tar.md5",
                archiveURL: URL(fileURLWithPath: "/tmp/\(partitionName).img"),
                archiveEntryIndex: index,
                entry: FirmwareArchiveEntry(path: "\(partitionName).img", size: 42, dataOffset: 0),
                partition: makePitEntry(partitionName: partitionName, flashFilename: "\(partitionName).img")
            )
        }

        let mappings = [
            mapping("param", index: 0),
            mapping("up_param", index: 1),
            mapping("super", index: 2),
            mapping("scp1", index: 3),
            mapping("prism", index: 4)
        ]

        let output = """
        Uploading up_param
        up_param upload successful
        Uploading super
        super upload successful
        Uploading scp1
        ERROR: Failed to confirm end of file transfer sequence!
        ERROR: scp1 upload failed!
        """

        let remaining = HeimdallFlashRunner.remainingMappingsAfterPartialFlash(output: output, mappings: mappings)

        // "param" ne doit pas être considéré comme envoyé à cause de la ligne
        // "up_param upload successful".
        #expect(remaining.map(\.partition.partitionName) == ["param", "scp1", "prism"])
    }

    @Test func sendsLargePartitionsLastForReliability() {
        func mapping(_ partitionName: String, size: UInt64, index: Int) -> FirmwareMapping {
            FirmwareMapping(
                slot: .ap,
                archiveName: "AP.tar.md5",
                archiveURL: URL(fileURLWithPath: "/tmp/\(partitionName).img"),
                archiveEntryIndex: index,
                entry: FirmwareArchiveEntry(path: "\(partitionName).img", size: size, dataOffset: 0),
                partition: makePitEntry(partitionName: partitionName, flashFilename: "\(partitionName).img")
            )
        }

        let ordered = HeimdallFlashRunner.reliabilityOrderedMappings([
            mapping("bootloader", size: 4_200_000, index: 0),
            mapping("boot", size: 33_600_000, index: 1),
            mapping("super", size: 5_940_000_000, index: 2),
            mapping("scp1", size: 195_000, index: 3),
            mapping("prism", size: 658_200_000, index: 4)
        ])

        #expect(ordered.map(\.partition.partitionName) == ["bootloader", "boot", "scp1", "prism", "super"])
    }

    @Test func extractsConfirmedUploadedPartitionNamesLineByLine() {
        let output = """
        Uploading up_param
        up_param upload successful
        Uploading boot
        boot upload successful
        Uploading dtbo
        """

        let names = HeimdallFlashRunner.confirmedUploadedPartitionNames(in: output)

        #expect(names == ["up_param", "boot"])
    }

    @Test func treatsSessionEndConfirmationFailureAsRecoverable() {
        let mapping = FirmwareMapping(
            slot: .bl,
            archiveName: "BL.tar.md5",
            archiveURL: URL(fileURLWithPath: "/tmp/lk.img"),
            archiveEntryIndex: 0,
            entry: FirmwareArchiveEntry(path: "lk.img", size: 42, dataOffset: 0),
            partition: makePitEntry(partitionName: "lk", flashFilename: "lk.img")
        )

        let recoverableOutput = """
        Uploading lk
        lk upload successful
        Ending session...
        ERROR: Failed to receive session end confirmation!
        ERROR: Failed to receive session end confirmation!
        Releasing device interface...
        """
        #expect(HeimdallFlashRunner.isRecoverableSessionEndFailure(outputText: recoverableOutput, mappings: [mapping]))

        let uploadFailureOutput = """
        Uploading lk
        ERROR: lk upload failed!
        ERROR: Failed to receive session end confirmation!
        """
        #expect(!HeimdallFlashRunner.isRecoverableSessionEndFailure(outputText: uploadFailureOutput, mappings: [mapping]))

        let incompleteUploadOutput = """
        Uploading lk
        ERROR: Failed to receive session end confirmation!
        """
        #expect(!HeimdallFlashRunner.isRecoverableSessionEndFailure(outputText: incompleteUploadOutput, mappings: [mapping]))

        #expect(!HeimdallFlashRunner.isRecoverableSessionEndFailure(outputText: "lk upload successful", mappings: [mapping]))
    }

    @Test func buildsHeimdallResumeCommandAfterNoRebootBatch() throws {
        let mapping = FirmwareMapping(
            slot: .ap,
            archiveName: "AP.tar.md5",
            archiveURL: URL(fileURLWithPath: "/tmp/lk.img"),
            archiveEntryIndex: 0,
            entry: FirmwareArchiveEntry(path: "lk.img", size: 42, dataOffset: 0),
            partition: makePitEntry(partitionName: "lk", flashFilename: "lk.img")
        )

        let arguments = HeimdallFlashRunner.commandArguments(
            mappings: [mapping],
            rebootAfterFlash: false,
            resumePreviousSession: true
        )

        #expect(arguments.contains("--resume"))
        #expect(arguments.contains("--no-reboot"))
        let resumeIndex = try #require(arguments.firstIndex(of: "--resume"))
        let partitionIndex = try #require(arguments.firstIndex(of: "--lk"))
        #expect(resumeIndex < partitionIndex)
    }

    @Test func mapsFirmwareEntriesForHeimdallWithoutPit() throws {
        let archive = FirmwareArchive(
            slot: .ap,
            url: URL(fileURLWithPath: "/tmp/AP.tar.md5"),
            entries: [
                FirmwareArchiveEntry(path: "boot.img.lz4", size: 4, dataOffset: 512),
                FirmwareArchiveEntry(path: "dpm-verified.img.lz4", size: 4, dataOffset: 1024),
                FirmwareArchiveEntry(path: "spmfw-verified.img.lz4", size: 4, dataOffset: 1536),
                FirmwareArchiveEntry(path: "fota.zip", size: 4, dataOffset: 2048)
            ]
        )

        let report = FirmwareMapper.validate(
            archives: [archive],
            pitEntries: [],
            allowsDirectPartitionNames: true
        )

        #expect(report.mappings.map(\.partition.partitionName) == ["boot", "dpm_1", "spmfw"])
        #expect(report.unmatchedEntries.map(\.entry.fileName) == ["fota.zip"])
        #expect(report.errors.isEmpty)
    }

    @Test func mapsFirmwareEntriesToPitPartitions() throws {
        let archive = FirmwareArchive(
            slot: .ap,
            url: URL(fileURLWithPath: "/tmp/AP.tar.md5"),
            entries: [
                FirmwareArchiveEntry(path: "boot.img.lz4", size: 4, dataOffset: 512),
                FirmwareArchiveEntry(path: "unknown.img.lz4", size: 4, dataOffset: 1024)
            ]
        )
        let pitEntries = [
            PitEntry(
                binaryType: 0,
                deviceType: 2,
                identifier: 1,
                attributes: 0,
                updateAttributes: 0,
                blockSizeOrOffset: 0,
                blockCount: 1,
                fileOffset: 0,
                fileSize: 0,
                partitionName: "boot",
                flashFilename: "boot.img",
                fotaFilename: ""
            )
        ]

        let report = FirmwareMapper.validate(archives: [archive], pitEntries: pitEntries)

        #expect(report.mappings.count == 1)
        #expect(report.mappings.first?.partition.partitionName == "boot")
        #expect(report.unmatchedEntries.map(\.entry.fileName) == ["unknown.img.lz4"])
        #expect(report.errors.contains { $0.contains("unknown.img.lz4") })
    }

    @Test func describesInsufficientDiskSpaceError() {
        let error = FirmwareBundleImportError.insufficientDiskSpace(
            requiredBytes: 8_000_000_000,
            availableBytes: 3_000_000_000
        )

        let description = error.errorDescription ?? ""
        #expect(description.contains("Espace disque insuffisant"))
        #expect(description.contains("8 GB") || description.contains("8 Go"))
        #expect(description.contains("3 GB") || description.contains("3 Go"))
    }

    @Test func importsBareRecoveryImageAsRecoveryPartitionTarget() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("FlashPortTest-twrp-3.7.0-a13ve-\(UUID().uuidString).img")
        try Data(repeating: 0xAB, count: 2048).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let archive = try RecoveryImageImporter.makeArchive(from: url)

        #expect(archive.slot == .ap)
        #expect(archive.url == url)
        #expect(archive.entries.map(\.fileName) == ["recovery.img"])
        #expect(archive.entries.first?.size == 2048)
        #expect(archive.entries.first?.dataOffset == 0)
        #expect(archive.entries.first?.normalizedPartitionCandidate == "recovery")
    }

    @Test func importsRecoveryFromTarAndRenamesEntry() throws {
        let url = try makeTemporaryTar(entries: [
            ("twrp-3.7.0_9-a13ve.img", Data(repeating: 0xCD, count: 4))
        ])
        defer { try? FileManager.default.removeItem(at: url) }

        let archive = try RecoveryImageImporter.makeArchive(from: url)

        #expect(archive.entries.map(\.fileName) == ["recovery.img"])
        #expect(archive.entries.first?.size == 4)
        #expect(archive.entries.first?.dataOffset == 512)
    }

    @Test func rejectsUnsupportedOrOversizedRecoveryFiles() throws {
        let zipURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("FlashPortTest-\(UUID().uuidString).zip")
        try Data(repeating: 0x01, count: 8).write(to: zipURL)
        defer { try? FileManager.default.removeItem(at: zipURL) }

        #expect(throws: RecoveryImportError.self) {
            try RecoveryImageImporter.makeArchive(from: zipURL)
        }

        let oversizedURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("FlashPortTest-\(UUID().uuidString).img")
        FileManager.default.createFile(atPath: oversizedURL.path, contents: nil)
        let handle = try FileHandle(forWritingTo: oversizedURL)
        try handle.truncate(atOffset: 300 * 1024 * 1024)
        try handle.close()
        defer { try? FileManager.default.removeItem(at: oversizedURL) }

        #expect(throws: RecoveryImportError.self) {
            try RecoveryImageImporter.makeArchive(from: oversizedURL)
        }
    }

    @Test func comparesReleaseVersionsForUpdateCheck() throws {
        let beta2 = try #require(ReleaseVersion(tag: "v1.0.0-beta.2"))
        let beta3 = try #require(ReleaseVersion(tag: "v1.0.0-beta.3"))
        let beta10 = try #require(ReleaseVersion(tag: "v1.0.0-beta.10"))
        let stable = try #require(ReleaseVersion(tag: "v1.0.0"))
        let nextMinor = try #require(ReleaseVersion(tag: "1.1.0-beta.1"))

        #expect(beta2 < beta3)
        #expect(beta3 < beta10)
        #expect(beta10 < stable)
        #expect(stable < nextMinor)
        #expect(!(beta2 < beta2))
        #expect(ReleaseVersion(tag: "n-importe-quoi") == nil)
    }

    @Test func doesNotBlockImportedFirmwareBeforePitIsLoaded() {
        let archive = FirmwareArchive(
            slot: .ap,
            url: URL(fileURLWithPath: "/tmp/AP.tar.md5"),
            entries: [
                FirmwareArchiveEntry(path: "boot.img.lz4", size: 4, dataOffset: 512),
                FirmwareArchiveEntry(path: "super.img.lz4", size: 4, dataOffset: 1024)
            ]
        )

        let report = FirmwareMapper.validate(
            archives: [archive],
            pitEntries: [],
            allowsDirectPartitionNames: false
        )

        // Sans PIT ni noms directs, les images non associées ne doivent pas
        // bloquer : la validation finale a lieu après la lecture du PIT.
        #expect(report.errors.isEmpty)
        #expect(report.warnings.contains { $0.contains("Lire le PIT") })
        #expect(report.unmatchedEntries.count == 2)
    }

    @Test func mapsCompressedEntryUsingPitFlashFilename() throws {
        let archive = FirmwareArchive(
            slot: .bl,
            url: URL(fileURLWithPath: "/tmp/BL.tar.md5"),
            entries: [
                FirmwareArchiveEntry(path: "preloader.img.lz4", size: 4, dataOffset: 512)
            ]
        )
        let pitEntries = [
            makePitEntry(partitionName: "bootloader", flashFilename: "preloader.img")
        ]

        let report = FirmwareMapper.validate(archives: [archive], pitEntries: pitEntries)

        #expect(report.mappings.count == 1)
        #expect(report.mappings.first?.partition.partitionName == "bootloader")
        #expect(report.errors.isEmpty)
    }

    @Test func mapsCpModemEntryToMd1imgPartition() throws {
        let archive = FirmwareArchive(
            slot: .cp,
            url: URL(fileURLWithPath: "/tmp/CP.tar.md5"),
            entries: [
                FirmwareArchiveEntry(path: "modem.bin.lz4", size: 4, dataOffset: 512),
                FirmwareArchiveEntry(path: "cp_debug.bin.lz4", size: 4, dataOffset: 1024)
            ]
        )
        let pitEntries = [
            makePitEntry(partitionName: "md1img", flashFilename: "md1img.img")
        ]

        let report = FirmwareMapper.validate(archives: [archive], pitEntries: pitEntries)

        #expect(report.mappings.count == 1)
        #expect(report.mappings.first?.partition.partitionName == "md1img")
        #expect(!report.warnings.contains { $0.contains("CP : aucune entree") })
    }

    @Test func warnsWhenCscAndHomeCscAreBothSelected() throws {
        let url = URL(fileURLWithPath: "/tmp/CSC.tar.md5")
        let cscArchive = FirmwareArchive(
            slot: .csc,
            url: url,
            entries: [
                FirmwareArchiveEntry(path: "cache.img.lz4", size: 4, dataOffset: 512)
            ]
        )
        let homeCscArchive = FirmwareArchive(
            slot: .homeCSC,
            url: url,
            entries: [
                FirmwareArchiveEntry(path: "cache.img.lz4", size: 4, dataOffset: 512)
            ]
        )
        let pitEntries = [
            makePitEntry(partitionName: "cache", flashFilename: "cache.img")
        ]

        let report = FirmwareMapper.validate(archives: [cscArchive, homeCscArchive], pitEntries: pitEntries)

        #expect(report.mappings.count == 1)
        #expect(report.warnings.contains { $0.contains("CSC et HOME_CSC") })
        #expect(report.warnings.contains { $0.contains("meme archive") })
    }

    @Test func warnsWhenMultipleImagesTargetSamePartition() throws {
        let blArchive = FirmwareArchive(
            slot: .bl,
            url: URL(fileURLWithPath: "/tmp/BL.tar.md5"),
            entries: [
                FirmwareArchiveEntry(path: "vbmeta.img.lz4", size: 4, dataOffset: 512)
            ]
        )
        let apArchive = FirmwareArchive(
            slot: .ap,
            url: URL(fileURLWithPath: "/tmp/AP.tar.md5"),
            entries: [
                FirmwareArchiveEntry(path: "vbmeta.img.lz4", size: 4, dataOffset: 512)
            ]
        )
        let pitEntries = [
            makePitEntry(partitionName: "vbmeta", flashFilename: "vbmeta.img")
        ]

        let report = FirmwareMapper.validate(archives: [blArchive, apArchive], pitEntries: pitEntries)

        #expect(report.mappings.count == 2)
        #expect(report.warnings.contains { $0.contains("vbmeta : plusieurs images") })
    }

    @Test func extractsSamsungFirmwareModelCodesFromOfficialNames() {
        #expect(FirmwareCompatibilityValidator.firmwareModelCode(from: "AP_A536BXXS6CWD4_A536BXXS6CWD4.tar.md5") == "A536B")
        #expect(FirmwareCompatibilityValidator.firmwareModelCode(from: "HOME_CSC_OXM_A536BOXM6CWD4.tar.md5") == "A536B")
        #expect(FirmwareCompatibilityValidator.firmwareModelCode(from: "BL_G991U1UES5DWB1.tar.md5") == "G991U1")
        #expect(FirmwareCompatibilityValidator.firmwareModelCode(from: "AP_X200XXU3CWE1.tar.md5") == "X200")
    }

    @Test func extractsSamsungFirmwareBootloaderRevisionFromOfficialNames() {
        #expect(FirmwareCompatibilityValidator.firmwareBootloaderRevision(from: "AP_A226BXXU1AUEE_CL21675614.tar.md5") == 1)
        #expect(FirmwareCompatibilityValidator.firmwareBootloaderRevision(from: "HOME_CSC_OMC_OXM_A226BOXM1AUF2.tar.md5") == 1)
        #expect(FirmwareCompatibilityValidator.firmwareBootloaderRevision(from: "BL_G991U1UES5DWB1.tar.md5") == 5)
        #expect(FirmwareCompatibilityValidator.firmwareBootloaderRevision(from: "AP_A536BXXSACWD4.tar.md5") == 10)
    }

    @Test func blocksFirmwareArchivesFromDifferentModels() {
        let blArchive = FirmwareArchive(
            slot: .bl,
            url: URL(fileURLWithPath: "/tmp/BL_A536BXXS6CWD4.tar.md5"),
            entries: []
        )
        let apArchive = FirmwareArchive(
            slot: .ap,
            url: URL(fileURLWithPath: "/tmp/AP_A536EXXS6CWD4.tar.md5"),
            entries: []
        )

        let report = FirmwareCompatibilityValidator.validate(
            archives: [blArchive, apArchive],
            expectedDeviceModelInput: nil,
            detectedDeviceModelCode: nil
        )

        #expect(report.firmwareModelCodes == ["A536B", "A536E"])
        #expect(report.errors.contains { $0.contains("archives de modèles différents") })
    }

    @Test func blocksFirmwareWhenExpectedModelDiffers() {
        let archive = FirmwareArchive(
            slot: .ap,
            url: URL(fileURLWithPath: "/tmp/AP_A536BXXS6CWD4.tar.md5"),
            entries: []
        )

        let report = FirmwareCompatibilityValidator.validate(
            archives: [archive],
            expectedDeviceModelInput: "SM-A536E",
            detectedDeviceModelCode: nil
        )

        #expect(report.firmwareModelCodes == ["A536B"])
        #expect(report.expectedDeviceModelCode == "A536E")
        #expect(report.errors.contains { $0.contains("différent du modèle attendu A536E") })
    }

    @Test func blocksFirmwareWhenBootloaderDowngradeIsDetected() {
        let archive = FirmwareArchive(
            slot: .ap,
            url: URL(fileURLWithPath: "/tmp/AP_A226BXXU1AUEE_CL21675614.tar.md5"),
            entries: []
        )

        let report = FirmwareCompatibilityValidator.validate(
            archives: [archive],
            expectedDeviceModelInput: "SM-A226B",
            detectedDeviceModelCode: nil,
            currentBootloaderRevisionInput: "2"
        )

        #expect(report.firmwareModelCodes == ["A226B"])
        #expect(report.firmwareBootloaderRevisions == [1])
        #expect(report.currentBootloaderRevision == 2)
        #expect(report.errors.contains { $0.contains("downgrade bootloader impossible") })
    }

    @Test func describesBootloaderRejectResponse() {
        let error = OdinProtocolError.unexpectedResponseType(
            context: "Fin sequence boot",
            expected: OdinProtocol.ControlType.fileTransfer.rawValue,
            actual: UInt32.max
        )

        #expect(error.errorDescription?.contains("bootloader a refusé") == true)
    }

    private func makePitData() -> Data {
        var data = Data(repeating: 0, count: 160)
        writeUInt32(0x12349876, to: &data, at: 0)
        writeUInt32(1, to: &data, at: 4)
        writeUInt32(10, to: &data, at: 8)
        writeUInt32(20, to: &data, at: 12)
        writeUInt16(30, to: &data, at: 16)
        writeUInt16(40, to: &data, at: 18)
        writeUInt16(50, to: &data, at: 20)
        writeUInt16(60, to: &data, at: 22)
        writeUInt16(70, to: &data, at: 24)
        writeUInt16(80, to: &data, at: 26)

        let entryOffset = 28
        writeUInt32(0, to: &data, at: entryOffset)
        writeUInt32(2, to: &data, at: entryOffset + 4)
        writeUInt32(7, to: &data, at: entryOffset + 8)
        writeUInt32(1, to: &data, at: entryOffset + 12)
        writeUInt32(2, to: &data, at: entryOffset + 16)
        writeUInt32(4096, to: &data, at: entryOffset + 20)
        writeUInt32(128, to: &data, at: entryOffset + 24)
        writeUInt32(0, to: &data, at: entryOffset + 28)
        writeUInt32(0, to: &data, at: entryOffset + 32)
        writeCString("BOOT", to: &data, at: entryOffset + 36, length: 32)
        writeCString("boot.img", to: &data, at: entryOffset + 68, length: 32)
        writeCString("boot.fota", to: &data, at: entryOffset + 100, length: 32)
        return data
    }

    private func makePitEntry(partitionName: String, flashFilename: String = "", identifier: UInt32 = 1) -> PitEntry {
        PitEntry(
            binaryType: 0,
            deviceType: 2,
            identifier: identifier,
            attributes: 0,
            updateAttributes: 0,
            blockSizeOrOffset: 0,
            blockCount: 1,
            fileOffset: 0,
            fileSize: 0,
            partitionName: partitionName,
            flashFilename: flashFilename,
            fotaFilename: ""
        )
    }

    private func writeUInt16(_ value: UInt16, to data: inout Data, at offset: Int) {
        var littleEndian = value.littleEndian
        withUnsafeBytes(of: &littleEndian) { buffer in
            data.replaceSubrange(offset..<offset + 2, with: buffer)
        }
    }

    private func writeUInt32(_ value: UInt32, to data: inout Data, at offset: Int) {
        var littleEndian = value.littleEndian
        withUnsafeBytes(of: &littleEndian) { buffer in
            data.replaceSubrange(offset..<offset + 4, with: buffer)
        }
    }

    private func writeCString(_ value: String, to data: inout Data, at offset: Int, length: Int) {
        let bytes = Array(value.utf8.prefix(length - 1))
        data.replaceSubrange(offset..<offset + bytes.count, with: bytes)
    }

    private func makeTemporaryTar(entries: [(String, Data)]) throws -> URL {
        var data = Data()
        for entry in entries {
            data.append(makeTarHeader(name: entry.0, size: UInt64(entry.1.count)))
            data.append(entry.1)
            let padding = (512 - entry.1.count % 512) % 512
            data.append(Data(repeating: 0, count: padding))
        }
        data.append(Data(repeating: 0, count: 1024))
        data.append(Data("0123456789abcdef0123456789abcdef".utf8))

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("tar.md5")
        try data.write(to: url)
        return url
    }

    private func makeTemporaryDataFile(_ data: Data, extension pathExtension: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(pathExtension)
        try data.write(to: url)
        return url
    }

    private func makeLZ4Frame(block: Data, isUncompressed: Bool) -> Data {
        var data = Data([
            0x04, 0x22, 0x4D, 0x18,
            0x60,
            0x40,
            0x00
        ])
        var blockSize = UInt32(block.count)
        if isUncompressed {
            blockSize |= 0x8000_0000
        }
        appendUInt32(blockSize, to: &data)
        data.append(block)
        appendUInt32(0, to: &data)
        return data
    }

    private func appendUInt32(_ value: UInt32, to data: inout Data) {
        var littleEndian = value.littleEndian
        withUnsafeBytes(of: &littleEndian) { buffer in
            data.append(contentsOf: buffer)
        }
    }

    private func makeTarHeader(name: String, size: UInt64) -> Data {
        var header = Data(repeating: 0, count: 512)
        writeASCII(name, to: &header, at: 0, length: 100)
        writeASCII("0000644", to: &header, at: 100, length: 8)
        writeASCII("0000000", to: &header, at: 108, length: 8)
        writeASCII("0000000", to: &header, at: 116, length: 8)
        writeASCII(String(size, radix: 8), to: &header, at: 124, length: 12)
        writeASCII("00000000000", to: &header, at: 136, length: 12)
        header.replaceSubrange(148..<156, with: Data(repeating: UInt8(ascii: " "), count: 8))
        header[156] = UInt8(ascii: "0")
        writeASCII("ustar", to: &header, at: 257, length: 6)
        writeASCII("00", to: &header, at: 263, length: 2)

        let checksum = header.reduce(0) { $0 + UInt32($1) }
        writeASCII(String(checksum, radix: 8), to: &header, at: 148, length: 6)
        header[154] = 0
        header[155] = UInt8(ascii: " ")
        return header
    }

    private func writeASCII(_ value: String, to data: inout Data, at offset: Int, length: Int) {
        let bytes = Array(value.utf8.prefix(length))
        data.replaceSubrange(offset..<offset + bytes.count, with: bytes)
    }
}
