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
}
