import Testing
@testable import OmarchyVMHelper

@Suite("Start menu presentation")
struct StartMenuPresentationTests {
    @Test("the reset notice describes actual compatibility failures, not app updates")
    func incompatibleWorkspaceNotice() {
        let detail = StartMenuPresentation.incompatibleWorkspaceDetail
        #expect(detail.contains("storage or boot format"))
        #expect(detail.contains("multiple saved VMs"))
        #expect(detail.contains("permanently erases"))
        #expect(!detail.contains("different Try Roguix build"))
    }

    @Test("microphone permission states offer only valid actions")
    func microphoneStates() {
        let authorized = StartMenuPresentation.microphone(
            state: .authorized,
            requestInFlight: false
        )
        #expect(authorized.isGranted)
        #expect(authorized.action == nil)
        #expect(authorized.actionTitle == nil)

        let undecided = StartMenuPresentation.microphone(
            state: .notDetermined,
            requestInFlight: false
        )
        #expect(!undecided.isGranted)
        #expect(undecided.action == .request)
        #expect(undecided.actionTitle == "Allow…")
        #expect(undecided.detail.contains("Optional"))

        let waiting = StartMenuPresentation.microphone(
            state: .notDetermined,
            requestInFlight: true
        )
        #expect(waiting.action == .request)
        #expect(waiting.actionTitle == "Waiting…")

        let denied = StartMenuPresentation.microphone(
            state: .denied,
            requestInFlight: false
        )
        #expect(denied.action == .openSettings)
        #expect(denied.actionTitle == "Open Settings")
        #expect(denied.detail.contains("Speaker playback will still work"))

        let restricted = StartMenuPresentation.microphone(
            state: .restricted,
            requestInFlight: false
        )
        #expect(!restricted.isGranted)
        #expect(restricted.action == nil)
        #expect(restricted.actionTitle == nil)
    }

    @Test("camera permission states keep camera access optional and recoverable")
    func cameraStates() {
        let authorized = StartMenuPresentation.camera(
            state: .authorized,
            requestInFlight: false
        )
        #expect(authorized.isGranted)
        #expect(authorized.action == nil)

        let undecided = StartMenuPresentation.camera(
            state: .notDetermined,
            requestInFlight: false
        )
        #expect(undecided.action == .request)
        #expect(undecided.actionTitle == "Allow…")
        #expect(undecided.detail.contains("Optional"))

        let waiting = StartMenuPresentation.camera(
            state: .notDetermined,
            requestInFlight: true
        )
        #expect(waiting.actionTitle == "Waiting…")

        let denied = StartMenuPresentation.camera(
            state: .denied,
            requestInFlight: false
        )
        #expect(denied.action == .openSettings)
        #expect(denied.actionTitle == "Open Settings")

        let restricted = StartMenuPresentation.camera(
            state: .restricted,
            requestInFlight: false
        )
        #expect(!restricted.isGranted)
        #expect(restricted.action == nil)
    }

    @Test("shared folder states distinguish absent, disabled, enabled, and broken shares")
    func sharedFolderStates() {
        let absent = StartMenuPresentation.sharedFolder(state: .disabled)
        #expect(!absent.isGranted)
        #expect(absent.compactDetailLines == nil)
        #expect(absent.toggleActionTitle == nil)

        let disabled = StartMenuPresentation.sharedFolder(
            state: SharedFolderMenuState(
                path: "/Users/test/Projects/demo",
                displayPath: "~/Projects/demo",
                isEnabled: false,
                problem: nil
            )
        )
        #expect(!disabled.isGranted)
        #expect(disabled.compactDetailLines == [
            "Mac folder: ~/Projects/demo",
            "In Roguix: Off",
        ])
        #expect(disabled.toggleActionTitle == "Turn On")

        let enabled = StartMenuPresentation.sharedFolder(
            state: SharedFolderMenuState(
                path: "/Users/test/Projects/demo",
                displayPath: "~/Projects/demo",
                isEnabled: true,
                problem: nil
            )
        )
        #expect(enabled.isGranted)
        #expect(enabled.compactDetailLines == [
            "Mac folder: ~/Projects/demo",
            "In Roguix: ~/demo",
        ])
        #expect(enabled.toggleActionTitle == "Turn Off")

        let broken = StartMenuPresentation.sharedFolder(
            state: SharedFolderMenuState(
                path: "/Volumes/Missing/demo",
                displayPath: "/Volumes/Missing/demo",
                isEnabled: true,
                problem: "The selected folder is unavailable."
            )
        )
        #expect(!broken.isGranted)
        #expect(broken.detail == "The selected folder is unavailable.")
        #expect(broken.compactDetailLines == nil)
        #expect(broken.toggleActionTitle == "Turn Off")
    }

    @Test("port summary covers empty, single, and multiple mappings")
    func portForwardingStates() {
        let empty = StartMenuPresentation.portForwarding(mappings: [])
        #expect(!empty.isGranted)
        #expect(empty.compactDetailLines == nil)

        let single = StartMenuPresentation.portForwarding(mappings: [
            PortForwardMapping(hostPort: 2222, guestPort: 22, protocol: .tcp),
        ])
        #expect(single.isGranted)
        #expect(single.grantedStatusLabel == "●  1 Port")
        #expect(single.compactDetailLines == [
            "Mac: localhost:2222",
            "Roguix: port 22 · TCP",
        ])

        let multiple = StartMenuPresentation.portForwarding(mappings: [
            PortForwardMapping(hostPort: 8080, guestPort: 3000, protocol: .tcp),
            PortForwardMapping(hostPort: 5353, guestPort: 5353, protocol: .udp),
        ])
        #expect(multiple.isGranted)
        #expect(multiple.grantedStatusLabel == "●  2 Ports")
        #expect(multiple.compactDetailLines == [
            "2 localhost mappings",
            "Available only on this Mac",
        ])
    }

    @Test("immersive guidance distinguishes windowed and fullscreen launch")
    func immersiveGuidance() {
        #expect(StartMenuPresentation.immersiveDetail(isEnabled: true)
            == "Roguix opens Full Screen with the Mac menu bar and Dock hidden.")
        #expect(StartMenuPresentation.immersiveDetail(isEnabled: false)
            == "Roguix opens in a window with the Mac menu bar and Dock available.")
    }

    @Test("language presentation distinguishes the system default from a chosen locale")
    func languageStates() {
        let systemDefault = StartMenuPresentation.language(state: .systemDefault)
        #expect(!systemDefault.isNonDefault)
        #expect(systemDefault.statusLabel == "○  English")
        #expect(systemDefault.detail.contains("English"))
        #expect(systemDefault.actionTitle.contains("繁體中文"))

        let traditionalChinese = StartMenuPresentation.language(
            state: LanguageMenuState(selectedLocale: GuestLocaleCatalog.traditionalChinese)
        )
        #expect(traditionalChinese.isNonDefault)
        #expect(traditionalChinese.statusLabel == "●  Traditional Chinese (繁體中文)")
        #expect(traditionalChinese.detail.contains("Traditional Chinese"))
        #expect(traditionalChinese.actionTitle == "Use English (Default)")
    }
}
