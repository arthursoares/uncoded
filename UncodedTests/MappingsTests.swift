import SwiftData
import XCTest
@testable import Uncoded

final class MappingsTests: XCTestCase {
    @MainActor
    private func context() throws -> ModelContext {
        let container = try ModelContainer(for: UserLens.self, CodeMapping.self,
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        return ModelContext(container)
    }

    @MainActor
    func testReplacingOneCodePreservesTheLensOtherCodes() throws {
        let context = try context()
        let lens = UserLens(name: "Re-coded lens", make: "")
        context.insert(lens)
        try Mappings.assign(code: "000110", to: lens, in: context)
        try Mappings.assign(code: "011110", to: lens, in: context)

        try Mappings.replace("000110", with: "101011", for: lens, in: context)

        XCTAssertEqual(Set(lens.mappings.map(\.code)), ["011110", "101011"])
        XCTAssertFalse(try context.fetch(FetchDescriptor<CodeMapping>())
            .contains(where: { $0.code == "000110" }))
    }

    @MainActor
    func testAssigningAnOccupiedCodeTransfersItsSingleMapping() throws {
        let context = try context()
        let oldOwner = UserLens(name: "Old owner", make: "")
        let newOwner = UserLens(name: "New owner", make: "")
        context.insert(oldOwner)
        context.insert(newOwner)
        try Mappings.assign(code: "000110", to: oldOwner, in: context)

        try Mappings.assign(code: "000110", to: newOwner, in: context)

        let matching = try context.fetch(FetchDescriptor<CodeMapping>())
            .filter { $0.code == "000110" }
        XCTAssertEqual(matching.count, 1)
        XCTAssertIdentical(matching.first?.lens, newOwner)
        XCTAssertFalse(oldOwner.mappings.contains(where: { $0.code == "000110" }))
    }

    @MainActor
    func testAuthorizationOnlyRequiresConfirmationForAnotherOwner() throws {
        let context = try context()
        let owner = UserLens(name: "Current owner", make: "")
        context.insert(owner)
        try Mappings.assign(code: "000110", to: owner, in: context)

        XCTAssertTrue(try Mappings.authorization(for: "011110", newOwnerName: "New owner",
                                                 currentLens: nil, confirming: nil,
                                                 in: context).isAllowed)
        XCTAssertTrue(try Mappings.authorization(for: "000110", newOwnerName: owner.name,
                                                 currentLens: owner, confirming: nil,
                                                 in: context).isAllowed)

        let result = try Mappings.authorization(for: "000110", newOwnerName: "New owner",
                                                currentLens: nil, confirming: nil,
                                                in: context)
        guard case .confirmationRequired(let transfer) = result else {
            return XCTFail("Expected an occupied code to require confirmation")
        }
        XCTAssertEqual(transfer.oldOwnerName, "Current owner")
        XCTAssertEqual(transfer.newOwnerName, "New owner")
        XCTAssertEqual(try context.fetch(FetchDescriptor<CodeMapping>()).count, 1)
        XCTAssertIdentical(try context.fetch(FetchDescriptor<CodeMapping>()).first?.lens, owner,
                           "Requesting or cancelling confirmation must not mutate ownership")
    }

    @MainActor
    func testCurrentConfirmationAllowsTransferAndPreservesOtherCodes() throws {
        let context = try context()
        let oldOwner = UserLens(name: "Old owner", make: "")
        let newOwner = UserLens(name: "New owner", make: "")
        context.insert(oldOwner)
        context.insert(newOwner)
        try Mappings.assign(code: "000110", to: oldOwner, in: context)
        try Mappings.assign(code: "011110", to: newOwner, in: context)
        try Mappings.assign(code: "101011", to: newOwner, in: context)

        let initial = try Mappings.authorization(for: "000110", newOwnerName: newOwner.name,
                                                 currentLens: newOwner, confirming: nil,
                                                 in: context)
        guard case .confirmationRequired(let confirmation) = initial else {
            return XCTFail("Expected transfer confirmation")
        }
        XCTAssertTrue(try Mappings.authorization(for: "000110", newOwnerName: newOwner.name,
                                                 currentLens: newOwner, confirming: confirmation,
                                                 in: context).isAllowed)

        try Mappings.replace("011110", with: "000110", for: newOwner, in: context)

        XCTAssertEqual(Set(newOwner.mappings.map(\.code)), ["000110", "101011"])
        XCTAssertFalse(oldOwner.mappings.contains(where: { $0.code == "000110" }))
    }

    @MainActor
    func testConfirmationIsRejectedWhenOwnerChangesBeforeCommit() throws {
        let context = try context()
        let firstOwner = UserLens(name: "First owner", make: "")
        let changedOwner = UserLens(name: "Changed owner", make: "")
        context.insert(firstOwner)
        context.insert(changedOwner)
        try Mappings.assign(code: "000110", to: firstOwner, in: context)

        let initial = try Mappings.authorization(for: "000110", newOwnerName: "New owner",
                                                 currentLens: nil, confirming: nil,
                                                 in: context)
        guard case .confirmationRequired(let confirmation) = initial else {
            return XCTFail("Expected initial confirmation")
        }
        try Mappings.assign(code: "000110", to: changedOwner, in: context)

        let revalidated = try Mappings.authorization(for: "000110", newOwnerName: "New owner",
                                                     currentLens: nil, confirming: confirmation,
                                                     in: context)
        guard case .confirmationRequired(let refreshed) = revalidated else {
            return XCTFail("A stale confirmation must not authorize a transfer")
        }
        XCTAssertEqual(refreshed.oldOwnerName, "Changed owner")
        XCTAssertIdentical(changedOwner.mappings.first(where: { $0.code == "000110" })?.lens,
                           changedOwner)
    }
}
