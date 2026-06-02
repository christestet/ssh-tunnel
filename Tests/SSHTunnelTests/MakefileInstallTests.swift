import Foundation
import XCTest

final class MakefileInstallTests: XCTestCase {
    func testInstallStopsRunningAppBeforeReplacingApplicationBundle() throws {
        let makefile = try String(
            contentsOfFile: "Makefile",
            encoding: .utf8
        )

        guard let installTarget = makefile.range(of: #"(?ms)^install:.*?(?=^\S|\z)"#, options: .regularExpression)
        else {
            XCTFail("Makefile must define an install target")
            return
        }

        let installBody = String(makefile[installTarget])
        let stopRange = try XCTUnwrap(installBody.range(of: "$(MAKE) -s stop"))
        let removeRange = try XCTUnwrap(installBody.range(of: "rm -rf /Applications/$(BUNDLE)"))

        XCTAssertLessThan(stopRange.lowerBound, removeRange.lowerBound)
    }

    func testDMGTargetStagesBundleAndCreatesDiskImage() throws {
        let makefile = try String(
            contentsOfFile: "Makefile",
            encoding: .utf8
        )

        guard let dmgTarget = makefile.range(of: #"(?ms)^dmg:.*?(?=^\S|\z)"#, options: .regularExpression)
        else {
            XCTFail("Makefile must define a dmg target")
            return
        }

        let dmgBody = String(makefile[dmgTarget])

        XCTAssertTrue(dmgBody.contains("$(BUNDLE)"))
        XCTAssertTrue(dmgBody.contains("ln -s /Applications"))
        XCTAssertTrue(dmgBody.contains("hdiutil create"))
        XCTAssertTrue(dmgBody.contains("$(DMG)"))
        XCTAssertTrue(makefile.contains("DMG        := $(DIST_DIR)/$(APP)-v$(VERSION)-macos26-arm64.dmg"))
    }

    func testBundleTargetStampsBuildVersionBeforeSigning() throws {
        let makefile = try String(
            contentsOfFile: "Makefile",
            encoding: .utf8
        )

        guard let bundleTarget = makefile.range(of: #"(?ms)^bundle:.*?(?=^\S|\z)"#, options: .regularExpression)
        else {
            XCTFail("Makefile must define a bundle target")
            return
        }

        let bundleBody = String(makefile[bundleTarget])
        let stampRange = try XCTUnwrap(bundleBody.range(of: "CFBundleVersion $(BUILD_VERSION)"))
        let codesignRange = try XCTUnwrap(bundleBody.range(of: "codesign --force --sign - --options runtime $(BUNDLE)"))

        XCTAssertLessThan(stampRange.lowerBound, codesignRange.lowerBound)
    }
}
