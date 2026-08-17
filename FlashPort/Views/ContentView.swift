import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct ContentView: View {
    @State private var viewModel = FlashViewModel()
    @State private var showsAdvancedSettings = false
    @State private var showsAppInfo = false
    @State private var showsFirmwareInfo = false
    @State private var advancedTab: AdvancedTab = .settings
    @State private var showsPitDetails = false
    @State private var showsFirmwareDetails = true
    @State private var showsManualFirmwareChecks = false
    @State private var interfaceMode: InterfaceMode = .guided
    @State private var isFirmwareDropTargeted = false
    @State private var updateChecker = UpdateChecker()

    private var activeStepColor: Color {
        Color(red: 0.28, green: 0.82, blue: 0.94)
    }

    private var completedStepColor: Color {
        Color(red: 0.22, green: 0.84, blue: 0.42)
    }

    var body: some View {
        @Bindable var viewModel = viewModel

        ZStack {
            Color(red: 0.10, green: 0.12, blue: 0.15)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                topBar

                Spacer(minLength: 26)

                mainFlow(viewModel: viewModel)

                if let heimdallInstallWarningText = viewModel.heimdallInstallWarningText {
                    heimdallInstallWarning(heimdallInstallWarningText)
                        .padding(.horizontal, 72)
                        .padding(.top, 16)
                }

                Spacer(minLength: 22)

                VStack(spacing: 12) {
                    if let flashFailureReason = viewModel.flashFailureReason {
                        flashFailureBanner(
                            reason: flashFailureReason,
                            advice: viewModel.flashFailureAdvice,
                            viewModel: viewModel
                        )
                        .frame(maxWidth: 900)
                    }

                    if let customRecoveryBootNoticeText = viewModel.customRecoveryBootNoticeText {
                        customRecoveryBootNotice(customRecoveryBootNoticeText)
                            .frame(maxWidth: 900)
                    }

                    bottomControlDock(viewModel: viewModel)
                }
                .padding(.horizontal, 72)
                .padding(.bottom, 36)
            }

            if isFirmwareDropTargeted {
                RoundedRectangle(cornerRadius: 18)
                    .strokeBorder(Color(red: 0.28, green: 0.82, blue: 0.94), lineWidth: 3)
                    .background(
                        RoundedRectangle(cornerRadius: 18)
                            .fill(Color(red: 0.28, green: 0.82, blue: 0.94).opacity(0.08))
                    )
                    .padding(10)
                    .allowsHitTesting(false)
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $isFirmwareDropTargeted) { providers in
            handleFirmwareDrop(providers, viewModel: viewModel)
        }
        .frame(minWidth: 980, minHeight: 650)
        .sheet(isPresented: $showsAdvancedSettings) {
            advancedSettingsSheet(viewModel: viewModel)
                .frame(minWidth: 900, minHeight: 650)
        }
        .sheet(isPresented: $showsAppInfo) {
            appInfoSheet
                .frame(width: 560, height: 640)
        }
        .sheet(isPresented: $showsFirmwareInfo) {
            firmwareInfoSheet(viewModel: viewModel)
                .frame(width: 760, height: 640)
        }
        .onAppear {
            viewModel.startAutomaticDeviceDetection()
        }
        .onDisappear {
            viewModel.stopAutomaticDeviceDetection()
        }
        .task {
            await updateChecker.checkForUpdate()
        }
    }

    private var topBar: some View {
        HStack(spacing: 14) {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color(red: 0.08, green: 0.62, blue: 0.76))
                        .frame(width: 34, height: 34)
                    Image(systemName: "iphone")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(.white)
                }

                HStack(spacing: 0) {
                    Text("Flash")
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundStyle(.white)
                    Text("Port")
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundStyle(Color(red: 0.28, green: 0.82, blue: 0.94))
                }

                Text("BETA")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Color.orange.opacity(0.85)))
            }

            Spacer()

            if let updateTag = updateChecker.availableUpdateTag {
                Button {
                    updateChecker.openUpdatePage()
                } label: {
                    Label("Mise à jour disponible (\(updateTag))", systemImage: "arrow.down.circle.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Capsule().fill(Color(red: 0.22, green: 0.84, blue: 0.42)))
                }
                .buttonStyle(.plain)
                .help("Ouvrir la page de téléchargement GitHub")
            }

            Button {
                viewModel.resetForNewFlash()
            } label: {
                Image(systemName: "arrow.counterclockwise.circle")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(.white.opacity(viewModel.canResetSession ? 0.88 : 0.3))
                    .frame(width: 42, height: 42)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!viewModel.canResetSession)
            .help("Réinitialiser pour un nouveau flash")

            Button {
                showsAppInfo = true
            } label: {
                Image(systemName: "info.circle")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.88))
                    .frame(width: 42, height: 42)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Version et historique")

            Button {
                showsAdvancedSettings = true
            } label: {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.88))
                    .frame(width: 42, height: 42)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Paramètres avancés")
        }
        .padding(.horizontal, 28)
        .padding(.top, 24)
    }

    private func mainFlow(viewModel: FlashViewModel) -> some View {
        let firmwareStatus = firmwareStepStatus(viewModel: viewModel)
        let deviceStatus = deviceStepStatus(viewModel: viewModel)
        let flashStatus = flashStepStatus(viewModel: viewModel)

        return HStack(spacing: 10) {
            workflowStep(
                stepNumber: 1,
                tone: .firmware,
                title: "Firmware",
                subtitle: firmwareStepSubtitle(viewModel: viewModel),
                status: firmwareStatus,
                ringProgress: firmwareStepRingProgress(viewModel: viewModel),
                buttonTitle: viewModel.isImportingFirmware ? "Import..." : "Importer firmware",
                buttonIcon: "folder.fill",
                isPrimary: true,
                isEnabled: !viewModel.isImportingFirmware,
                action: selectFirmwareBundle,
                infoAction: {
                    showsFirmwareInfo = true
                },
                clearAction: hasFirmwareBundle(viewModel: viewModel) && !viewModel.isImportingFirmware ? {
                    viewModel.clearFirmwareBundle()
                } : nil
            )

            connectorLine(isComplete: firmwareStatus == .complete, tone: .firmware)

            workflowStep(
                stepNumber: 2,
                tone: .device,
                title: "Téléphone",
                subtitle: deviceStepSubtitle(viewModel: viewModel),
                status: deviceStatus,
                buttonTitle: deviceButtonTitle(viewModel: viewModel),
                buttonIcon: deviceButtonIcon(viewModel: viewModel),
                isPrimary: false,
                isEnabled: deviceButtonEnabled(viewModel: viewModel),
                action: {
                    viewModel.checkDeviceConnection()
                },
                showsSearchingIndicator: shouldShowDeviceSearchIndicator(viewModel: viewModel)
            )

            connectorLine(isComplete: deviceStatus == .complete, tone: .device)

            workflowStep(
                stepNumber: 3,
                tone: .flash,
                title: "Flash",
                subtitle: flashStepSubtitle(viewModel: viewModel),
                status: flashStatus,
                ringProgress: flashStepRingProgress(viewModel.state),
                buttonTitle: flashButtonTitle(viewModel: viewModel),
                buttonIcon: flashButtonIcon(viewModel: viewModel),
                isPrimary: false,
                isEnabled: isFlashStepButtonEnabled(viewModel: viewModel),
                action: {
                    viewModel.startRealFlash()
                }
            )
        }
        .padding(.horizontal, 0)
    }

    private func connectorLine(isComplete: Bool, tone: WorkflowStepTone) -> some View {
        Capsule()
            .fill(isComplete ? Color.white.opacity(0.32) : Color.white.opacity(0.10))
            .frame(width: 44, height: 1.5)
            .padding(.top, 4)
    }

    private func workflowStep(
        stepNumber: Int,
        tone: WorkflowStepTone,
        title: String,
        subtitle: String,
        status: WorkflowStepStatus,
        ringProgress: Double? = nil,
        buttonTitle: String,
        buttonIcon: String,
        isPrimary: Bool,
        isEnabled: Bool,
        action: @escaping () -> Void,
        infoAction: (() -> Void)? = nil,
        showsSearchingIndicator: Bool = false,
        clearAction: (() -> Void)? = nil
    ) -> some View {
        let stepWidth: CGFloat = infoAction == nil ? 214 : 252

        return VStack(spacing: 14) {
            stepRing(stepNumber, tone: tone, status: status, progress: ringProgress, isReady: isEnabled || isPrimary)

            VStack(spacing: 6) {
                Text(title)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white)

                Text(subtitle)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white.opacity(0.64))
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .frame(width: 190)
                    .frame(minHeight: 34)

                statusBadge(status, tone: tone)
            }

            HStack(spacing: 8) {
                if showsSearchingIndicator {
                    deviceSearchIndicator
                        .frame(width: 198, height: 46)
                } else {
                    Button(action: action) {
                        Label(buttonTitle, systemImage: buttonIcon)
                            .font(.system(size: 15, weight: .semibold))
                            .lineLimit(1)
                            .minimumScaleFactor(0.86)
                            .frame(width: 198, height: 46)
                    }
                    .buttonStyle(FlashActionButtonStyle(isPrimary: isPrimary, isEnabled: isEnabled))
                    .disabled(!isEnabled)
                }

                if let infoAction {
                    Button(action: infoAction) {
                        Image(systemName: "info.circle")
                            .font(.system(size: 17, weight: .semibold))
                            .frame(width: 42, height: 46)
                    }
                    .buttonStyle(FlashActionButtonStyle(isPrimary: false))
                    .help("Infos firmware")
                }
            }
        }
        .frame(width: stepWidth)
        .padding(.horizontal, 4)
        .padding(.vertical, 18)
        .overlay(alignment: .topTrailing) {
            if let clearAction {
                Button(action: clearAction) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(.white.opacity(0.62))
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(6)
                .help("Retirer le firmware")
            }
        }
    }

    private var deviceSearchIndicator: some View {
        HStack(spacing: 10) {
            ProgressView()
                .controlSize(.small)
                .tint(Color(red: 0.28, green: 0.82, blue: 0.94))

            VStack(alignment: .leading, spacing: 1) {
                Text("Recherche...")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.86))
                Text("Download Mode")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.50))
            }
        }
        .frame(maxWidth: .infinity)
        .background(Color.white.opacity(0.075))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.white.opacity(0.12), lineWidth: 1)
        )
        .help("Recherche automatique d'un téléphone Samsung en mode Download")
    }

    private func stepRing(_ number: Int, tone: WorkflowStepTone, status: WorkflowStepStatus, progress: Double?, isReady: Bool) -> some View {
        let normalizedProgress = progress.map { min(max($0, 0), 1) }
        let ringValue = normalizedProgress ?? stepRingStatusProgress(status)
        let ringColor = stepRingColor(status: status, tone: tone, isReady: isReady)
        let contentColor = stepRingContentColor(status: status, tone: tone, isReady: isReady)

        return ZStack {
            Circle()
                .fill(Color.white.opacity(0.035))
                .frame(width: 58, height: 58)

            Circle()
                .stroke(Color.white.opacity(0.12), lineWidth: 2)
                .frame(width: 70, height: 70)

            if let ringValue {
                Circle()
                    .trim(from: 0, to: ringValue)
                    .stroke(ringColor, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .frame(width: 70, height: 70)
            }

            stepRingContent(number: number, status: status, progress: normalizedProgress, color: contentColor)
        }
        .frame(width: 72, height: 72)
        .shadow(color: ringColor.opacity(status == .pending ? 0 : 0.10), radius: 10, x: 0, y: 4)
    }

    @ViewBuilder
    private func stepRingContent(number: Int, status: WorkflowStepStatus, progress: Double?, color: Color) -> some View {
        switch status {
        case .active:
            if let progress {
                Text("\(Int((progress * 100).rounded()))%")
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(color)
            } else {
                ProgressView()
                    .controlSize(.small)
                    .tint(color)
            }
        case .complete:
            Text("OK")
                .font(.system(size: 14, weight: .bold, design: .rounded))
                .foregroundStyle(color)
        case .warning:
            Text("!")
                .font(.system(size: 20, weight: .bold, design: .rounded))
                .foregroundStyle(color)
        case .error:
            Image(systemName: "xmark")
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(color)
        case .ready, .pending:
            Text(String(format: "%02d", number))
                .font(.system(size: 18, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(color)
        }
    }

    private func statusBadge(_ status: WorkflowStepStatus, tone: WorkflowStepTone) -> some View {
        HStack(spacing: 5) {
            Circle()
                .fill(statusBadgeColor(status: status, tone: tone))
                .frame(width: 5, height: 5)
            Text(status.title)
                .font(.system(size: 11, weight: .semibold))
        }
        .foregroundStyle(statusBadgeColor(status: status, tone: tone))
        .frame(height: 18)
    }

    private func bottomControlDock(viewModel: FlashViewModel) -> some View {
        VStack(spacing: 8) {
            HStack(alignment: .center, spacing: 20) {
                dataModeControl(viewModel: viewModel)
                controlDivider
                sessionControl(viewModel: viewModel)
            }
            .frame(maxWidth: .infinity)

            progressPanel(viewModel: viewModel)
                .frame(maxWidth: .infinity)
        }
        .padding(.horizontal, 18)
        .frame(maxWidth: 900)
        .frame(maxWidth: .infinity)
    }

    private var controlDivider: some View {
        Rectangle()
            .fill(Color.white.opacity(0.08))
            .frame(width: 1, height: 22)
    }

    private func dataModeControl(viewModel: FlashViewModel) -> some View {
        HStack(spacing: 12) {
            Label("Données", systemImage: "externaldrive")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white.opacity(0.66))
                .frame(width: 78, alignment: .leading)

            HStack(spacing: 3) {
                ForEach(FirmwareDataMode.allCases) { mode in
                    dataModeButton(mode, viewModel: viewModel)
                }
            }
            .padding(3)
            .background(
                Capsule()
                    .fill(Color.white.opacity(0.10))
            )
            .overlay(
                Capsule()
                    .stroke(Color.white.opacity(0.040), lineWidth: 1)
            )
        }
        .frame(width: 388, height: 36)
    }

    private func dataModeButton(_ mode: FirmwareDataMode, viewModel: FlashViewModel) -> some View {
        let isSelected = viewModel.firmwareDataMode == mode

        return Button {
            viewModel.setFirmwareDataMode(mode)
        } label: {
            Text(mode.title)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.88)
                .frame(width: mode == .erase ? 124 : 140, height: 30)
        }
        .buttonStyle(.plain)
        .foregroundStyle(dataModeTextColor(mode, isSelected: isSelected))
        .background(dataModeSelectionBackground(mode, isSelected: isSelected))
        .clipShape(Capsule())
        .shadow(
            color: dataModeSelectedColor(mode).opacity(isSelected ? 0.22 : 0),
            radius: 8,
            x: 0,
            y: 3
        )
        .help(dataModeHelp(mode))
    }

    private func dataModeHelp(_ mode: FirmwareDataMode) -> String {
        switch mode {
        case .erase:
            return "Flash avec effacement volontaire des données utilisateur via userdata/CSC."
        case .preserve:
            return "N'efface pas volontairement userdata et utilise HOME_CSC. Android peut quand même demander un reset si les anciennes données ne montent plus."
        }
    }

    private func sessionControl(viewModel: FlashViewModel) -> some View {
        HStack(spacing: 8) {
            rebootAfterFlashButton(viewModel: viewModel)
            exitDownloadButton(viewModel: viewModel)
        }
        .frame(width: 368, height: 36)
    }

    private func rebootAfterFlashButton(viewModel: FlashViewModel) -> some View {
        let isEnabled = viewModel.canEnableRebootAfterFlash
        let isSelected = viewModel.rebootAfterFlash

        return Button {
            viewModel.setRebootAfterFlash(!viewModel.rebootAfterFlash)
        } label: {
            Label(
                "Redémarrer après flash",
                systemImage: isSelected ? "checkmark.circle.fill" : "circle"
            )
            .font(.system(size: 12, weight: .semibold))
            .lineLimit(1)
            .minimumScaleFactor(0.88)
            .frame(width: 196, height: 30)
        }
        .buttonStyle(.plain)
        .foregroundStyle(bottomToggleForeground(isEnabled: isEnabled, isSelected: isSelected))
        .background(bottomToggleBackground(isEnabled: isEnabled, isSelected: isSelected))
        .clipShape(Capsule())
        .overlay(
            Capsule()
                .stroke(bottomToggleBorder(isEnabled: isEnabled, isSelected: isSelected), lineWidth: 1)
        )
        .disabled(!isEnabled)
        .help(isEnabled ? "Redémarre automatiquement le téléphone après le flash" : "Désactivé pour TWRP : il faut démarrer directement en recovery")
    }

    private func exitDownloadButton(viewModel: FlashViewModel) -> some View {
        Button {
            viewModel.exitDownloadMode()
        } label: {
            Label(exitDownloadButtonTitle(viewModel: viewModel), systemImage: "power")
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.88)
                .frame(width: 148, height: 30)
        }
        .buttonStyle(.plain)
        .foregroundStyle(viewModel.canExitDownloadMode ? .white.opacity(0.82) : .white.opacity(0.34))
        .background(
            Capsule()
                .fill(Color.white.opacity(viewModel.canExitDownloadMode ? 0.10 : 0.045))
        )
        .overlay(
            Capsule()
                .stroke(Color.white.opacity(viewModel.canExitDownloadMode ? 0.08 : 0.045), lineWidth: 1)
        )
        .disabled(!viewModel.canExitDownloadMode)
        .help(exitDownloadHelp(viewModel: viewModel))
    }

    private func progressPanel(viewModel: FlashViewModel) -> some View {
        let value = progressValue(viewModel: viewModel)
        let tint = progressTint(viewModel: viewModel)

        return VStack(spacing: 5) {
            HStack(spacing: 8) {
                Circle()
                    .fill(progressStatusDotColor(viewModel: viewModel))
                    .frame(width: 6, height: 6)
                    .shadow(color: progressStatusDotColor(viewModel: viewModel).opacity(0.40), radius: 5)

                Text(stageText(viewModel: viewModel))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(stageColor(viewModel: viewModel))
                    .lineLimit(1)
                    .truncationMode(.tail)

                Spacer()

                if let trailingText = progressTrailingText(viewModel: viewModel) {
                    Text(trailingText)
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(stageColor(viewModel: viewModel).opacity(0.92))
                        .monospacedDigit()
                }
            }

            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.white.opacity(0.10))

                    if value > 0 {
                        Capsule()
                            .fill(
                                LinearGradient(
                                    colors: [
                                        tint.opacity(0.78),
                                        tint
                                    ],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                            )
                            .frame(width: min(proxy.size.width, max(8, proxy.size.width * value)))
                            .shadow(color: tint.opacity(0.20), radius: 6, x: 0, y: 0)
                    }
                }
            }
            .frame(height: 4)
        }
        .frame(height: 25)
    }

    private func flashFailureBanner(reason: String, advice: String?, viewModel: FlashViewModel) -> some View {
        let accent = Color(red: 1.0, green: 0.36, blue: 0.36)
        let cleanedAdvice = advice.map { $0.replacingOccurrences(of: "Diagnostic : ", with: "") }

        return HStack(alignment: .top, spacing: 0) {
            Rectangle()
                .fill(accent)
                .frame(width: 4)

            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "xmark.octagon.fill")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(accent)
                    .padding(.top, 1)

                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Text("Flash échoué")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.white)

                        Spacer(minLength: 0)

                        Button {
                            copyFailureReport(reason: reason, advice: advice)
                        } label: {
                            Label("Copier", systemImage: "doc.on.doc")
                                .font(.system(size: 11, weight: .semibold))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.white.opacity(0.7))

                        Button {
                            viewModel.resetForNewFlash()
                        } label: {
                            Label("Réinitialiser", systemImage: "arrow.counterclockwise")
                                .font(.system(size: 11, weight: .semibold))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(accent)
                    }

                    Text(reason)
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.82))
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)

                    if let cleanedAdvice {
                        HStack(alignment: .top, spacing: 6) {
                            Image(systemName: "lightbulb.fill")
                                .font(.system(size: 11))
                                .foregroundStyle(Color(red: 1.0, green: 0.80, blue: 0.35))
                                .padding(.top, 1)

                            Text(cleanedAdvice)
                                .font(.caption)
                                .foregroundStyle(.white.opacity(0.66))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            .padding(12)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(red: 0.20, green: 0.06, blue: 0.07).opacity(0.55))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(accent.opacity(0.45), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private func copyFailureReport(reason: String, advice: String?) {
        var text = "FlashPort — échec de flash\n\(reason)"
        if let advice {
            text += "\n\(advice)"
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func heimdallInstallWarning(_ message: String) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.orange)

            VStack(alignment: .leading, spacing: 3) {
                Text("Heimdall non détecté")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)

                Text(message)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.70))
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 16)

            Button {
                advancedTab = .settings
                showsAdvancedSettings = true
            } label: {
                Label("Paramètres", systemImage: "slider.horizontal.3")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 112, height: 32)
            }
            .buttonStyle(FlashActionButtonStyle(isPrimary: false))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.11))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.orange.opacity(0.24), lineWidth: 1)
        )
    }

    private func customRecoveryBootNotice(_ message: String) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "arrow.clockwise.circle.fill")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(Color(red: 0.28, green: 0.82, blue: 0.94))

            VStack(alignment: .leading, spacing: 3) {
                Text("Boot TWRP manuel requis")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)

                Text(message)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.70))
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 16)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(red: 0.28, green: 0.82, blue: 0.94).opacity(0.10))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color(red: 0.28, green: 0.82, blue: 0.94).opacity(0.22), lineWidth: 1)
        )
    }

    private func advancedSettingsSheet(viewModel: FlashViewModel) -> some View {
        @Bindable var viewModel = viewModel

        return VStack(spacing: 0) {
            HStack {
                Text("Paramètres avancés")
                    .font(.title2)
                    .fontWeight(.semibold)

                Spacer()

                Button("Fermer") {
                    showsAdvancedSettings = false
                }
            }
            .padding(18)

            Divider()

            TabView(selection: $advancedTab) {
                advancedSettings(viewModel: viewModel)
                    .tabItem {
                        Label("Paramètres", systemImage: "slider.horizontal.3")
                    }
                    .tag(AdvancedTab.settings)

                LogConsoleView(lines: viewModel.logLines)
                    .padding(16)
                    .tabItem {
                        Label("Journal", systemImage: "terminal")
                    }
                    .tag(AdvancedTab.logs)
            }
        }
    }

    private var appInfoSheet: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Informations")
                    .font(.title2)
                    .fontWeight(.semibold)

                Spacer()

                Button {
                    reportIssue(viewModel: viewModel)
                } label: {
                    Label("Signaler un problème", systemImage: "ladybug")
                }
                .help("Ouvre un rapport GitHub pré-rempli avec la version et le téléphone détecté")

                Button("Fermer") {
                    showsAppInfo = false
                }
            }
            .padding(18)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    HStack(spacing: 12) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 8)
                                .fill(Color(red: 0.08, green: 0.62, blue: 0.76))
                                .frame(width: 42, height: 42)

                            Image(systemName: "iphone")
                                .font(.system(size: 22, weight: .semibold))
                                .foregroundStyle(.white)
                        }

                        VStack(alignment: .leading, spacing: 3) {
                            Text("FlashPort")
                                .font(.system(size: 17, weight: .semibold))

                            Text("Version \(appVersionText) — BETA")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        Spacer()

                        Link(destination: URL(string: "https://github.com/hadrien500/FlashPort")!) {
                            Label("Page GitHub", systemImage: "arrow.up.right.square")
                                .font(.caption)
                        }
                    }

                    Text(appDescriptionText)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    VStack(alignment: .leading, spacing: 10) {
                        Label("Nouveautés de cette version", systemImage: "sparkles")
                            .font(.headline)

                        ForEach(appLatestChanges, id: \.self) { change in
                            HStack(alignment: .top, spacing: 8) {
                                Circle()
                                    .fill(Color(red: 0.28, green: 0.82, blue: 0.94))
                                    .frame(width: 5, height: 5)
                                    .padding(.top, 6)

                                Text(change)
                                    .font(.callout)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }

                        Link(destination: URL(string: "https://github.com/hadrien500/FlashPort/blob/main/CHANGELOG.md")!) {
                            Label("Historique complet des versions", systemImage: "clock.arrow.circlepath")
                                .font(.caption)
                        }
                        .padding(.top, 2)
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 10)
                            .fill(Color.primary.opacity(0.05))
                    )

                    VStack(alignment: .leading, spacing: 12) {
                        Text("L'essentiel")
                            .font(.headline)

                        LazyVGrid(
                            columns: [
                                GridItem(.flexible(), alignment: .topLeading),
                                GridItem(.flexible(), alignment: .topLeading)
                            ],
                            alignment: .leading,
                            spacing: 12
                        ) {
                            ForEach(appKeyFeatures, id: \.text) { feature in
                                HStack(alignment: .top, spacing: 8) {
                                    Image(systemName: feature.icon)
                                        .font(.system(size: 13, weight: .semibold))
                                        .foregroundStyle(Color(red: 0.28, green: 0.82, blue: 0.94))
                                        .frame(width: 18)
                                        .padding(.top, 2)

                                    Text(feature.text)
                                        .font(.callout)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                    }

                    Divider()

                    flashHistorySection(viewModel: viewModel)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(18)
            }
        }
    }

    private func flashHistorySection(viewModel: FlashViewModel) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Sessions récentes")
                    .font(.headline)

                Spacer()

                Button {
                    exportSessionReport(viewModel: viewModel)
                } label: {
                    Label("Exporter rapport", systemImage: "square.and.arrow.up")
                }
                .controlSize(.small)
            }

            if viewModel.flashHistoryEntries.isEmpty {
                Text("Aucun flash enregistré pour l'instant.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                VStack(spacing: 0) {
                    ForEach(viewModel.flashHistoryEntries.prefix(5)) { entry in
                        flashHistoryRow(entry)
                        if entry.id != viewModel.flashHistoryEntries.prefix(5).last?.id {
                            Divider()
                        }
                    }
                }
                .background(Color.black.opacity(0.03))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    private func flashHistoryRow(_ entry: FlashHistoryEntry) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: entry.result == "Succès" ? "checkmark.circle.fill" : "xmark.octagon.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(entry.result == "Succès" ? completedStepColor : .red)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 3) {
                Text("\(entry.result) · \(historyDateText(entry.date))")
                    .font(.system(size: 12, weight: .semibold))

                Text("\(entry.firmwareName.isEmpty ? "Firmware non renseigné" : entry.firmwareName) · \(entry.backendName)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Text("\(entry.selectedImageCount) images · \(ByteCountFormatter.string(fromByteCount: Int64(clamping: entry.selectedSize), countStyle: .file)) · \(entry.dataModeTitle)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 10)
    }

    private func historyDateText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    private func firmwareInfoSheet(viewModel: FlashViewModel) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Label("Info firmware", systemImage: "info.circle")
                    .font(.title2)
                    .fontWeight(.semibold)

                Spacer()

                Button("Fermer") {
                    showsFirmwareInfo = false
                }
            }
            .padding(18)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    firmwareInfoStatus(viewModel: viewModel)
                    firmwareSecuritySettings(viewModel: viewModel)
                    firmwareIssueList(
                        title: "Blocages",
                        issues: viewModel.firmwareCompatibilityErrors,
                        color: .red,
                        systemImage: "xmark.octagon.fill"
                    )
                    firmwareArchiveInfoList(viewModel: viewModel)
                }
                .padding(.horizontal, 22)
                .padding(.vertical, 20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func firmwareInfoStatus(viewModel: FlashViewModel) -> some View {
        let color = firmwareCompatibilityStatusColor(viewModel: viewModel)

        return HStack(alignment: .top, spacing: 10) {
            Image(systemName: firmwareInfoStatusIcon(viewModel: viewModel))
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(color)
                .frame(width: 22)

            VStack(alignment: .leading, spacing: 4) {
                Text(firmwareInfoStatusTitle(viewModel: viewModel))
                    .font(.headline)

                Text(viewModel.firmwareCompatibilitySummary)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(color.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(color.opacity(0.18), lineWidth: 1)
        )
    }

    private func firmwareInfoStatusTitle(viewModel: FlashViewModel) -> String {
        if viewModel.firmwareArchives.isEmpty {
            return "Aucun firmware importé"
        }
        if !viewModel.firmwareCompatibilityErrors.isEmpty {
            return "Firmware incompatible"
        }
        if !viewModel.firmwareCompatibilityWarnings.isEmpty {
            return "Firmware à vérifier"
        }
        if !viewModel.firmwarePackageMetadata.modelCodes.isEmpty
            && (viewModel.detectedDeviceModelCode != nil || viewModel.normalizedExpectedDeviceModelCode != nil) {
            return "Modèle compatible"
        }
        return "Infos firmware scannées"
    }

    private func firmwareInfoStatusIcon(viewModel: FlashViewModel) -> String {
        if viewModel.firmwareArchives.isEmpty {
            return "archivebox"
        }
        if !viewModel.firmwareCompatibilityErrors.isEmpty {
            return "xmark.octagon.fill"
        }
        if !viewModel.firmwareCompatibilityWarnings.isEmpty {
            return "exclamationmark.triangle.fill"
        }
        if !viewModel.firmwarePackageMetadata.modelCodes.isEmpty
            && (viewModel.detectedDeviceModelCode != nil || viewModel.normalizedExpectedDeviceModelCode != nil) {
            return "checkmark.shield.fill"
        }
        return "info.circle.fill"
    }

    @ViewBuilder
    private func firmwareIssueList(title: String, issues: [String], color: Color, systemImage: String) -> some View {
        if !issues.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Label(title, systemImage: systemImage)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(color)

                ForEach(issues, id: \.self) { issue in
                    Text(issue)
                        .font(.caption)
                        .foregroundStyle(color)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func firmwareArchiveInfoList(viewModel: FlashViewModel) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Archives détectées", systemImage: "shippingbox")
                .font(.system(size: 13, weight: .semibold))

            if viewModel.firmwareArchives.isEmpty {
                Text("Aucune archive BL/AP/CP/CSC scannée.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                VStack(spacing: 0) {
                    ForEach(viewModel.firmwareArchives) { archive in
                        archiveInfoRow(archive)

                        if archive.id != viewModel.firmwareArchives.last?.id {
                            Divider()
                        }
                    }
                }
                .padding(.horizontal, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.black.opacity(0.03))
                .cornerRadius(6)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func archiveInfoRow(_ archive: FirmwareArchive) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(archive.slot.rawValue)
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 58, alignment: .leading)

            VStack(alignment: .leading, spacing: 3) {
                Text(archive.displayName)
                    .font(.caption)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Text(archiveMetadataSummary(archive))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func archiveMetadataSummary(_ archive: FirmwareArchive) -> String {
        var parts = [
            "\(archive.entries.count) entrées",
            "TAR lisible",
            archive.displayName.lowercased().hasSuffix(".tar.md5") ? "MD5 présent" : "MD5 absent"
        ]
        if let modelCode = archive.modelCode {
            parts.append(formatDeviceModelCode(modelCode))
        }
        if let buildCode = FirmwareCompatibilityValidator.firmwareBuildCode(from: archive.displayName) {
            parts.append(buildCode)
        }
        if let bootloaderRevision = archive.bootloaderRevision {
            parts.append("binary \(FirmwareCompatibilityValidator.bootloaderRevisionText(bootloaderRevision))")
        }
        return parts.joined(separator: " - ")
    }

    private func firmwareSecuritySettings(viewModel: FlashViewModel) -> some View {
        @Bindable var viewModel = viewModel

        return VStack(alignment: .leading, spacing: 12) {
            firmwareMetadataGrid(viewModel: viewModel)

            DisclosureGroup("Vérification manuelle", isExpanded: $showsManualFirmwareChecks) {
                HStack(spacing: 8) {
                    Text("Modèle téléphone")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    TextField(
                        "SM-A536B",
                        text: Binding(
                            get: { viewModel.expectedDeviceModelCode },
                            set: { viewModel.setExpectedDeviceModelCode($0) }
                        )
                    )
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 150)

                    Text("Binary actuel")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    TextField(
                        "1",
                        text: Binding(
                            get: { viewModel.currentBootloaderRevision },
                            set: { viewModel.setCurrentBootloaderRevision($0) }
                        )
                    )
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 56)

                    if !viewModel.expectedDeviceModelCode.isEmpty || !viewModel.currentBootloaderRevision.isEmpty {
                        Button {
                            viewModel.setExpectedDeviceModelCode("")
                            viewModel.setCurrentBootloaderRevision("")
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                        }
                        .buttonStyle(.borderless)
                        .help("Effacer le modèle et le binary saisis")
                    }

                    Spacer()
                }
                .padding(.top, 6)

                Text("À utiliser seulement si le téléphone ne donne pas son modèle en Download Mode.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .font(.caption)
        }
    }

    private func firmwareMetadataGrid(viewModel: FlashViewModel) -> some View {
        LazyVGrid(
            columns: [
                GridItem(.flexible(minimum: 220), spacing: 12, alignment: .top),
                GridItem(.flexible(minimum: 220), spacing: 12, alignment: .top)
            ],
            alignment: .leading,
            spacing: 12
        ) {
            firmwareMetadataItem(
                title: "Package",
                value: firmwarePackageSourceSummary(viewModel.firmwarePackageMetadata),
                systemImage: "archivebox"
            )
            firmwareMetadataItem(
                title: "Modèle firmware",
                value: firmwareModelSummary(viewModel.firmwarePackageMetadata.modelCodes),
                systemImage: "iphone"
            )
            firmwareMetadataItem(
                title: "Région",
                value: firmwareRegionSummary(viewModel.firmwarePackageMetadata.regionCodes),
                systemImage: "globe"
            )
            firmwareMetadataItem(
                title: "Version firmware",
                value: firmwareBuildSummary(viewModel.firmwarePackageMetadata.buildCodes),
                systemImage: "number"
            )
            firmwareMetadataItem(
                title: "Binary firmware",
                value: firmwareBinarySummary(viewModel.firmwarePackageMetadata.bootloaderRevisions),
                systemImage: "lock.shield"
            )
            firmwareMetadataItem(
                title: "Téléphone",
                value: deviceModelSummary(viewModel: viewModel),
                systemImage: "cable.connector"
            )
        }
    }

    private func firmwareMetadataItem(title: String, value: String, systemImage: String) -> some View {
        HStack(alignment: .top, spacing: 7) {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private func firmwarePackageSourceSummary(_ metadata: FirmwarePackageMetadata) -> String {
        if let sourceName = metadata.sourceName {
            return sourceName
        }
        if metadata.archiveCount > 0 {
            return "\(metadata.archiveCount) archives, \(metadata.imageCount) images"
        }
        return "Aucun firmware"
    }

    private func firmwareModelSummary(_ modelCodes: [String]) -> String {
        guard !modelCodes.isEmpty else { return "Non détecté" }
        return modelCodes.map(formatDeviceModelCode).joined(separator: ", ")
    }

    private func firmwareRegionSummary(_ regionCodes: [String]) -> String {
        regionCodes.isEmpty ? "Non détectée" : regionCodes.joined(separator: ", ")
    }

    private func firmwareBuildSummary(_ buildCodes: [String]) -> String {
        guard !buildCodes.isEmpty else { return "Non détectée" }
        if buildCodes.count <= 2 {
            return buildCodes.joined(separator: ", ")
        }
        return buildCodes.prefix(2).joined(separator: ", ") + " +\(buildCodes.count - 2)"
    }

    private func firmwareBinarySummary(_ revisions: [Int]) -> String {
        guard !revisions.isEmpty else { return "Non détecté" }
        return revisions
            .map { FirmwareCompatibilityValidator.bootloaderRevisionText($0) }
            .joined(separator: ", ")
    }

    private func deviceModelSummary(viewModel: FlashViewModel) -> String {
        if let detectedDeviceModelCode = viewModel.detectedDeviceModelCode {
            return "Détecté \(formatDeviceModelCode(detectedDeviceModelCode))"
        }
        if let expectedDeviceModelCode = viewModel.normalizedExpectedDeviceModelCode {
            return "Saisi \(formatDeviceModelCode(expectedDeviceModelCode))"
        }
        return "Non détecté"
    }

    private func formatDeviceModelCode(_ modelCode: String) -> String {
        modelCode.hasPrefix("SM-") ? modelCode : "SM-\(modelCode)"
    }

    private func advancedSettings(viewModel: FlashViewModel) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                interfaceModeSettings

                advancedSection(
                    "Rapports",
                    systemImage: "doc.text",
                    subtitle: "Exporter les informations utiles pour diagnostiquer ou archiver une session."
                ) {
                    reportActionRow(viewModel: viewModel)
                }

                advancedSection(
                    "Méthode de flash",
                    systemImage: "bolt.horizontal",
                    subtitle: "Choisis entre le moteur natif Swift et Heimdall (externe)."
                ) {
                    HStack(alignment: .top, spacing: 32) {
                        flashBackendSettings(viewModel: viewModel)
                            .frame(maxWidth: 410, alignment: .leading)

                        if interfaceMode == .expert {
                            dangerousFlashSettings(viewModel: viewModel)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }

                advancedSection(
                    "Recovery personnalisé (TWRP)",
                    systemImage: "wrench.and.screwdriver",
                    subtitle: "Flasher un recovery TWRP et son vbmeta (.img, .img.lz4, .tar, .tar.md5) ou un dossier complet."
                ) {
                    VStack(alignment: .leading, spacing: 8) {
                        Button {
                            selectRecoveryImage(viewModel: viewModel)
                        } label: {
                            Label("Flasher un recovery…", systemImage: "internaldrive")
                        }
                        .disabled(viewModel.isImportingFirmware)

                        Text("Sélectionne un ou plusieurs fichiers (recovery + vbmeta patché) ou le dossier qui les contient. Chaque image est mappée sur sa partition. Vérifie que la build TWRP correspond exactement au modèle et au chipset du téléphone. Un bootloader déverrouillé (Déverrouillage OEM) est requis. Après le flash, quitte Download puis maintiens Volume Haut + Power jusqu'à TWRP.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                if interfaceMode == .expert {
                    advancedSection(
                        "Actions rapides",
                        systemImage: "wand.and.stars",
                        subtitle: "Tests et sélections manuelles pour diagnostiquer un flash."
                    ) {
                        advancedActionGrid(viewModel: viewModel)
                    }

                    Divider()

                    advancedDisclosure(
                        title: viewModel.hasLoadedPit ? "Table de partitions (\(viewModel.pitEntries.count))" : "Table de partitions",
                        systemImage: "tablecells",
                        isExpanded: $showsPitDetails
                    ) {
                        if viewModel.hasLoadedPit {
                            PitSummaryView(entries: viewModel.pitEntries)
                        } else {
                            Text("Aucune table de partitions chargée. Le flash peut la lire automatiquement si nécessaire.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    advancedDisclosure(
                        title: "Correspondances firmware (\(viewModel.firmwareMappings.count))",
                        systemImage: "list.bullet.rectangle",
                        isExpanded: $showsFirmwareDetails
                    ) {
                        firmwareMappingSettings(viewModel: viewModel)
                    }
                }
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var interfaceModeSettings: some View {
        advancedSection(
            "Interface",
            systemImage: "switch.2",
            subtitle: "Guidé masque les actions risquées. Expert affiche les outils PIT, sélection et Erase NAND."
        ) {
            Picker(
                "",
                selection: $interfaceMode
            ) {
                ForEach(InterfaceMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .frame(width: 280)
        }
    }

    private func flashBackendSettings(viewModel: FlashViewModel) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Méthode utilisée")
                .font(.caption)
                .foregroundStyle(.secondary)

            Picker(
                "",
                selection: Binding(
                    get: { viewModel.flashBackend },
                    set: { viewModel.setFlashBackend($0) }
                )
            ) {
                ForEach(FlashBackend.allCases) { backend in
                    Text(backend.title).tag(backend)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .frame(maxWidth: 380)

            Text(viewModel.flashBackendStatusText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func dangerousFlashSettings(viewModel: FlashViewModel) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Dernier recours", systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(.orange)

            Toggle("Erase NAND - effacement bas niveau", isOn: Binding(
                get: { viewModel.nandEraseBeforeFlash },
                set: { viewModel.setNandEraseBeforeFlash($0) }
            ))
            .toggleStyle(.checkbox)
            .foregroundStyle(viewModel.nandEraseBeforeFlash ? .orange : .secondary)
            .help("Efface userdata via Odin avant le flash")

            Text("Commande Odin directe avant le flash. À utiliser seulement si Effacer données ne suffit pas.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func reportActionRow(viewModel: FlashViewModel) -> some View {
        HStack(spacing: 10) {
            Button {
                exportSessionReport(viewModel: viewModel)
            } label: {
                Label("Exporter rapport", systemImage: "square.and.arrow.up")
            }

            Button {
                exportPit(viewModel: viewModel)
            } label: {
                Label("Exporter PIT", systemImage: "tablecells")
            }
            .disabled(!viewModel.hasLoadedPit)

            Spacer()

            Text("\(viewModel.flashHistoryEntries.count) sessions dans l'historique")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .controlSize(.small)
    }

    private func advancedActionGrid(viewModel: FlashViewModel) -> some View {
        LazyVGrid(
            columns: [
                GridItem(.adaptive(minimum: 145, maximum: 220), spacing: 8, alignment: .leading)
            ],
            alignment: .leading,
            spacing: 8
        ) {
            Button {
                viewModel.testOdinConnection()
            } label: {
                Label("Tester Odin", systemImage: "bolt.horizontal")
            }
            .disabled(!viewModel.canTestOdinConnection)

            Button {
                viewModel.readPit()
            } label: {
                Label(viewModel.hasLoadedPit ? "PIT chargé" : "Lire PIT", systemImage: "tablecells")
            }
            .disabled(!viewModel.canReadPit)

            Button {
                exportPit(viewModel: viewModel)
            } label: {
                Label("Exporter PIT", systemImage: "square.and.arrow.up")
            }
            .disabled(!viewModel.hasLoadedPit)

            Button {
                viewModel.selectRecommendedFirmwareMappings()
            } label: {
                Label("Sélection conseillée", systemImage: "checklist")
            }
            .disabled(!viewModel.hasFirmwareMappingSource || viewModel.firmwareMappings.isEmpty)

            Button {
                viewModel.selectSmallCscFirmwareMappings()
            } label: {
                Label("CSC minimal", systemImage: "line.3.horizontal.decrease")
            }
            .disabled(!viewModel.hasFirmwareMappingSource || viewModel.firmwareMappings.isEmpty)

            Button {
                viewModel.selectUserdataOnlyFirmwareMapping()
            } label: {
                Label("Seulement userdata", systemImage: "externaldrive.badge.xmark")
            }
            .disabled(viewModel.firmwareMappings.isEmpty)

            Button {
                viewModel.clearFirmwareMappingSelection()
            } label: {
                Label("Effacer sélection", systemImage: "xmark")
            }
            .disabled(viewModel.selectedFirmwareMappingIDs.isEmpty)
        }
        .controlSize(.small)
    }

    private func firmwareMappingSettings(viewModel: FlashViewModel) -> some View {
        FirmwareSelectionView(
            archiveForSlot: { viewModel.firmwareArchive(for: $0) },
            mappings: viewModel.firmwareMappings,
            unmatchedEntries: viewModel.firmwareUnmatchedEntries,
            selectedMappingIDs: viewModel.selectedFirmwareMappingIDs,
            selectionWarnings: viewModel.selectionWarnings,
            warnings: viewModel.firmwareWarnings,
            errors: viewModel.firmwareErrors,
            mappingSourceName: viewModel.firmwareMappingSourceName,
            hasMappingSource: viewModel.hasFirmwareMappingSource
        ) { mappingID, isSelected in
            viewModel.setFirmwareMappingSelection(mappingID, isSelected: isSelected)
        } onRecommendedSelectionRequested: {
            viewModel.selectRecommendedFirmwareMappings()
        } onSmallCscSelectionRequested: {
            viewModel.selectSmallCscFirmwareMappings()
        } onSelectionCleared: {
            viewModel.clearFirmwareMappingSelection()
        } onArchiveSelected: { url, slot in
            viewModel.setFirmwareArchive(url, for: slot)
        } onArchiveRemoved: { slot in
            viewModel.removeFirmwareArchive(for: slot)
        }
    }

    private func advancedSection<Content: View>(
        _ title: String,
        systemImage: String,
        subtitle: String? = nil,
        @ViewBuilder content: @escaping () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Label(title, systemImage: systemImage)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.primary)

                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func advancedDisclosure<Content: View>(
        title: String,
        systemImage: String,
        isExpanded: Binding<Bool>,
        @ViewBuilder content: @escaping () -> Content
    ) -> some View {
        DisclosureGroup(isExpanded: isExpanded) {
            content()
                .padding(.top, 8)
        } label: {
            Label(title, systemImage: systemImage)
                .font(.system(size: 13, weight: .semibold))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func firmwareStepSubtitle(viewModel: FlashViewModel) -> String {
        if viewModel.isImportingFirmware {
            return viewModel.firmwareImportProgress?.message ?? "Analyse du firmware"
        }
        if viewModel.firmwareImportProgress?.isFailed == true {
            return viewModel.firmwareImportProgress?.message ?? "Import interrompu"
        }
        if let sourceName = viewModel.importedFirmwareSourceName {
            return sourceName
        }
        if !viewModel.firmwareArchives.isEmpty {
            return "\(viewModel.firmwareArchives.count) fichiers chargés"
        }
        return "ZIP complet Samsung"
    }

    private func deviceStepSubtitle(viewModel: FlashViewModel) -> String {
        if viewModel.hasOpenOdinSession {
            return "PIT chargé, session prête"
        }
        if viewModel.isDeviceConnected {
            if viewModel.hasLoadedPit {
                return "Download Mode détecté, PIT chargé"
            }
            return viewModel.connectedDeviceDescription ?? "Download Mode détecté"
        }
        if viewModel.hasLoadedPit {
            return "PIT chargé, recherche téléphone"
        }
        if viewModel.isSearchingDownloadModeDevice {
            return "Recherche automatique"
        }
        return "Branche en Download Mode"
    }

    private func flashStepSubtitle(viewModel: FlashViewModel) -> String {
        switch viewModel.state {
        case .preparingFirmware:
            return "Décompression firmware"
        case .connecting:
            return "Connexion au téléphone"
        case .handshaking:
            return "Session Odin"
        case .readingPIT:
            return "Lecture PIT"
        case .flashing(let partition, _):
            return "Écriture \(partition)"
        case .finishing:
            return viewModel.rebootAfterFlash ? "Redémarrage automatique" : "Finalisation"
        case .completed where didCompleteFlash(viewModel: viewModel):
            return "Flash terminé avec succès"
        case .completed:
            break
        case .failed:
            return "Flash interrompu"
        case .idle:
            break
        }

        if viewModel.canReadPitBeforeRealFlash {
            return "Prêt à flasher"
        }
        if viewModel.selectedFirmwareMappings.isEmpty {
            return "Firmware requis"
        }
        if !viewModel.firmwareErrors.isEmpty || hasExclusiveCscConflict(viewModel: viewModel) {
            return "Vérifier firmware"
        }
        if hasDuplicatePartitionSelection(viewModel: viewModel) {
            return "Sélection invalide"
        }
        if hasIncompatibleUserdataSelection(viewModel: viewModel) {
            return "Mode données incompatible"
        }
        if requiresHeimdallBackendForFlash(viewModel: viewModel) && !viewModel.isHeimdallAvailable {
            return "Heimdall requis"
        }
        if willReadPitAutomatically(viewModel: viewModel) {
            return "Préparation automatique"
        }
        if viewModel.rebootAfterFlash {
            return "Redémarrage auto après flash"
        }
        return flashSummaryText(viewModel: viewModel)
    }

    private func flashButtonTitle(viewModel: FlashViewModel) -> String {
        switch viewModel.state {
        case .flashing, .finishing:
            return "Flash en cours"
        case .completed:
            return canFlashFromMain(viewModel: viewModel) ? "Flasher" : "Terminé"
        case .failed:
            return canFlashFromMain(viewModel: viewModel) ? "Réessayer" : flashUnavailableTitle(viewModel: viewModel)
        case .readingPIT:
            return "Lecture PIT"
        case .idle, .preparingFirmware, .connecting, .handshaking:
            return canFlashFromMain(viewModel: viewModel) ? "Flasher" : flashUnavailableTitle(viewModel: viewModel)
        }
    }

    private func flashButtonIcon(viewModel: FlashViewModel) -> String {
        switch viewModel.state {
        case .flashing, .finishing:
            return "hourglass"
        case .completed:
            if canFlashFromMain(viewModel: viewModel) {
                return "arrow.up.circle.fill"
            }
            return didCompleteFlash(viewModel: viewModel) ? "checkmark.circle" : flashUnavailableIcon(viewModel: viewModel)
        case .failed:
            return canFlashFromMain(viewModel: viewModel) ? "arrow.counterclockwise.circle" : flashUnavailableIcon(viewModel: viewModel)
        case .readingPIT:
            return "tablecells"
        case .idle, .preparingFirmware, .connecting, .handshaking:
            return canFlashFromMain(viewModel: viewModel) ? "arrow.up.circle.fill" : flashUnavailableIcon(viewModel: viewModel)
        }
    }

    private func flashUnavailableTitle(viewModel: FlashViewModel) -> String {
        if viewModel.isImportingFirmware {
            return "Import en cours"
        }
        if !hasFirmwareBundle(viewModel: viewModel) {
            return "Firmware requis"
        }
        if !isDeviceAvailableForFlash(viewModel: viewModel) {
            return "Téléphone requis"
        }
        if !viewModel.hasFirmwareMappingSource || viewModel.firmwareMappings.isEmpty {
            return "PIT requis"
        }
        if !viewModel.firmwareErrors.isEmpty || hasExclusiveCscConflict(viewModel: viewModel) {
            return "Vérifier firmware"
        }
        if viewModel.selectedFirmwareMappings.isEmpty {
            return "Sélection requise"
        }
        if hasDuplicatePartitionSelection(viewModel: viewModel) {
            return "Sélection invalide"
        }
        if hasIncompatibleUserdataSelection(viewModel: viewModel) {
            return "Mode données"
        }
        if requiresHeimdallBackendForFlash(viewModel: viewModel) && !viewModel.isHeimdallAvailable {
            return "Heimdall requis"
        }
        return "Indisponible"
    }

    private func flashUnavailableIcon(viewModel: FlashViewModel) -> String {
        let title = flashUnavailableTitle(viewModel: viewModel)

        switch title {
        case "Firmware requis", "Import en cours":
            return "archivebox"
        case "Téléphone requis":
            return "cable.connector"
        case "PIT requis":
            return "tablecells"
        case "Heimdall requis":
            return "exclamationmark.triangle"
        case "Sélection requise", "Sélection invalide":
            return "checklist"
        case "Mode données":
            return "externaldrive.badge.xmark"
        default:
            return "lock"
        }
    }

    private func exitDownloadButtonTitle(viewModel: FlashViewModel) -> String {
        if viewModel.hasCustomRecoveryFlashSelection {
            return "Quitter Download"
        }
        if viewModel.canExitDownloadMode {
            return "Quitter Download"
        }
        if viewModel.isDeviceConnected || viewModel.hasOpenOdinSession {
            return "Action en cours"
        }
        return "Téléphone requis"
    }

    private func exitDownloadHelp(viewModel: FlashViewModel) -> String {
        if viewModel.hasCustomRecoveryFlashSelection {
            return "Désactivé pour TWRP : sors manuellement du mode Download et démarre directement en recovery"
        }
        if viewModel.canExitDownloadMode {
            return "Redémarre le téléphone pour sortir du mode Download"
        }
        if viewModel.isDeviceConnected || viewModel.hasOpenOdinSession {
            return "Disponible quand l'opération en cours est terminée"
        }
        return "Disponible après détection d'un téléphone en mode Download"
    }

    private func deviceButtonTitle(viewModel: FlashViewModel) -> String {
        return "Actualiser"
    }

    private func deviceButtonIcon(viewModel: FlashViewModel) -> String {
        return "arrow.clockwise"
    }

    private func deviceButtonEnabled(viewModel: FlashViewModel) -> Bool {
        return viewModel.isDeviceConnected || !viewModel.isSearchingDownloadModeDevice
    }

    private func shouldShowDeviceSearchIndicator(viewModel: FlashViewModel) -> Bool {
        !viewModel.isDeviceConnected && viewModel.isSearchingDownloadModeDevice
    }

    private func canFlashFromMain(viewModel: FlashViewModel) -> Bool {
        viewModel.canStartRealFlashOrPrepare
    }

    private func isFlashStepButtonEnabled(viewModel: FlashViewModel) -> Bool {
        canFlashFromMain(viewModel: viewModel)
    }

    private func isDeviceAvailableForFlash(viewModel: FlashViewModel) -> Bool {
        viewModel.isDeviceConnected || viewModel.hasOpenOdinSession
    }

    private func willReadPitAutomatically(viewModel: FlashViewModel) -> Bool {
        guard viewModel.flashBackend == .heimdall && !viewModel.hasLoadedPit else {
            return false
        }

        return (
            viewModel.firmwareDataMode == .erase
                && viewModel.firmwareMappings.contains { $0.partition.partitionName == "userdata" }
        ) || viewModel.hasCustomRecoveryFlashSelection
    }

    private func hasDuplicatePartitionSelection(viewModel: FlashViewModel) -> Bool {
        Dictionary(grouping: viewModel.selectedFirmwareMappings, by: { $0.partition.partitionName })
            .contains { $0.value.count > 1 }
    }

    private func hasExclusiveCscConflict(viewModel: FlashViewModel) -> Bool {
        viewModel.firmwareArchives.contains { $0.slot == .csc }
            && viewModel.firmwareArchives.contains { $0.slot == .homeCSC }
    }

    private func hasIncompatibleUserdataSelection(viewModel: FlashViewModel) -> Bool {
        viewModel.firmwareDataMode == .preserve
            && viewModel.selectedFirmwareMappings.contains { $0.partition.partitionName == "userdata" }
    }

    private func requiresNativeSwiftSessionForFlash(viewModel: FlashViewModel) -> Bool {
        viewModel.nandEraseBeforeFlash
            || (
                viewModel.flashBackend == .heimdall
                    && viewModel.firmwareDataMode == .erase
                    && viewModel.firmwareMappings.contains { $0.partition.partitionName == "userdata" }
            )
            || (
                viewModel.flashBackend == .heimdall
                    && viewModel.hasCustomRecoveryFlashSelection
            )
            || viewModel.flashBackend == .nativeSwift
    }

    private func requiresHeimdallBackendForFlash(viewModel: FlashViewModel) -> Bool {
        viewModel.flashBackend == .heimdall && !requiresNativeSwiftSessionForFlash(viewModel: viewModel)
    }

    private func hasFirmwareBundle(viewModel: FlashViewModel) -> Bool {
        viewModel.importedFirmwareSourceName != nil
            || !viewModel.firmwareArchives.isEmpty
            || !viewModel.firmwareMappings.isEmpty
            || !viewModel.selectedFirmwareMappingIDs.isEmpty
    }

    private func firmwareStepStatus(viewModel: FlashViewModel) -> WorkflowStepStatus {
        if viewModel.isImportingFirmware {
            return .active
        }
        if viewModel.firmwareImportProgress?.isFailed == true {
            return .warning
        }
        if !viewModel.firmwareErrors.isEmpty {
            return .warning
        }
        // Un firmware importé et sans erreur est « prêt » : le mapping des
        // images sur les partitions se fait au moment du flash (lecture PIT
        // automatique en mode natif), donc on ne dépend pas de la sélection.
        if !viewModel.firmwareArchives.isEmpty || viewModel.importedFirmwareSourceName != nil {
            return .complete
        }
        return .pending
    }

    private func firmwareStepRingProgress(viewModel: FlashViewModel) -> Double? {
        guard viewModel.isImportingFirmware else {
            return nil
        }
        return viewModel.firmwareImportProgress?.progress ?? 0.02
    }

    private func deviceStepStatus(viewModel: FlashViewModel) -> WorkflowStepStatus {
        if viewModel.isReadingPitBeforeFlash && isDeviceAvailableForFlash(viewModel: viewModel) {
            return .complete
        }
        if isDeviceOperationActive(viewModel.state) {
            return .active
        }
        if viewModel.isSearchingDownloadModeDevice {
            return .active
        }
        if viewModel.hasOpenOdinSession || viewModel.isDeviceConnected {
            return .complete
        }
        return .pending
    }

    private func flashStepStatus(viewModel: FlashViewModel) -> WorkflowStepStatus {
        if viewModel.isReadingPitBeforeFlash {
            return .active
        }
        if isFlashOperationActive(viewModel.state) {
            return .active
        }
        if didCompleteFlash(viewModel: viewModel) {
            return .complete
        }
        if case .failed = viewModel.state {
            return .error
        }
        if canFlashFromMain(viewModel: viewModel) {
            return .ready
        }
        return .pending
    }

    private func isDeviceOperationActive(_ state: FlashSessionState) -> Bool {
        switch state {
        case .connecting, .handshaking, .readingPIT:
            return true
        case .idle, .preparingFirmware, .flashing, .finishing, .completed, .failed:
            return false
        }
    }

    private func isFlashOperationActive(_ state: FlashSessionState) -> Bool {
        switch state {
        case .preparingFirmware, .flashing, .finishing:
            return true
        case .idle, .connecting, .handshaking, .readingPIT, .completed, .failed:
            return false
        }
    }

    private func flashStepRingProgress(_ state: FlashSessionState) -> Double? {
        switch state {
        case .flashing(_, let progress):
            return min(max(progress, 0), 1)
        case .finishing:
            return 0.98
        default:
            return nil
        }
    }

    private func stepRingStatusProgress(_ status: WorkflowStepStatus) -> Double? {
        switch status {
        case .pending:
            return nil
        case .active:
            return nil
        case .ready:
            // Pas d'arc partiel : une étape « prête » n'est pas « à 18 % ».
            // L'anneau reste vide (seul le numéro s'affiche), l'accent de
            // couleur vient de la teinte du contour et du badge.
            return nil
        case .complete:
            return 1
        case .warning:
            return 1
        case .error:
            return 1
        }
    }

    private func stepRingColor(status: WorkflowStepStatus, tone: WorkflowStepTone, isReady: Bool) -> Color {
        switch status {
        case .pending:
            return isReady ? tone.accent.opacity(0.42) : .white.opacity(0.20)
        case .warning:
            return .orange
        case .error:
            return Color(red: 1.0, green: 0.30, blue: 0.30)
        case .active:
            return activeStepColor
        case .ready:
            return tone.accent
        case .complete:
            return completedStepColor
        }
    }

    private func stepRingContentColor(status: WorkflowStepStatus, tone: WorkflowStepTone, isReady: Bool) -> Color {
        switch status {
        case .pending:
            return isReady ? tone.accent.opacity(0.58) : .white.opacity(0.46)
        case .active:
            return activeStepColor
        case .ready:
            return tone.accent
        case .complete:
            return completedStepColor
        case .warning:
            return .orange
        case .error:
            return Color(red: 1.0, green: 0.30, blue: 0.30)
        }
    }

    private func statusBadgeColor(status: WorkflowStepStatus, tone: WorkflowStepTone) -> Color {
        switch status {
        case .pending:
            return .white.opacity(0.34)
        case .active:
            return activeStepColor.opacity(0.90)
        case .ready:
            return tone.accent
        case .complete:
            return completedStepColor
        case .warning:
            return .orange
        case .error:
            return Color(red: 1.0, green: 0.30, blue: 0.30)
        }
    }

    private func dataModeSelectedColor(_ mode: FirmwareDataMode) -> Color {
        switch mode {
        case .erase:
            return Color(red: 1.0, green: 0.08, blue: 0.16)
        case .preserve:
            return activeStepColor
        }
    }

    private func dataModeTextColor(_ mode: FirmwareDataMode, isSelected: Bool) -> Color {
        isSelected ? .white : .white.opacity(0.64)
    }

    private func dataModeSelectionBackground(_ mode: FirmwareDataMode, isSelected: Bool) -> Color {
        isSelected ? dataModeSelectedColor(mode) : .clear
    }

    private func bottomToggleForeground(isEnabled: Bool, isSelected: Bool) -> Color {
        guard isEnabled else {
            return .white.opacity(0.34)
        }
        return isSelected ? .white.opacity(0.88) : .white.opacity(0.58)
    }

    private func bottomToggleBackground(isEnabled: Bool, isSelected: Bool) -> Color {
        guard isEnabled else {
            return Color.white.opacity(0.045)
        }
        return isSelected ? activeStepColor.opacity(0.18) : Color.white.opacity(0.075)
    }

    private func bottomToggleBorder(isEnabled: Bool, isSelected: Bool) -> Color {
        guard isEnabled else {
            return Color.white.opacity(0.045)
        }
        return isSelected ? activeStepColor.opacity(0.20) : Color.white.opacity(0.055)
    }

    private func progressValue(viewModel: FlashViewModel) -> Double {
        if let importProgress = displayedFirmwareImportProgress(viewModel: viewModel) {
            return importProgress.progress
        }
        if case .completed = viewModel.state, !didCompleteFlash(viewModel: viewModel) {
            return 0
        }
        return progressValue(viewModel.state)
    }

    private func progressValue(_ state: FlashSessionState) -> Double {
        switch state {
        case .idle, .preparingFirmware, .connecting, .handshaking, .readingPIT:
            return 0
        case .flashing(_, let progress):
            return min(max(progress, 0), 1)
        case .finishing:
            return 0.98
        case .completed:
            return 1
        case .failed:
            return 0
        }
    }

    private func importProgressPercent(_ progress: FirmwareImportProgress) -> Int {
        Int((progress.progress * 100).rounded())
    }

    private func progressPercent(_ state: FlashSessionState) -> Int {
        Int(progressValue(state) * 100)
    }

    private func progressTrailingText(viewModel: FlashViewModel) -> String? {
        if let importProgress = displayedFirmwareImportProgress(viewModel: viewModel) {
            return importProgress.isFailed ? "Échec" : "\(importProgressPercent(importProgress))%"
        }

        switch viewModel.state {
        case .completed where didCompleteFlash(viewModel: viewModel):
            return "\(progressPercent(viewModel.state))%"
        case .flashing, .finishing:
            if let flashRemainingTimeText = viewModel.flashRemainingTimeText {
                return "\(progressPercent(viewModel.state))% · \(flashRemainingTimeText)"
            }
            return "\(progressPercent(viewModel.state))%"
        case .failed:
            return "Échec"
        case .idle, .preparingFirmware, .connecting, .handshaking, .readingPIT, .completed:
            return nil
        }
    }

    private func stageText(viewModel: FlashViewModel) -> String {
        if let importProgress = displayedFirmwareImportProgress(viewModel: viewModel) {
            return importProgress.message
        }

        switch viewModel.state {
        case .idle:
            return "Prêt"
        case .preparingFirmware:
            return "Décompression / préparation"
        case .connecting:
            return "Connexion au téléphone"
        case .handshaking:
            return "Handshake Odin"
        case .readingPIT:
            return "Lecture PIT"
        case .flashing(let partition, _):
            return "Flash \(partition)"
        case .finishing:
            return "Finalisation"
        case .completed:
            return completedOperationText(viewModel: viewModel)
        case .failed:
            return "Flash interrompu"
        }
    }

    private func stageColor(viewModel: FlashViewModel) -> Color {
        if let importProgress = displayedFirmwareImportProgress(viewModel: viewModel) {
            if importProgress.isFailed {
                return .red
            }
            if importProgress.isComplete {
                return Color(red: 0.28, green: 0.82, blue: 0.94)
            }
            return .white.opacity(0.82)
        }

        switch viewModel.state {
        case .failed:
            return .red
        case .completed where didCompleteFlash(viewModel: viewModel):
            return completedStepColor
        case .completed:
            return activeStepColor
        default:
            return .white.opacity(0.82)
        }
    }

    private func progressTint(viewModel: FlashViewModel) -> Color {
        if let importProgress = displayedFirmwareImportProgress(viewModel: viewModel), importProgress.isFailed {
            return .red
        }

        switch viewModel.state {
        case .failed:
            return .red
        case .completed where didCompleteFlash(viewModel: viewModel):
            return completedStepColor
        case .completed:
            return activeStepColor
        default:
            return activeStepColor
        }
    }

    private func progressStatusDotColor(viewModel: FlashViewModel) -> Color {
        if let importProgress = displayedFirmwareImportProgress(viewModel: viewModel) {
            return importProgress.isFailed ? .red : Color(red: 0.28, green: 0.82, blue: 0.94)
        }

        switch viewModel.state {
        case .failed:
            return .red
        case .completed where didCompleteFlash(viewModel: viewModel):
            return completedStepColor
        case .completed:
            return activeStepColor
        case .preparingFirmware, .connecting, .handshaking, .readingPIT, .flashing, .finishing:
            return activeStepColor
        default:
            return .white.opacity(0.36)
        }
    }

    private func didCompleteFlash(viewModel: FlashViewModel) -> Bool {
        if case .completed = viewModel.state {
            return viewModel.completedOperation == .flash
        }
        return false
    }

    private func completedOperationText(viewModel: FlashViewModel) -> String {
        switch viewModel.completedOperation {
        case .flash:
            return "Flash terminé avec succès"
        case .odinTest:
            return "Connexion Odin validée"
        case .pitRead:
            return "PIT chargé"
        case .exitDownloadMode:
            return "Téléphone sorti du mode Download"
        case .none:
            return "Terminé"
        }
    }

    private func displayedFirmwareImportProgress(viewModel: FlashViewModel) -> FirmwareImportProgress? {
        if viewModel.isImportingFirmware {
            return viewModel.firmwareImportProgress
                ?? FirmwareImportProgress(message: "Analyse du firmware", progress: 0.02)
        }
        guard case .idle = viewModel.state else {
            return nil
        }
        guard let progress = viewModel.firmwareImportProgress,
              progress.isComplete || progress.isFailed else {
            return nil
        }
        return progress
    }

    private func flashSummaryText(viewModel: FlashViewModel) -> String {
        let selectedCount = viewModel.selectedFirmwareMappings.count
        let selectedSize = ByteCountFormatter.string(
            fromByteCount: Int64(clamping: viewModel.selectedFlashSize),
            countStyle: .file
        )
        return "\(selectedCount) images, \(selectedSize)"
    }

    private func firmwareCompatibilityStatusColor(viewModel: FlashViewModel) -> Color {
        if !viewModel.firmwareCompatibilityErrors.isEmpty {
            return .red
        }
        if !viewModel.firmwareCompatibilityWarnings.isEmpty {
            return .orange
        }
        if !viewModel.firmwareModelCodes.isEmpty
            && (viewModel.normalizedExpectedDeviceModelCode != nil
                || viewModel.detectedDeviceModelCode != nil
                || viewModel.normalizedCurrentBootloaderRevision != nil) {
            return .green
        }
        return .secondary
    }

    private func reportIssue(viewModel: FlashViewModel) {
        var components = URLComponents(string: "https://github.com/hadrien500/FlashPort/issues/new")!
        components.queryItems = [
            URLQueryItem(name: "template", value: "rapport-de-flash.yml"),
            URLQueryItem(name: "version", value: "\(appVersionText)"),
            URLQueryItem(
                name: "telephone",
                value: viewModel.connectedDeviceDescription
                    ?? viewModel.detectedDeviceModelCode
                    ?? ""
            ),
            URLQueryItem(name: "firmware", value: viewModel.importedFirmwareSourceName ?? "")
        ]

        if let url = components.url {
            NSWorkspace.shared.open(url)
        }
    }

    private func handleFirmwareDrop(_ providers: [NSItemProvider], viewModel: FlashViewModel) -> Bool {
        guard !viewModel.isImportingFirmware,
              let provider = providers.first(where: { $0.canLoadObject(ofClass: URL.self) }) else {
            return false
        }

        _ = provider.loadObject(ofClass: URL.self) { url, _ in
            guard let url else { return }
            DispatchQueue.main.async {
                guard !viewModel.isImportingFirmware else { return }
                viewModel.importFirmwareBundle(url)
            }
        }
        return true
    }

    private func selectRecoveryImage(viewModel: FlashViewModel) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.title = "Choisir un recovery et son vbmeta (.img, .tar) ou un dossier"
        panel.message = "Sélectionne le recovery TWRP, et le vbmeta patché si nécessaire, ou le dossier qui les contient."
        panel.prompt = "Choisir"
        panel.allowedContentTypes = [.data, .folder]
        if panel.runModal() == .OK, !panel.urls.isEmpty {
            viewModel.importRecoveryImages(panel.urls)
        }
    }

    private func selectFirmwareBundle() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.title = "Importer un firmware Samsung"
        panel.prompt = "Importer"
        if panel.runModal() == .OK, let url = panel.url {
            viewModel.importFirmwareBundle(url)
        }
    }

    private func exportSessionReport(viewModel: FlashViewModel) {
        saveTextFile(
            defaultName: "FlashPort-Rapport-\(exportDateSlug()).txt",
            text: viewModel.sessionReportText()
        )
    }

    private func exportPit(viewModel: FlashViewModel) {
        saveTextFile(
            defaultName: "FlashPort-PIT-\(exportDateSlug()).csv",
            text: viewModel.pitExportText()
        )
    }

    private func saveTextFile(defaultName: String, text: String) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = defaultName
        panel.canCreateDirectories = true
        panel.title = "Exporter"
        panel.prompt = "Exporter"
        if panel.runModal() == .OK, let url = panel.url {
            try? text.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    private func exportDateSlug() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: Date())
    }

    private var appVersionText: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String

        switch (version, build) {
        case let (.some(version), .some(build)):
            return "\(version) (\(build))"
        case let (.some(version), .none):
            return version
        case let (.none, .some(build)):
            return build
        case (.none, .none):
            return "1.0.0"
        }
    }

    private var appDescriptionText: String {
        "FlashPort permet d’importer, analyser et flasher des firmwares Samsung compatibles depuis macOS. L’application détecte automatiquement les appareils en mode Download, affiche les informations du firmware, prend en charge les archives BL/AP/CP/CSC et guide le flash jusqu’au redémarrage."
    }

    private var appLatestChanges: [String] {
        [
            "L'app signale automatiquement les nouvelles versions publiées sur GitHub.",
            "Rapport de problème GitHub pré-rempli et contrôle de l'espace disque à l'import.",
            "Correctif : le firmware importé n'est plus marqué « À vérifier » avant la lecture du PIT."
        ]
    }

    private var appKeyFeatures: [(icon: String, text: String)] {
        [
            ("bolt.fill", "Moteur Odin natif Swift, images de plus de 4 Go"),
            ("externaldrive.fill.badge.checkmark", "Conservation des données (download-list Odin)"),
            ("checkmark.shield.fill", "Contrôles modèle, binary et anti-downgrade"),
            ("number.circle.fill", "Vérification MD5 des archives à l'import"),
            ("tablecells", "Lecture PIT automatique quand nécessaire"),
            ("doc.text.fill", "Journal détaillé et export de rapport")
        ]
    }
}

private enum AdvancedTab: Hashable {
    case settings
    case logs
}

private enum InterfaceMode: String, CaseIterable, Identifiable {
    case guided
    case expert

    var id: String { rawValue }

    var title: String {
        switch self {
        case .guided:
            return "Guidé"
        case .expert:
            return "Expert"
        }
    }
}

private enum WorkflowStepTone {
    case firmware
    case device
    case flash

    var accent: Color {
        switch self {
        case .firmware:
            return Color(red: 0.28, green: 0.82, blue: 0.94)
        case .device:
            return Color(red: 0.50, green: 0.68, blue: 1.0)
        case .flash:
            return Color(red: 1.0, green: 0.57, blue: 0.18)
        }
    }

    var badgeForeground: Color {
        switch self {
        case .firmware:
            return Color(red: 0.04, green: 0.16, blue: 0.20)
        case .device:
            return Color(red: 0.06, green: 0.10, blue: 0.22)
        case .flash:
            return Color(red: 0.18, green: 0.09, blue: 0.02)
        }
    }
}

private enum WorkflowStepStatus {
    case pending
    case active
    case ready
    case complete
    case warning
    case error

    var title: String {
        switch self {
        case .pending:
            return "En attente"
        case .active:
            return "En cours"
        case .ready:
            return "Prêt"
        case .complete:
            return "Valide"
        case .warning:
            return "À vérifier"
        case .error:
            return "Échec"
        }
    }

    var icon: String {
        switch self {
        case .pending:
            return "circle"
        case .active:
            return "arrow.triangle.2.circlepath"
        case .ready:
            return "checkmark.circle"
        case .complete:
            return "checkmark.circle.fill"
        case .warning:
            return "exclamationmark.triangle.fill"
        case .error:
            return "xmark.circle.fill"
        }
    }

}

private struct FlashActionButtonStyle: ButtonStyle {
    let isPrimary: Bool
    var isEnabled = true

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(foregroundColor)
            .background(backgroundColor(configuration: configuration))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(borderColor, lineWidth: 1)
            )
            .opacity(configuration.isPressed ? 0.86 : 1)
    }

    private func backgroundColor(configuration: Configuration) -> Color {
        guard isEnabled else {
            return Color.white.opacity(0.035)
        }

        if isPrimary {
            return configuration.isPressed
                ? Color(red: 0.06, green: 0.54, blue: 0.66)
                : Color(red: 0.08, green: 0.62, blue: 0.76)
        }
        return Color.white.opacity(configuration.isPressed ? 0.12 : 0.08)
    }

    private var foregroundColor: Color {
        guard isEnabled else {
            return .white.opacity(0.34)
        }

        return isPrimary ? .white : .white.opacity(0.68)
    }

    private var borderColor: Color {
        if !isEnabled {
            return Color.white.opacity(0.06)
        }
        return isPrimary ? Color.white.opacity(0.16) : Color.white.opacity(0.10)
    }
}

#Preview {
    ContentView()
}
