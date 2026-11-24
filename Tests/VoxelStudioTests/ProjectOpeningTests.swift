import XCTest
@testable import VoxelStudio

final class ProjectOpeningTests: XCTestCase {
    private let cell = Cell(2, 0, 3)
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: folder)
    }

    private func emptyProject(at url: URL) throws -> EditorModel {
        let model = EditorModel()
        model.newProject()
        try model.saveProject(to: url)
        return model
    }

    func testSavingWhileReopeningCurrentFileKeepsLatestEdits() throws {
        let url = folder.appendingPathComponent("Beacon.vxl")
        let model = try emptyProject(at: url)
        model.apply(hit: nil, adjacent: cell)
        try model.loadProject(from: url) { model.saveProject() }
        XCTAssertEqual(model.visibleCells, [cell: model.ink])
        XCTAssertFalse(model.isDirty)
        XCTAssertFalse(model.canUndo)
    }

    func testSaveAsToIncomingFileThroughSymbolicLinkUsesSavedContents() throws {
        let original = folder.appendingPathComponent("Original.vxl")
        let incoming = folder.appendingPathComponent("Incoming.vxl")
        let alias = folder.appendingPathComponent("Linked.vxl")
        _ = try emptyProject(at: incoming)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: incoming)
        let model = try emptyProject(at: original)
        model.apply(hit: nil, adjacent: cell)
        try model.loadProject(from: alias) {
            try model.saveProject(to: incoming)
            return true
        }
        XCTAssertEqual(model.title, "Incoming")
        XCTAssertEqual(model.visibleCells, [cell: model.ink])
        XCTAssertFalse(model.isDirty)
    }

    func testCancelAndDiscardWhileReopeningDirtyProject() throws {
        let url = folder.appendingPathComponent("Beacon.vxl")
        let model = try emptyProject(at: url)
        model.apply(hit: nil, adjacent: cell)
        let originalID = model.projectID
        try model.loadProject(from: url) { false }
        XCTAssertEqual(model.projectID, originalID)
        XCTAssertEqual(model.visibleCells, [cell: model.ink])
        XCTAssertTrue(model.isDirty)
        try model.loadProject(from: url) { true }
        XCTAssertNotEqual(model.projectID, originalID)
        XCTAssertTrue(model.visibleCells.isEmpty)
        XCTAssertFalse(model.isDirty)
    }

    func testInvalidIncomingFileLeavesDirtyProjectUntouchedWithoutPrompting() throws {
        let url = folder.appendingPathComponent("Beacon.vxl")
        let model = try emptyProject(at: url)
        model.apply(hit: nil, adjacent: cell)
        let invalid = folder.appendingPathComponent("Broken.vxl")
        try Data("{}".utf8).write(to: invalid)
        XCTAssertThrowsError(try model.loadProject(from: invalid) {
            XCTFail("Invalid input should fail before asking to close the active project.")
            return true
        })
        XCTAssertEqual(model.visibleCells, [cell: model.ink])
        XCTAssertTrue(model.isDirty)
    }
}
