import Foundation
import Darwin
import IOUSBHost
import IOKit
import IOKit.usb

/// Erreurs de communication USB.
enum USBError: Error, LocalizedError {
    case deviceNotFound
    case interfaceOpenFailed(String)
    case pipeNotFound(String)
    case transportNotImplemented
    case transferFailed(String)

    var errorDescription: String? {
        switch self {
        case .deviceNotFound:
            return "Aucun terminal Samsung en mode Download n'a été trouvé."
        case .interfaceOpenFailed(let reason):
            return "Impossible d'ouvrir l'interface USB du terminal : \(reason)"
        case .pipeNotFound(let details):
            return "Pipes USB bulk IN/OUT introuvables.\n\(details)"
        case .transportNotImplemented:
            return "Le transport USB bulk natif n'est pas encore implemente."
        case .transferFailed(let reason):
            return "Transfert USB échoué : \(reason)"
        }
    }
}

/// Enveloppe autour d'IOUSBHost pour dialoguer avec un terminal Samsung
/// en mode Download.
///
/// Remarque d'implementation : IOUSBHostDevice / IOUSBHostInterface
/// necessitent l'entitlement com.apple.security.device.usb-transport ou une
/// application non-sandboxee signee avec les droits requis. La resolution
/// exacte des pipes bulk IN/OUT doit se faire en enumerant les endpoints de
/// l'interface active au runtime, la valeur pipeRef ci-dessous est un
/// espace réservé à compléter lors des tests sur matériel réel.
final class USBDevice {

    private(set) var isConnected = false
    let vendorID: UInt16
    let productID: UInt16
    let locationID: UInt32?
    let serialNumber: String?
    private(set) var transportNotes: [String] = []

    private let service: io_service_t
    private var queue: DispatchQueue?
    private var hostDevice: IOUSBHostDevice?
    private var hostInterface: IOUSBHostInterface?
    private var inputPipe: IOUSBHostPipe?
    private var outputPipe: IOUSBHostPipe?
    private var serialConnection: SerialConnection?
    private let transferTimeout: TimeInterval = 10

    var transportDescription: String {
        if let serialConnection {
            if let configuredBaudRate = serialConnection.configuredBaudRate {
                return "port série USB \(serialConnection.path) @ \(configuredBaudRate) bps"
            }
            return "port série USB \(serialConnection.path)"
        }
        if isConnected {
            return "IOUSBHost bulk"
        }
        return "aucun transport ouvert"
    }

    var supportsUSBZeroLengthPackets: Bool {
        serialConnection == nil && outputPipe != nil
    }

    var displayName: String {
        let product = String(format: "0x%04X", productID)
        if let serialNumber, !serialNumber.isEmpty {
            return "Samsung Download Mode (\(product), \(serialNumber))"
        }
        return "Samsung Download Mode (\(product))"
    }

    private init(
        service: io_service_t,
        vendorID: UInt16,
        productID: UInt16,
        locationID: UInt32?,
        serialNumber: String?
    ) {
        self.service = service
        self.vendorID = vendorID
        self.productID = productID
        self.locationID = locationID
        self.serialNumber = serialNumber
    }

    deinit {
        IOObjectRelease(service)
    }

    /// Recherche un terminal Samsung en mode Download parmi les
    /// périphériques USB actuellement connectés.
    static func findDownloadModeDevice() -> USBDevice? {
        guard let matching = IOServiceMatching("IOUSBHostDevice") else {
            return nil
        }

        var iterator: io_iterator_t = 0
        let result = IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator)
        guard result == KERN_SUCCESS else {
            return nil
        }
        defer { IOObjectRelease(iterator) }

        while true {
            let service = IOIteratorNext(iterator)
            guard service != 0 else { break }

            guard
                let vendorID: UInt16 = registryInteger(service, key: "idVendor"),
                let productID: UInt16 = registryInteger(service, key: "idProduct")
            else {
                IOObjectRelease(service)
                continue
            }

            let isSamsungDownloadMode =
                vendorID == OdinProtocol.samsungVendorID &&
                OdinProtocol.knownProductIDs.contains(productID)

            guard isSamsungDownloadMode else {
                IOObjectRelease(service)
                continue
            }

            return USBDevice(
                service: service,
                vendorID: vendorID,
                productID: productID,
                locationID: registryInteger(service, key: "locationID"),
                serialNumber: registryString(service, key: "USB Serial Number") ?? registryString(service, key: "iSerialNumber")
            )
        }

        return nil
    }

    /// Ouvre l'interface et resout les pipes bulk IN/OUT.
    func open() throws {
        if isConnected {
            return
        }

        transportNotes.removeAll()
        let usbQueue = DispatchQueue(
            label: "AndroidFLASH.USBDevice.\(String(format: "%04X", productID))",
            qos: .userInitiated
        )
        queue = usbQueue

        let interfaceServices = Self.childServices(conformingTo: "IOUSBHostInterface", under: service)
        var diagnostics: [String] = [
            "Diagnostic USB pour \(displayName) :",
            Self.diagnosticLine(for: service, title: "Device")
        ]
        defer {
            for interfaceService in interfaceServices {
                IOObjectRelease(interfaceService)
            }
        }

        if tryOpenBulkInterface(
            interfaceServices: interfaceServices,
            queue: usbQueue,
            diagnostics: &diagnostics,
            initOptions: [],
            diagnosticPrefix: nil
        ) {
            return
        }

        do {
            diagnostics.append("  Tentative capture USB bulk native : deviceCapture.")
            hostDevice = try IOUSBHostDevice(
                __ioService: service,
                options: .deviceCapture,
                queue: usbQueue,
                interestHandler: nil
            )
            diagnostics.append("  Capture IOUSBHostDevice réussie.")

            if tryOpenBulkInterface(
                interfaceServices: interfaceServices,
                queue: usbQueue,
                diagnostics: &diagnostics,
                initOptions: [],
                diagnosticPrefix: "après capture"
            ) {
                return
            }

            transportNotes.append("USB bulk natif capturé, mais aucune pipe bulk IN/OUT utilisable : fallback série.")
            hostDevice?.destroy(options: .deviceSurrender)
            hostDevice = nil
            Thread.sleep(forTimeInterval: 0.5)
        } catch {
            hostDevice = nil
            transportNotes.append("USB bulk natif indisponible : \(Self.shortErrorDescription(error)). Fallback série utilisé.")
            diagnostics.append("  Capture USB bulk native refusée : \(error)")
        }

        let serialPaths = Self.serialCalloutPaths(under: service)
        diagnostics.append("  Ports série candidats : \(serialPaths.isEmpty ? "aucun" : serialPaths.joined(separator: ", "))")

        for serialPath in serialPaths {
            do {
                serialConnection = try SerialConnection(path: serialPath, timeout: transferTimeout)
                isConnected = true
                return
            } catch {
                diagnostics.append("  Ouverture \(serialPath) impossible : \(error)")
            }
        }

        queue = nil
        if interfaceServices.isEmpty {
            diagnostics.append(contentsOf: Self.childDiagnosticLines(under: service))
            throw USBError.interfaceOpenFailed("aucune interface IOUSBHostInterface trouvée.\n\(diagnostics.joined(separator: "\n"))")
        } else {
            throw USBError.pipeNotFound(diagnostics.joined(separator: "\n"))
        }
    }

    func close() {
        inputPipe = nil
        outputPipe = nil
        serialConnection?.close()
        serialConnection = nil
        hostInterface?.destroy(options: [])
        hostInterface = nil
        hostDevice?.destroy(options: .deviceSurrender)
        hostDevice = nil
        queue = nil
        isConnected = false
    }

    func discardPendingData() throws {
        if let serialConnection {
            try serialConnection.discardPendingData()
        }
    }

    /// Envoie des données brutes sur le pipe bulk OUT.
    func send(_ data: Data) throws {
        guard isConnected else { throw USBError.deviceNotFound }
        if let serialConnection {
            try serialConnection.send(data)
            return
        }

        guard let outputPipe else { throw USBError.pipeNotFound("Aucun pipe OUT n'est ouvert.") }

        let buffer = data.isEmpty ? nil : NSMutableData(data: data)
        let bytesTransferred = try performTransfer(on: outputPipe, buffer: buffer)
        guard bytesTransferred == data.count else {
            throw USBError.transferFailed("Écriture incomplète : \(bytesTransferred)/\(data.count) octets.")
        }
    }

    /// Reçoit des données depuis le pipe bulk IN, taille maximale attendue.
    func receive(maxLength: Int, timeout: TimeInterval? = nil) throws -> Data {
        guard isConnected else { throw USBError.deviceNotFound }
        if let serialConnection {
            return try serialConnection.receive(maxLength: maxLength, timeout: timeout)
        }

        guard let inputPipe else { throw USBError.pipeNotFound("Aucun pipe IN n'est ouvert.") }
        guard maxLength > 0 else { return Data() }

        guard let buffer = NSMutableData(length: maxLength) else {
            throw USBError.transferFailed("Allocation du buffer de réception impossible.")
        }

        let bytesTransferred = try performTransfer(on: inputPipe, buffer: buffer, timeout: timeout ?? transferTimeout)
        return Data(bytes: buffer.bytes, count: bytesTransferred)
    }

    private func performTransfer(on pipe: IOUSBHostPipe, buffer: NSMutableData?, timeout: TimeInterval? = nil) throws -> Int {
        let semaphore = DispatchSemaphore(value: 0)
        let completion = TransferCompletion()
        let effectiveTimeout = timeout ?? transferTimeout
        var enqueueError: Error?

        for attempt in 0..<3 {
            do {
                try pipe.enqueueIORequest(with: buffer, completionTimeout: effectiveTimeout) { status, bytesTransferred in
                    if status == kIOReturnSuccess {
                        completion.set(.success(bytesTransferred))
                    } else {
                        completion.set(.failure(.transferFailed("IOReturn \(Self.describeIOReturn(status)).")))
                    }
                    semaphore.signal()
                }
                enqueueError = nil
                break
            } catch {
                enqueueError = error
                if attempt < 2 {
                    Thread.sleep(forTimeInterval: 0.12 * Double(attempt + 1))
                }
            }
        }

        if let enqueueError {
            throw USBError.transferFailed(String(describing: enqueueError))
        }

        let waitResult = semaphore.wait(timeout: .now() + effectiveTimeout + 1)
        guard waitResult == .success else {
            throw USBError.transferFailed("Delai d'attente USB depasse.")
        }

        switch completion.value {
        case .success(let bytesTransferred):
            return bytesTransferred
        case .failure(let error):
            throw error
        case .none:
            throw USBError.transferFailed("Aucun resultat de transfert USB.")
        }
    }

    private func tryOpenBulkInterface(
        interfaceServices: [io_service_t],
        queue usbQueue: DispatchQueue,
        diagnostics: inout [String],
        initOptions: IOUSBHostObjectInitOptions,
        diagnosticPrefix: String?
    ) -> Bool {
        for (index, interfaceService) in interfaceServices.enumerated() {
            let titleSuffix = diagnosticPrefix.map { " \($0)" } ?? ""
            diagnostics.append(Self.diagnosticLine(for: interfaceService, title: "Interface \(index + 1)\(titleSuffix)"))
            diagnostics.append(contentsOf: Self.childDiagnosticLines(under: interfaceService))

            let candidateInterface: IOUSBHostInterface
            do {
                candidateInterface = try IOUSBHostInterface(
                    __ioService: interfaceService,
                    options: initOptions,
                    queue: usbQueue,
                    interestHandler: nil
                )
            } catch {
                diagnostics.append("  Ouverture IOUSBHostInterface\(titleSuffix) impossible : \(error)")
                continue
            }

            try? candidateInterface.selectAlternateSetting(0)

            let outPipes = Self.availablePipes(on: candidateInterface, addresses: 0x01...0x0F)
            let inPipes = Self.availablePipes(on: candidateInterface, addresses: 0x81...0x8F)
            diagnostics.append("  Pipes OUT visibles\(titleSuffix) : \(Self.describePipeAddresses(outPipes.map(\.address)))")
            diagnostics.append("  Pipes IN visibles\(titleSuffix) : \(Self.describePipeAddresses(inPipes.map(\.address)))")

            guard let outPipe = outPipes.first?.pipe, let inPipe = inPipes.first?.pipe else {
                candidateInterface.destroy(options: [])
                continue
            }

            hostInterface = candidateInterface
            outputPipe = outPipe
            inputPipe = inPipe
            isConnected = true
            return true
        }

        return false
    }

    private static func registryInteger<T: FixedWidthInteger>(_ service: io_service_t, key: String) -> T? {
        guard let value = IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() else {
            return nil
        }

        if let number = value as? NSNumber {
            return T(truncatingIfNeeded: number.uint64Value)
        }

        if let data = value as? Data {
            return integer(from: data)
        }

        return nil
    }

    private static func registryString(_ service: io_service_t, key: String) -> String? {
        IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? String
    }

    private static func integer<T: FixedWidthInteger>(from data: Data) -> T? {
        guard data.count <= MemoryLayout<T>.size else { return nil }
        var value: UInt64 = 0
        for (index, byte) in data.enumerated() {
            value |= UInt64(byte) << UInt64(index * 8)
        }
        return T(truncatingIfNeeded: value)
    }

    private static func childServices(conformingTo className: String, under service: io_service_t) -> [io_service_t] {
        var iterator: io_iterator_t = 0
        guard IORegistryEntryGetChildIterator(service, kIOServicePlane, &iterator) == KERN_SUCCESS else {
            return []
        }
        defer { IOObjectRelease(iterator) }

        var matches: [io_service_t] = []
        while true {
            let child = IOIteratorNext(iterator)
            guard child != 0 else { break }

            let conforms = className.withCString { IOObjectConformsTo(child, $0) != 0 }
            if conforms {
                matches.append(child)
            } else {
                matches.append(contentsOf: childServices(conformingTo: className, under: child))
                IOObjectRelease(child)
            }
        }

        return matches
    }

    private static func serialCalloutPaths(under service: io_service_t) -> [String] {
        let serialServices = childServices(conformingTo: "IOSerialBSDClient", under: service)
        defer {
            for serialService in serialServices {
                IOObjectRelease(serialService)
            }
        }

        return serialServices.compactMap { serialService in
            registryString(serialService, key: "IOCalloutDevice") ?? registryString(serialService, key: "IODialinDevice")
        }
    }

    private static func availablePipes(on interface: IOUSBHostInterface, addresses: ClosedRange<Int>) -> [(address: Int, pipe: IOUSBHostPipe)] {
        var pipes: [(address: Int, pipe: IOUSBHostPipe)] = []
        for address in addresses {
            if let pipe = try? interface.copyPipe(withAddress: address) {
                pipes.append((address, pipe))
            }
        }
        return pipes
    }

    private static func describePipeAddresses(_ addresses: [Int]) -> String {
        guard !addresses.isEmpty else { return "aucun" }
        return addresses
            .map { String(format: "0x%02X", $0) }
            .joined(separator: ", ")
    }

    private static func diagnosticLine(for service: io_service_t, title: String) -> String {
        let keys = [
            "idVendor",
            "idProduct",
            "locationID",
            "bDeviceClass",
            "bDeviceSubClass",
            "bDeviceProtocol",
            "bNumConfigurations",
            "kUSBCurrentConfiguration",
            "bInterfaceNumber",
            "bAlternateSetting",
            "bInterfaceClass",
            "bInterfaceSubClass",
            "bInterfaceProtocol",
            "bNumEndpoints",
            "bEndpointAddress",
            "bmAttributes",
            "wMaxPacketSize",
            "bInterval",
            "IOCalloutDevice",
            "IODialinDevice",
            "IOTTYDevice",
            "IOProviderClass",
            "USB Product Name",
            "USB Interface Name"
        ]
        let values = keys.compactMap { key -> String? in
            guard let value = registryValueDescription(service, key: key) else { return nil }
            return "\(key)=\(value)"
        }

        return "  \(title): \(objectClassName(service)) \(values.joined(separator: ", "))"
    }

    private static func childDiagnosticLines(under service: io_service_t) -> [String] {
        var iterator: io_iterator_t = 0
        guard IORegistryEntryGetChildIterator(service, kIOServicePlane, &iterator) == KERN_SUCCESS else {
            return []
        }
        defer { IOObjectRelease(iterator) }

        var lines: [String] = []
        while true {
            let child = IOIteratorNext(iterator)
            guard child != 0 else { break }
            defer { IOObjectRelease(child) }

            lines.append(diagnosticLine(for: child, title: "Enfant"))
        }

        return lines
    }

    private static func registryValueDescription(_ service: io_service_t, key: String) -> String? {
        guard let value = IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() else {
            return nil
        }

        if let number = value as? NSNumber {
            return "\(number.uint64Value) (\(String(format: "0x%llX", number.uint64Value)))"
        }

        if let string = value as? String {
            return string
        }

        if let data = value as? Data {
            let bytes = data.prefix(16).map { String(format: "%02X", $0) }.joined(separator: " ")
            let suffix = data.count > 16 ? " ..." : ""
            return "Data[\(data.count)] \(bytes)\(suffix)"
        }

        return String(describing: value)
    }

    private static func objectClassName(_ service: io_service_t) -> String {
        var name = [CChar](repeating: 0, count: 128)
        let result = IOObjectGetClass(service, &name)
        guard result == KERN_SUCCESS else { return "classe inconnue" }
        return String(cString: name)
    }

    private static func describeIOReturn(_ status: IOReturn) -> String {
        String(format: "0x%08X", UInt32(bitPattern: status))
    }

    private static func shortErrorDescription(_ error: Error) -> String {
        if let localizedError = error as? LocalizedError, let description = localizedError.errorDescription {
            return description
        }

        let rawDescription = String(describing: error)
        guard rawDescription.count > 180 else { return rawDescription }
        return "\(rawDescription.prefix(177))..."
    }
}

private final class TransferCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<Int, USBError>?

    var value: Result<Int, USBError>? {
        lock.lock()
        defer { lock.unlock() }
        return result
    }

    func set(_ result: Result<Int, USBError>) {
        lock.lock()
        self.result = result
        lock.unlock()
    }
}

private final class SerialConnection {
    private static let preferredBaudRate: speed_t = 3_000_000
    private static let baseBaudRate: speed_t = speed_t(B115200)
    private static let iosSIOSpeedRequest: UInt = 0x8008_5402

    let path: String
    private(set) var configuredBaudRate: Int?

    private let timeout: TimeInterval
    private var fileDescriptor: Int32
    private var originalAttributes: termios?

    init(path: String, timeout: TimeInterval) throws {
        self.path = path
        self.timeout = timeout
        self.fileDescriptor = Darwin.open(path, O_RDWR | O_NOCTTY | O_NONBLOCK)

        guard fileDescriptor >= 0 else {
            throw USBError.transferFailed("Ouverture du port série \(path) impossible : \(Self.errnoDescription(errno)).")
        }

        do {
            try configureRawMode()
            tcflush(fileDescriptor, TCIOFLUSH)
        } catch {
            Darwin.close(fileDescriptor)
            fileDescriptor = -1
            throw error
        }
    }

    deinit {
        close()
    }

    func close() {
        guard fileDescriptor >= 0 else { return }

        if var originalAttributes {
            tcsetattr(fileDescriptor, TCSANOW, &originalAttributes)
        }

        Darwin.close(fileDescriptor)
        fileDescriptor = -1
    }

    func discardPendingData() throws {
        guard fileDescriptor >= 0 else {
            throw USBError.transferFailed("Port série fermé.")
        }

        guard tcflush(fileDescriptor, TCIOFLUSH) == 0 else {
            throw USBError.transferFailed("Nettoyage du tampon série impossible sur \(path) : \(Self.errnoDescription(errno)).")
        }
    }

    func send(_ data: Data) throws {
        guard fileDescriptor >= 0 else {
            throw USBError.transferFailed("Port série fermé.")
        }
        guard !data.isEmpty else { return }

        try data.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return }

            var bytesWritten = 0
            while bytesWritten < data.count {
                let result = Darwin.write(
                    fileDescriptor,
                    baseAddress.advanced(by: bytesWritten),
                    data.count - bytesWritten
                )

                if result > 0 {
                    bytesWritten += result
                    continue
                }

                if result == -1 && (errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK) {
                    usleep(1_000)
                    continue
                }

                throw USBError.transferFailed("Écriture série échouée sur \(path) : \(Self.errnoDescription(errno)).")
            }
        }
    }

    func receive(maxLength: Int, timeout overrideTimeout: TimeInterval? = nil) throws -> Data {
        guard fileDescriptor >= 0 else {
            throw USBError.transferFailed("Port série fermé.")
        }

        guard maxLength > 0 else {
            return Data()
        }

        let deadline = Date().addingTimeInterval(overrideTimeout ?? timeout)
        var received = Data()
        var buffer = [UInt8](repeating: 0, count: maxLength)

        while received.count < maxLength && Date() < deadline {
            let remainingLength = maxLength - received.count
            let bytesRead = buffer.withUnsafeMutableBytes { mutableBuffer in
                guard let baseAddress = mutableBuffer.baseAddress else { return -1 }
                return Darwin.read(fileDescriptor, baseAddress, remainingLength)
            }

            if bytesRead > 0 {
                received.append(contentsOf: buffer.prefix(bytesRead))
                continue
            }

            if bytesRead == -1 && !(errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK) {
                throw USBError.transferFailed("Lecture série échouée sur \(path) : \(Self.errnoDescription(errno)).")
            }

            usleep(1_000)
        }

        guard !received.isEmpty else {
            throw USBError.transferFailed("Aucune réponse reçue sur \(path) avant expiration du délai.")
        }

        return received
    }

    private func configureRawMode() throws {
        var attributes = termios()
        guard tcgetattr(fileDescriptor, &attributes) == 0 else {
            throw USBError.transferFailed("Lecture des attributs série impossible : \(Self.errnoDescription(errno)).")
        }

        originalAttributes = attributes
        var rawAttributes = attributes
        cfmakeraw(&rawAttributes)
        rawAttributes.c_cflag |= tcflag_t(CLOCAL)
        rawAttributes.c_cflag |= tcflag_t(CREAD)
        cfsetspeed(&rawAttributes, Self.baseBaudRate)

        guard tcsetattr(fileDescriptor, TCSANOW, &rawAttributes) == 0 else {
            throw USBError.transferFailed("Configuration du port série impossible : \(Self.errnoDescription(errno)).")
        }

        applyPreferredBaudRateIfPossible()
    }

    private func applyPreferredBaudRateIfPossible() {
        var requestedSpeed = Self.preferredBaudRate
        guard Darwin.ioctl(fileDescriptor, Self.iosSIOSpeedRequest, &requestedSpeed) == 0 else {
            configuredBaudRate = Int(Self.baseBaudRate)
            return
        }

        configuredBaudRate = Int(requestedSpeed)
    }

    private static func errnoDescription(_ code: Int32) -> String {
        String(cString: strerror(code))
    }
}
