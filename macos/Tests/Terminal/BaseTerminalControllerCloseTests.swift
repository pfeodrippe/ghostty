import Testing
@testable import Ghostty

struct BaseTerminalControllerCloseTests {
    @Test(arguments: [
        (false, false, false),
        (false, true, true),
        (true, false, false),
        (true, true, false),
    ])
    func shouldConfirmSurfaceClose(
        processExited: Bool,
        notifiedProcessAlive: Bool,
        expected: Bool
    ) {
        #expect(
            BaseTerminalController.shouldConfirmSurfaceClose(
                processExited: processExited,
                notifiedProcessAlive: notifiedProcessAlive
            ) == expected
        )
    }
}
