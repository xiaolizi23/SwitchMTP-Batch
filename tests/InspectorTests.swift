// Checks the container inspector and the hactool output classifier against
// synthetic containers. Run with scripts/test-inspector.sh.
//
// These are structural checks only: the samples hold no Nintendo content, so
// nothing here can be verified against real signatures.

import Foundation

@main
struct InspectorTests {
    static var failures = 0

    static func expect(_ condition: Bool, _ label: String) {
        if condition {
            print("  ok   \(label)")
        } else {
            print("  FAIL \(label)")
            failures += 1
        }
    }

    static func main() throws {
        let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let samples = CommandLine.arguments.count > 1
            ? URL(fileURLWithPath: CommandLine.arguments[1])
            : directory.appendingPathComponent("build/test-samples")
        // Samples are synthetic and regenerable, so they are not tracked; generate
        // them first (scripts/test-inspector.sh does this and passes the path in).
        guard FileManager.default.fileExists(
            atPath: samples.appendingPathComponent("valid.nsp").path
        ) else {
            print("no samples at \(samples.path)")
            print("generate with: python3 tests/make_samples.py build/test-samples")
            exit(2)
        }

        func report(_ name: String) -> ContainerReport? {
            let url = samples.appendingPathComponent(name)
            guard let format = PackageFormat.from(url: url) else { return nil }
            return PackageInspector.inspect(url: url, format: format)
        }

        print("container inspection")

        if let r = report("valid.nsp") {
            expect(r.verdict == .unverified, "valid.nsp is structurally clean but unverified")
            expect(r.contentType == .base, "valid.nsp is a base title")
            expect(r.titleID == "0100000000010000", "valid.nsp title id")
            expect(r.ncaCount == 2, "valid.nsp counts the CNMT as an NCA")
            expect(r.hasCnmt && r.hasTicket, "valid.nsp has CNMT and ticket")
        } else { expect(false, "valid.nsp readable") }

        if let r = report("update.nsp") {
            expect(r.verdict == .unverified, "update.nsp is structurally clean but unverified")
            expect(r.contentType == .update, "update.nsp low 16 bits 0x0800 = update")
        } else { expect(false, "update.nsp readable") }

        if let r = report("dlc.nsp") {
            expect(r.contentType == .dlc, "dlc.nsp is DLC")
            expect(r.verdict == .unverified, "dlc.nsp is structurally clean but unverified")
        } else { expect(false, "dlc.nsp readable") }

        if let r = report("no_ticket.nsp") {
            expect(r.verdict == .unverified, "missing ticket stays unverified, not non-retail")
            expect(r.issues.contains { $0.title.contains("ticket") }, "missing ticket is explained")
        } else { expect(false, "no_ticket.nsp readable") }

        if let r = report("truncated.nsp") {
            expect(r.verdict == .blocked, "truncated.nsp is blocked")
            expect(r.issues.contains { $0.severity == .blocking }, "truncation has a blocking note")
        } else { expect(false, "truncated.nsp readable") }

        if let r = report("fake.nsp") {
            expect(r.verdict == .blocked, "fake.nsp is blocked")
            expect(!r.isStructurallySound, "fake.nsp cannot be sent")
        } else { expect(false, "fake.nsp readable") }

        if let r = report("tiny.nsp") {
            expect(r.verdict == .blocked, "tiny.nsp is blocked")
        } else { expect(false, "tiny.nsp readable") }

        if let r = report("compressed.nsp") {
            expect(r.compressedContent, "NCZ payload detected")
            expect(r.verdict == .unverified, "compressed payload is unverified, not caution")
        } else { expect(false, "compressed.nsp readable") }

        if let r = report("valid.xci") {
            expect(r.contentType == .base, "valid.xci is a base title")
            expect(r.titleID == "0100000000010000", "valid.xci title id comes from the secure partition")
            expect(r.ncaCount == 2, "valid.xci counts NCAs inside secure")
            expect(r.hasCnmt, "valid.xci sees the CNMT")
            expect(r.verdict == .unverified, "valid.xci is structurally clean but unverified")
        } else { expect(false, "valid.xci readable") }

        if let r = report("overlap.nsp") {
            expect(r.verdict == .blocked, "overlapping entries are blocked")
            expect(r.issues.contains { $0.title.contains("重叠") }, "overlap is explained")
        } else { expect(false, "overlap.nsp readable") }

        print("content type derivation")
        // Real retail IDs, where the four digits before ".cnmt.nca" are not
        // 0000. These are the cases that used to read as DLC.
        let types: [(String, PackageContentType, String)] = [
            ("01000000000AA000", .base, "retail base (…A000)"),
            ("01000000000AA800", .update, "retail update (…A800)"),
            ("01000000000AB001", .dlc, "retail add-on (…B001)"),
            ("01000000000BA000", .base, "second retail base (…B000)"),
            ("01000000000CC000", .base, "third retail base (…C000)"),
            ("0100000000010000", .base, "synthetic base (…0000)"),
            ("0100000000010800", .update, "synthetic patch (…0800)"),
            ("0100000000021000", .dlc, "synthetic add-on (…1000)"),
        ]
        for (titleID, expected, label) in types {
            expect(PackageInspector.contentType(for: titleID, fileName: "x.nsp") == expected,
                   "\(label) is \(expected.rawValue)")
        }
        expect(PackageInspector.isValidTitleID("01000000000AA000"), "retail title id accepted")
        expect(!PackageInspector.isValidTitleID("CC1324AA881AD518"), "content hash rejected as title id")

        print("title id from container names")
        // Real repacks hash the CNMT name and only the ticket carries the
        // title ID, as 32 hex digits. This is the case that left a 44-package
        // library with no title IDs, no covers and no base/update merging.
        expect(PackageInspector.titleIDFrom(names: ["ae1700a1629a87db70a11dc4c20ab4b0.cnmt.nca",
                                                    "01000000000dd8000000000000000011.tik"]) == "01000000000DD800",
               "32-hex ticket name yields the title id")
        expect(PackageInspector.titleIDFrom(names: ["01000000000AA0000000000000000000.tik"]) == "01000000000AA000",
               "zero-padded ticket name yields the title id")
        expect(PackageInspector.titleIDFrom(names: ["01000000000AA000.cnmt.nca",
                                                    "01000000000AC800.cnmt.nca"]) == "01000000000AA000",
               "CNMT name still wins over ticket")
        expect(PackageInspector.titleIDFromFileName("[本体v1.0.0][01000000000EE000][18.0.0][中文].xci") == "01000000000EE000",
               "release-name bracket is used for cartridge images")
        expect(PackageInspector.titleIDFromFileName("no-id-here.nsp") == nil, "name without title id yields nothing")

        print("display names")
        let names: [(String, String)] = [
            ("/tmp/samples/SampleGame/[本体v1.0.0][01000000000AA000][1.0.0][中文][US].nsp", "SampleGame"),
            ("/tmp/samples/SampleGame/DLC/[DLC][01000000000AB001][2.12.0][中文][US].nsp", "SampleGame"),
            ("/tmp/samples/Another Game/升级档-v1.1.0/[01000000000FF000][US][v131072][v1.1.0][UPD].nsz",
             "Another Game"),
            ("/tmp/samples/Third Title/nsp本体/Third Title - v1.0.0 [01000000000CC000][v0].nsp", "Third Title"),
            ("/tmp/samples/fixture/[本体v1.0.0][01000000000DD000][16.0.3][中文].nsp", "fixture"),
        ]
        for (path, expected) in names {
            let name = PackageInspector.displayName(for: URL(fileURLWithPath: path))
            expect(name == expected, "\(path.split(separator: "/").last!) names as \(expected) (got \(name))")
        }
        expect(PackageInspector.isGenericName("升级档-v1.1.0"), "version-only folder is generic")
        expect(PackageInspector.isGenericName("nsz本体"), "payload folder is generic")
        expect(PackageInspector.isGenericName("DLC"), "DLC folder is generic")
        expect(!PackageInspector.isGenericName("SampleGame"), "real title is not generic")

        print("deep-check classification")
        func block(_ body: String, keys: Int = 1) -> String {
            "NSP_NCA_BEGIN: a.nca\n\(body)\nNSP_NCA_END: a.nca\nNSP_RESULT: 1 nca(s), 0 skipped\nNSP_KEYSTATE: registered=\(keys) personalized=0"
        }
        let outputs: [(String, String, DeepCheckState)] = [
            ("keys", "Failed to read NCA header!\nInvalid NCA header! Are keys correct?\nDone!", .unavailable),
            ("sig", block("  Fixed-Key Signature (FAIL): BB\n  Hash (GOOD): CC"), .signatureInvalid),
            ("good", block("  Fixed-Key Signature (GOOD): AA\n  Hash (GOOD): CC"), .verified),
            ("hash", block("  Fixed-Key Signature (GOOD): AA\n  Superblock Hash (FAIL): CC"), .failed),
            // A hash mismatch without a derived title key only means "could not
            // decrypt": it must never be reported as corruption.
            ("hash-without-key", block("  Fixed-Key Signature (GOOD): AA\n  Superblock Hash (FAIL): CC", keys: 0), .unavailable),
            // Unknown key generation: the FAIL may be a decryption/key gap, not
            // corruption. Downgrade to cannot-confirm instead of red.
            ("hash-unknown-generation", block("  Fixed-Key Signature (GOOD): AA\n  Superblock Hash (FAIL): CC\n  Master Key Revision: 0x11 (Unknown)"), .unavailable),
        ]
        for (label, text, state) in outputs {
            let result = DeepVerifier.interpret(output: text, format: .nsp)
            expect(result.state == state, "hactool output '\(label)' maps to \(state.rawValue)")
        }

        print("install plan order")
        // DBI rejects an update whose base is not installed yet, so the plan
        // must keep titles whole and send base -> update -> DLC inside each.
        func planPackage(_ name: String, _ type: PackageContentType, _ titleID: String) -> InstallPackage {
            var package = InstallPackage(url: URL(fileURLWithPath: "/batch/\(name)"),
                                         format: .nsp, fileSize: 1, displayName: name)
            package.baseTitleID = titleID
            package.contentType = type
            return package
        }
        let baseA = planPackage("Zzz base.nsp", .base, "0100000000010000")
        let updateA = planPackage("Aaa update.nsp", .update, "0100000000010000")
        let dlcA = planPackage("Mmm dlc.nsp", .dlc, "0100000000010000")
        let unknownA = planPackage("000 unknown.nsp", .unknown, "0100000000010000")
        let baseB = planPackage("Mmm base.nsp", .base, "0100000000011000")

        let single = InstallPlanOrder.ordered([dlcA, updateA, baseA])
        expect(single.map(\.displayName) == ["Zzz base.nsp", "Aaa update.nsp", "Mmm dlc.nsp"],
               "inside one title: base, then update, then DLC")

        expect(InstallPlanOrder.ordered([unknownA, dlcA, baseA, updateA]).last?.id == unknownA.id,
               "unrecognised type sorts last inside its title")

        // File names that form the cycle the old one-pass comparator allowed:
        // base(A)=Z…, update(A)=A…, base(B)=M….
        let mixed = InstallPlanOrder.ordered([updateA, baseB, baseA, dlcA],
                                             groupTitles: [baseA.groupKey: "Zelda",
                                                           baseB.groupKey: "Mario"])
        expect(mixed.map(\.displayName) == ["Mmm base.nsp", "Zzz base.nsp", "Aaa update.nsp", "Mmm dlc.nsp"],
               "titles stay whole and blocks are ordered by title name")
        for key in [baseA.groupKey, baseB.groupKey] {
            let offsets = mixed.enumerated().filter { $0.element.groupKey == key }.map(\.offset)
            expect(offsets.last! - offsets.first! == offsets.count - 1, "title \(key) is not interleaved")
        }
        expect(InstallPlanOrder.ordered([updateA, baseB, baseA, dlcA]).map(\.displayName)
               == InstallPlanOrder.ordered([baseA, dlcA, updateA, baseB]).map(\.displayName),
               "no title catalogue: the plan is still deterministic")

        print("install retry policy")
        expect(InstallRetryPolicy.decision(attempts: 1, isCancelled: false) == .retry,
               "first failure is retried, not written off")
        expect(InstallRetryPolicy.decision(attempts: 2, isCancelled: false) == .retry,
               "second failure still gets its last attempt")
        expect(InstallRetryPolicy.decision(attempts: 3, isCancelled: false) == .fail,
               "third failure is written off so the batch moves on")
        expect(InstallRetryPolicy.decision(attempts: 1, isCancelled: true) == .cancelled,
               "a user cancel is never retried")

        print("install queue persistence")
        let storeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("switchmtp-plan-test/InstallQueue.json")
        let entries = [
            InstallQueueStore.Entry(path: "/games/a.nsp", storageKind: "sdInstall", attempts: 0),
            InstallQueueStore.Entry(path: "/games/b.nsz", storageKind: "nandInstall", attempts: 2),
        ]
        expect(InstallQueueStore.save(entries, to: storeURL), "queue file written")
        expect(InstallQueueStore.load(from: storeURL) == entries, "queue survives a round trip")
        expect(InstallQueueStore.save([], to: storeURL), "empty queue clears the file")
        expect(InstallQueueStore.load(from: storeURL).isEmpty, "cleared queue reloads empty")
        expect(InstallQueueStore.load(from: storeURL.appendingPathComponent("missing.json")).isEmpty,
               "missing queue file is not an error")

        print(failures == 0 ? "ALL CHECKS PASSED" : "\(failures) CHECK(S) FAILED")
        exit(failures == 0 ? 0 : 1)
    }

}
