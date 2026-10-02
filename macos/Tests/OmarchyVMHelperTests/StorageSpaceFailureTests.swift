import Testing
@testable import OmarchyVMHelper

@Suite("Storage space failures")
struct StorageSpaceFailureTests {
    @Test("A disk-space refusal names the space needed and free")
    func spaceRefusal() throws {
        let output = """
            qemu-persistent-storage: not enough free space for the VM: 21545 MiB required, 14102 MiB available
            run-qemu-gpu: could not materialize the bundled root disk
            """
        let message = try #require(StorageSpaceFailure.message(standardError: output))
        #expect(message.contains("23 GB free"))
        #expect(message.contains("only 14 GB"))
        #expect(!message.contains("Reinstall"))
    }

    @Test("Other failures keep their own messages")
    func unrelated() {
        #expect(StorageSpaceFailure.message(standardError: "run-qemu-gpu: could not prepare the selected root disk") == nil)
    }
}
