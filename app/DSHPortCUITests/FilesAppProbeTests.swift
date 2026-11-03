//
//  FilesAppProbeTests.swift
//  DSHPortCUITests
//
//  A diagnostic for the Files app's own accessibility tree.
//
//  WHY IT IS SEPARATE FROM THE ASSERTION
//  -------------------------------------
//  Driving `com.apple.DocumentsApp` means finding out how Apple's own app
//  presents its rows, and a wrong guess produces a failed assertion that says
//  nothing about what the screen actually contained. This test asserts nothing:
//  it walks the Files app to each place the real test needs and prints every
//  descendant with its type, identifier and label, so the real test's lookups can
//  be chosen from evidence rather than from memory.
//
//  It is not part of the delivered verdict; `Step17UITests` is. It exists so the
//  next person does not have to rediscover the same labels.
//

import XCTest

final class FilesAppProbeTests: XCTestCase {

    private func dump(_ app: XCUIApplication, _ tag: String) {
        print("STEP17-DUMP \(tag) START")
        let all = app.descendants(matching: .any).allElementsBoundByIndex
        for element in all {
            let label = element.label
            let identifier = element.identifier
            // Only what can be addressed: an element with neither is not useful
            // to a test and would bury the ones that are.
            if label.isEmpty && identifier.isEmpty { continue }
            print("STEP17-EL type=\(element.elementType.rawValue) id=\(identifier) label=\(label)")
        }
        print("STEP17-DUMP \(tag) END count=\(all.count)")
    }

    func testDumpFilesAppTree() {
        let files = XCUIApplication(bundleIdentifier: "com.apple.DocumentsApp")
        files.launch()
        files.activate()
        sleep(5)
        dump(files, "launch")

        for label in ["浏览", "Browse"] {
            let button = files.tabBars.buttons[label]
            if button.exists { button.tap(); sleep(3); break }
        }
        dump(files, "browse")

        // The "位置" header is a collapsible section header; tapping it may be
        // what reveals the location rows.
        let locationsHeader = files.cells["位置"].firstMatch
        if locationsHeader.exists {
            locationsHeader.tap()
            sleep(2)
            dump(files, "after-locations-tap")
        }

        // Whatever the row is called, ask for anything containing "iPhone".
        let candidates = files.descendants(matching: .any).allElementsBoundByIndex
            .filter { $0.label.contains("iPhone") }
        for candidate in candidates {
            print("STEP17-IPHONE-CANDIDATE type=\(candidate.elementType.rawValue) id=\(candidate.identifier) label=\(candidate.label) hittable=\(candidate.isHittable)")
        }
        if let row = candidates.first(where: { $0.isHittable }) {
            row.tap()
            sleep(3)
            dump(files, "after-iphone")
        }
    }
}
