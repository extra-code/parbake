// SPDX-FileCopyrightText: 2026 Christian Semmelmann
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing
import Virtualization

@testable import RuntimeMacOS

/// An error that names itself as its underlying error.
///
/// `NSError` is `@unchecked Sendable`, and a subclass must restate it; this one adds no stored state.
private final class SelfWrappingError: NSError, @unchecked Sendable {
    override var userInfo: [String: Any] { [NSUnderlyingErrorKey: self] }
}

struct MacOSVirtualMachineTests {
    @Test
    func testTheVMLimitMapsToVMLimitReached() {
        let mapped = MacOSVirtualMachine.mapStartError(VZError(.virtualMachineLimitExceeded))
        #expect(mapped as? RuntimeFailure == .vmLimitReached)
    }

    @Test
    func testAWrappedVMLimitMapsToVMLimitReached() {
        let outer = NSError(domain: VZError.errorDomain, code: VZError.Code.internalError.rawValue, userInfo: [NSUnderlyingErrorKey: VZError(.virtualMachineLimitExceeded)])
        #expect(MacOSVirtualMachine.mapStartError(outer) as? RuntimeFailure == .vmLimitReached)
    }

    @Test
    func testALockContentionErrorIsReturnedUnchanged() {
        let inner = NSError(domain: NSPOSIXErrorDomain, code: Int(EAGAIN))
        let outer = NSError(domain: VZError.errorDomain, code: VZError.Code.internalError.rawValue, userInfo: [NSUnderlyingErrorKey: inner])
        let mapped = MacOSVirtualMachine.mapStartError(outer)
        #expect(mapped as? RuntimeFailure == nil)
        #expect((mapped as NSError) === outer)
        #expect(MacOSVirtualMachine.isLockContention(mapped))
    }

    @Test
    func testOtherVZErrorsAreReturnedUnchanged() {
        let error = VZError(.invalidVirtualMachineConfiguration)
        let mapped = MacOSVirtualMachine.mapStartError(error)
        #expect(mapped as? RuntimeFailure == nil)
        #expect((mapped as? VZError)?.code == .invalidVirtualMachineConfiguration)
    }

    @Test
    func testAnErrorThatWrapsItselfEndsTheWalk() {
        let error = SelfWrappingError(domain: "test", code: 1)
        #expect(!MacOSVirtualMachine.isLockContention(error))
        #expect(MacOSVirtualMachine.mapStartError(error) as? RuntimeFailure == nil)
    }
}
