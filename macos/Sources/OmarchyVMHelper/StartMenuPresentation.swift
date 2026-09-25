import Foundation

enum StartMenuPermissionAction: Equatable {
    case request
    case openSettings
}

struct StartMenuPermissionPresentation: Equatable {
    let detail: String
    let isGranted: Bool
    let actionTitle: String?
    let action: StartMenuPermissionAction?
}

struct StartMenuSharedFolderPresentation: Equatable {
    let detail: String
    let compactDetailLines: [String]?
    let isGranted: Bool
    let toggleActionTitle: String?
}

struct StartMenuMemoryPresentation: Equatable {
    let detail: String
    /// The MiB value behind each popup entry, in display order.
    let choicesMiB: [Int]
    let choiceTitles: [String]
    let selectedIndex: Int
    /// False when this Mac's RAM fits only the default, so the popup renders
    /// disabled rather than offering a single-item "choice".
    let isAdjustable: Bool
}

struct StartMenuPortForwardingPresentation: Equatable {
    let detail: String
    let compactDetailLines: [String]?
    let isGranted: Bool
    let grantedStatusLabel: String
}

struct StartMenuLanguagePresentation: Equatable {
    let detail: String
    /// True once a non-default guest locale is selected. Only affects the
    /// row's status dot color, mirroring how `sharedFolder` and
    /// `portForwarding` treat "the optional setting is turned on."
    let isNonDefault: Bool
    let statusLabel: String
    let actionTitle: String
}

/// Pure presentation rules for the start menu. Keeping user-visible state out
/// of AppKit makes the important behavior testable without relying on window
/// positions, font metrics, run-loop timing, or the current display size.
enum StartMenuPresentation {
    static func resources(_ resources: VMResources) -> String {
        "\(resources.cpuCount) processor cores · \(resources.memoryGiB) GiB memory"
            + (resources.diskGiB.map { " · \($0) GiB disk" } ?? "")
    }

    static let incompatibleWorkspaceDetail = "The saved VM uses a storage or boot format this version can’t use, or its data folder contains multiple saved VMs. Reset Roguix to create a compatible VM. Resetting permanently erases everything in the VM."

    static func microphone(
        state: MicrophoneAuthorizationState,
        requestInFlight: Bool
    ) -> StartMenuPermissionPresentation {
        switch state {
        case .authorized:
            StartMenuPermissionPresentation(
                detail: "Apps in Roguix can record from your Mac microphone.",
                isGranted: true,
                actionTitle: nil,
                action: nil
            )
        case .notDetermined:
            StartMenuPermissionPresentation(
                detail: "Optional. Speaker playback works without microphone access.",
                isGranted: false,
                actionTitle: requestInFlight ? "Waiting…" : "Allow…",
                action: .request
            )
        case .denied:
            StartMenuPermissionPresentation(
                detail: "Recording is off. Speaker playback will still work.",
                isGranted: false,
                actionTitle: "Open Settings",
                action: .openSettings
            )
        case .restricted:
            StartMenuPermissionPresentation(
                detail: "Recording is unavailable because of this Mac’s policy.",
                isGranted: false,
                actionTitle: nil,
                action: nil
            )
        }
    }

    static func camera(
        state: CameraAuthorizationState,
        requestInFlight: Bool
    ) -> StartMenuPermissionPresentation {
        switch state {
        case .authorized:
            StartMenuPermissionPresentation(
                detail: "Apps in Roguix can use your Mac camera while they are recording.",
                isGranted: true,
                actionTitle: nil,
                action: nil
            )
        case .notDetermined:
            StartMenuPermissionPresentation(
                detail: "Optional. The camera turns on only while a Roguix app uses it.",
                isGranted: false,
                actionTitle: requestInFlight ? "Waiting…" : "Allow…",
                action: .request
            )
        case .denied:
            StartMenuPermissionPresentation(
                detail: "The Mac camera is off inside Roguix.",
                isGranted: false,
                actionTitle: "Open Settings",
                action: .openSettings
            )
        case .restricted:
            StartMenuPermissionPresentation(
                detail: "Camera access is unavailable because of this Mac’s policy.",
                isGranted: false,
                actionTitle: nil,
                action: nil
            )
        }
    }

    static func sharedFolder(
        state: SharedFolderMenuState
    ) -> StartMenuSharedFolderPresentation {
        let detail: String
        let compactDetailLines: [String]?
        if let problem = state.problem {
            detail = problem
            compactDetailLines = nil
        } else if let displayPath = state.displayPath, state.isEnabled {
            let guestPath = "~/\(SharedFolderPolicy.guestLinkName(state.path ?? displayPath))"
            detail = "Mac folder: \(displayPath). In Roguix: \(guestPath)."
            compactDetailLines = [
                "Mac folder: \(displayPath)",
                "In Roguix: \(guestPath)",
            ]
        } else if let displayPath = state.displayPath {
            detail = "Mac folder: \(displayPath). In Roguix: Off."
            compactDetailLines = [
                "Mac folder: \(displayPath)",
                "In Roguix: Off",
            ]
        } else {
            detail = "Optional. Pick a Mac folder to use inside Roguix under the same name."
            compactDetailLines = nil
        }

        return StartMenuSharedFolderPresentation(
            detail: detail,
            compactDetailLines: compactDetailLines,
            isGranted: state.isEnabled && state.problem == nil,
            toggleActionTitle: state.path == nil ? nil : (state.isEnabled ? "Turn Off" : "Turn On")
        )
    }

    static func portForwarding(
        mappings: [PortForwardMapping]
    ) -> StartMenuPortForwardingPresentation {
        if mappings.isEmpty {
            return StartMenuPortForwardingPresentation(
                detail: "Optional. Reach services running in Roguix at localhost on this Mac.",
                compactDetailLines: nil,
                isGranted: false,
                grantedStatusLabel: "●  0 Ports"
            )
        }
        if mappings.count == 1, let mapping = mappings.first {
            return StartMenuPortForwardingPresentation(
                detail: "localhost:\(mapping.hostPort) → "
                    + "Roguix:\(mapping.guestPort) · \(mapping.protocol.displayName)",
                compactDetailLines: [
                    "Mac: localhost:\(mapping.hostPort)",
                    "Roguix: port \(mapping.guestPort) · \(mapping.protocol.displayName)",
                ],
                isGranted: true,
                grantedStatusLabel: "●  1 Port"
            )
        }
        return StartMenuPortForwardingPresentation(
            detail: "\(mappings.count) localhost mappings. Available only on this Mac.",
            compactDetailLines: [
                "\(mappings.count) localhost mappings",
                "Available only on this Mac",
            ],
            isGranted: true,
            grantedStatusLabel: "●  \(mappings.count) Ports"
        )
    }

    static func memory(
        preferredMiB: Int,
        hostMemoryMiB: Int
    ) -> StartMenuMemoryPresentation {
        let choices = MemoryPolicy.allowedChoicesMiB(hostMemoryMiB: hostMemoryMiB)
        let selected = MemoryPolicy.resolvedMemoryMiB(
            preferredMiB: preferredMiB,
            hostMemoryMiB: hostMemoryMiB
        )
        let titles = choices.map { choice in
            MemoryPolicy.choiceTitle(memoryMiB: choice, hostMemoryMiB: hostMemoryMiB)
        }
        let isAdjustable = choices.count > 1
        return StartMenuMemoryPresentation(
            detail: isAdjustable
                ? "Higher allocations may affect macOS performance. Applies on the next launch."
                : "This Mac’s memory fits the \(MemoryPolicy.displayLabel(memoryMiB: MemoryPolicy.defaultMemoryMiB)) default.",
            choicesMiB: choices,
            choiceTitles: titles,
            selectedIndex: choices.firstIndex(of: selected) ?? 0,
            isAdjustable: isAdjustable
        )
    }

    static func immersiveDetail(isEnabled: Bool) -> String {
        isEnabled
            ? "Roguix opens Full Screen with the Mac menu bar and Dock hidden."
            : "Roguix opens in a window with the Mac menu bar and Dock available."
    }

    static func language(state: LanguageMenuState) -> StartMenuLanguagePresentation {
        guard state.supportsSelection else {
            return StartMenuLanguagePresentation(
                detail: "This saved VM does not support language selection. Reset Roguix to use it; reset erases the VM’s data.",
                isNonDefault: false,
                statusLabel: "○  Requires reset",
                actionTitle: "Language unavailable"
            )
        }
        guard let selected = state.selectedLocale else {
            return StartMenuLanguagePresentation(
                detail: "Roguix boots in English, the guest’s default language.",
                isNonDefault: false,
                statusLabel: "○  English",
                actionTitle: "Switch to \(GuestLocaleCatalog.traditionalChinese.displayName)"
            )
        }
        return StartMenuLanguagePresentation(
            detail: "Roguix boots in \(selected.displayName).",
            isNonDefault: true,
            statusLabel: "●  \(selected.displayName)",
            actionTitle: "Use English (Default)"
        )
    }
}
