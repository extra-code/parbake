// SPDX-FileCopyrightText: 2026 Christian Semmelmann
// SPDX-License-Identifier: Apache-2.0

import Darwin
import Foundation
import Testing

@testable import RuntimeMacOS

struct BundlePathPolicyTests {
    private let base: URL

    init() throws {
        let raw = FileManager.default.temporaryDirectory.appendingPathComponent("bpp-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: raw, withIntermediateDirectories: true)
        guard let resolved = realpath(raw.path, nil) else { throw POSIXError(.ENOENT) }
        defer { free(resolved) }
        base = URL(fileURLWithPath: String(cString: resolved))
    }

    private func makeHome(_ name: String = "home") throws -> URL {
        let home = base.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
        return home
    }

    @discardableResult
    private func makeBundle(in directory: URL, name: String = "VM.bundle", mode: Int = 0o755) throws -> URL {
        let bundle = directory.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true, attributes: [.posixPermissions: mode])
        try Data("x".utf8).write(to: bundle.appendingPathComponent("Disk.img"))
        try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: bundle.path)
        return bundle
    }

    @Test
    func testAcceptsABundleUnderHomeAndReturnsItCanonical() throws {
        let home = try makeHome()
        let bundle = try makeBundle(in: home)
        let policy = try BundlePathPolicy(home: home)
        #expect(try policy.validate(bundle.path).path == bundle.path)
        #expect(policy.roots.first?.path == home.path)
    }

    @Test
    func testRefusesASymlinkToABundleOutsideTheRoots() throws {
        let home = try makeHome()
        let outside = try makeBundle(in: try makeHome("elsewhere"))
        let link = home.appendingPathComponent("link.bundle")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        let policy = try BundlePathPolicy(home: home)
        #expect(throws: BundlePathError.outsideRoots(path: outside.path, roots: [home.path])) { try policy.validate(link.path) }
    }

    @Test
    func testRefusesDotDotEscapingTheRoot() throws {
        let home = try makeHome()
        let outside = try makeBundle(in: try makeHome("elsewhere"))
        let policy = try BundlePathPolicy(home: home)
        let escaping = home.path + "/../elsewhere/" + outside.lastPathComponent
        #expect(throws: BundlePathError.outsideRoots(path: outside.path, roots: [home.path])) { try policy.validate(escaping) }
    }

    @Test
    func testComparesRootsByPathComponents() throws {
        let a = try makeHome("a")
        let ab = try makeHome("ab")
        let bundle = try makeBundle(in: ab)
        let policy = try BundlePathPolicy(home: a)
        do {
            _ = try policy.validate(bundle.path)
            Issue.record("expected outsideRoots")
        } catch let error as BundlePathError {
            guard case .outsideRoots = error else {
                Issue.record("got \(error)")
                return
            }
        }
    }

    @Test
    func testRefusesAWorldWritableBundle() throws {
        let home = try makeHome()
        let bundle = try makeBundle(in: home, mode: 0o777)
        let policy = try BundlePathPolicy(home: home)
        #expect(throws: BundlePathError.writableByOthers(path: bundle.path)) { try policy.validate(bundle.path) }
    }

    @Test
    func testNamesTheBundleDirectoryForAWrongOwner() throws {
        let home = try makeHome()
        let bundle = try makeBundle(in: home)
        let policy = try BundlePathPolicy(home: home, uid: getuid() + 1)
        #expect(throws: BundlePathError.wrongOwner(path: bundle.path)) { try policy.validate(bundle.path) }
    }

    @Test
    func testRefusesALayoutLinkOutsideTheRoots() throws {
        let home = try makeHome()
        let bundle = try makeBundle(in: home)
        try FileManager.default.removeItem(at: bundle.appendingPathComponent("Disk.img"))
        try FileManager.default.createSymbolicLink(at: bundle.appendingPathComponent("Disk.img"), withDestinationURL: URL(fileURLWithPath: "/etc/hosts"))
        let policy = try BundlePathPolicy(home: home)
        do {
            _ = try policy.validate(bundle.path)
            Issue.record("expected linkOutsideRoots")
        } catch let error as BundlePathError {
            guard case .linkOutsideRoots = error else {
                Issue.record("got \(error)")
                return
            }
        }
    }

    @Test
    func testARootsFileAdmitsAnExtraRoot() throws {
        let home = try makeHome()
        let extra = try makeHome("extra")
        let bundle = try makeBundle(in: extra)
        let file = BundlePathPolicy.defaultRootsFile(home: home)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("# extra root\n\n\(extra.path)\n".utf8).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        let policy = try BundlePathPolicy(home: home)
        #expect(try policy.validate(bundle.path).path == bundle.path)
    }

    @Test
    func testAGroupWritableRootsFileIsBad() throws {
        let home = try makeHome()
        let file = BundlePathPolicy.defaultRootsFile(home: home)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("\(home.path)\n".utf8).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o660], ofItemAtPath: file.path)
        do {
            _ = try BundlePathPolicy(home: home)
            Issue.record("expected badRootsFile")
        } catch let error as BundlePathError {
            guard case .badRootsFile = error else {
                Issue.record("got \(error)")
                return
            }
        }
    }

    @Test(arguments: ["relative/VM.bundle", "~/VM.bundle", "", "VM.bundle"])
    func testRefusesANonAbsoluteLabel(label: String) throws {
        let policy = try BundlePathPolicy(home: try makeHome())
        #expect(throws: BundlePathError.notAbsolute(label)) { try policy.validate(label) }
    }

    @Test
    func testAMissingPathIsBundleMissing() throws {
        let home = try makeHome()
        let policy = try BundlePathPolicy(home: home)
        let path = home.appendingPathComponent("nope.bundle").path
        #expect(throws: RuntimeFailure.bundleMissing(path: path, missing: nil)) { try policy.validate(path) }
    }

    @Test
    func testARelativeRootsFileLineIsBad() throws {
        let home = try makeHome()
        let file = BundlePathPolicy.defaultRootsFile(home: home)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("relative/dir\n".utf8).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        let message = "line 1: relative/dir is not an absolute path"
        #expect(throws: BundlePathError.badRootsFile(path: file.path, reason: message)) { try BundlePathPolicy(home: home) }
    }

    @Test
    func testAMissingRootsFileDirectoryIsBad() throws {
        let home = try makeHome()
        let file = BundlePathPolicy.defaultRootsFile(home: home)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("\(base.path)/missing\n".utf8).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        #expect(throws: BundlePathError.self) { try BundlePathPolicy(home: home) }
    }

    @Test
    func testARootsFileOwnedByAnotherUserIsBad() throws {
        let home = try makeHome()
        let file = BundlePathPolicy.defaultRootsFile(home: home)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("\(home.path)\n".utf8).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        #expect(throws: BundlePathError.self) { try BundlePathPolicy(home: home, uid: getuid() + 1) }
    }

    @Test
    func testALayoutLinkInsideTheRootsIsAccepted() throws {
        let home = try makeHome()
        let bundle = try makeBundle(in: home)
        let target = home.appendingPathComponent("real.img")
        try Data("x".utf8).write(to: target)
        try FileManager.default.removeItem(at: bundle.appendingPathComponent("Disk.img"))
        try FileManager.default.createSymbolicLink(at: bundle.appendingPathComponent("Disk.img"), withDestinationURL: target)
        let policy = try BundlePathPolicy(home: home)
        #expect(try policy.validate(bundle.path).path == bundle.path)
    }

    @Test
    func testAWorldWritableLayoutFileIsRefused() throws {
        let home = try makeHome()
        let bundle = try makeBundle(in: home)
        let disk = bundle.appendingPathComponent("Disk.img")
        try FileManager.default.setAttributes([.posixPermissions: 0o666], ofItemAtPath: disk.path)
        let policy = try BundlePathPolicy(home: home)
        #expect(throws: BundlePathError.writableByOthers(path: disk.path)) { try policy.validate(bundle.path) }
    }

    @Test
    func testOutsideRootsNamesTheRootsFile() {
        let text = BundlePathError.outsideRoots(path: "/x", roots: ["/h"]).description
        #expect(text.contains("bundle-roots"))
    }

    @Test
    func testASymlinkedRootIsCanonicalAndAdmitsItsBundles() throws {
        let real = try makeHome("real")
        let bundle = try makeBundle(in: real)
        let link = base.appendingPathComponent("home-link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        let policy = try BundlePathPolicy(home: link)
        #expect(policy.roots.map(\.path) == [real.path])
        #expect(try policy.validate(link.path + "/" + bundle.lastPathComponent).path == bundle.path)
    }

    @Test
    func testASlashRootAdmitsEveryPath() throws {
        let home = try makeHome()
        let outside = try makeBundle(in: try makeHome("elsewhere"))
        let file = BundlePathPolicy.defaultRootsFile(home: home)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("/\n".utf8).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        let policy = try BundlePathPolicy(home: home)
        #expect(policy.roots.map(\.path) == [home.path, "/"])
        #expect(try policy.validate(outside.path).path == outside.path)
    }

    @Test
    func testABundleEqualToARootIsAccepted() throws {
        let home = try makeHome()
        try Data("x".utf8).write(to: home.appendingPathComponent("Disk.img"))
        let policy = try BundlePathPolicy(home: home)
        #expect(try policy.validate(home.path).path == home.path)
    }

    @Test
    func testALayerLinkOutsideTheRootsIsRefused() throws {
        let home = try makeHome()
        let bundle = try makeBundle(in: home)
        let outside = try makeHome("elsewhere").appendingPathComponent("Layer.asif")
        try Data("x".utf8).write(to: outside)
        let layer = bundle.appendingPathComponent("Layer.asif")
        try FileManager.default.createSymbolicLink(at: layer, withDestinationURL: outside)
        let policy = try BundlePathPolicy(home: home)
        #expect(throws: BundlePathError.linkOutsideRoots(file: layer.path, target: outside.path)) { try policy.validate(bundle.path) }
    }
}
