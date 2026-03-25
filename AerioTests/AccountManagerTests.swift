import XCTest
@testable import Aerio

@MainActor
final class AccountManagerTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!
    private var manager: AccountManager!

    override func setUp() {
        super.setUp()
        suiteName = "AccountManagerTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        manager = AccountManager(defaults: defaults)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        manager = nil
        super.tearDown()
    }

    func testInitiallyEmpty() {
        XCTAssertTrue(manager.accounts.isEmpty)
    }

    func testAddAccount() {
        let account = Account(id: "a1", email: "user@gmail.com", displayName: "User")
        manager.addAccount(account)
        XCTAssertEqual(manager.accounts.count, 1)
        XCTAssertEqual(manager.accounts.first?.id, "a1")
    }

    func testAddDuplicateAccountIgnored() {
        let account = Account(id: "a1", email: "user@gmail.com", displayName: "User")
        manager.addAccount(account)
        manager.addAccount(account)
        XCTAssertEqual(manager.accounts.count, 1)
    }

    func testRemoveAccount() {
        let account = Account(id: "a1", email: "user@gmail.com", displayName: "User")
        manager.addAccount(account)
        manager.removeAccount(id: "a1")
        XCTAssertTrue(manager.accounts.isEmpty)
    }

    func testRemoveNonexistentAccountNoOp() {
        manager.removeAccount(id: "nonexistent")
        XCTAssertTrue(manager.accounts.isEmpty)
    }

    func testAccountForId() {
        let account = Account(id: "a1", email: "user@gmail.com", displayName: "User")
        manager.addAccount(account)
        XCTAssertNotNil(manager.account(for: "a1"))
        XCTAssertNil(manager.account(for: "a2"))
    }

    func testUpdateAccount() {
        var account = Account(id: "a1", email: "user@gmail.com", displayName: "User", color: .blue)
        manager.addAccount(account)
        account.displayName = "Updated User"
        account.color = .red
        manager.updateAccount(account)
        XCTAssertEqual(manager.accounts.first?.displayName, "Updated User")
        XCTAssertEqual(manager.accounts.first?.color, .red)
    }

    func testPersistenceAcrossInstances() {
        let account = Account(id: "a1", email: "user@gmail.com", displayName: "User")
        manager.addAccount(account)

        let manager2 = AccountManager(defaults: defaults)
        XCTAssertEqual(manager2.accounts.count, 1)
        XCTAssertEqual(manager2.accounts.first?.email, "user@gmail.com")
    }

    func testUpdateAccountPersistence() {
        var account = Account(id: "a1", email: "user@gmail.com", displayName: "User", color: .blue)
        manager.addAccount(account)
        account.displayName = "New Name"
        account.color = .green
        manager.updateAccount(account)

        let manager2 = AccountManager(defaults: defaults)
        XCTAssertEqual(manager2.accounts.first?.displayName, "New Name")
        XCTAssertEqual(manager2.accounts.first?.color, .green)
    }

    func testUpdateNonexistentAccountNoOp() {
        let account = Account(id: "nonexistent", email: "x@gmail.com", displayName: "X")
        manager.updateAccount(account)
        XCTAssertTrue(manager.accounts.isEmpty)
    }

    func testAccountInitialsSingleName() {
        let account = Account(id: "a1", email: "user@gmail.com", displayName: "Alice")
        XCTAssertEqual(account.initials, "A")
    }

    func testAccountInitialsTwoNames() {
        let account = Account(id: "a1", email: "user@gmail.com", displayName: "Alice Brown")
        XCTAssertEqual(account.initials, "AB")
    }

    func testAccountInitialsThreeNames() {
        let account = Account(id: "a1", email: "user@gmail.com", displayName: "Alice B Carter")
        XCTAssertEqual(account.initials, "AB")
    }

    func testComputeInitialsStatic() {
        XCTAssertEqual(Account.computeInitials(from: "John Doe"), "JD")
        XCTAssertEqual(Account.computeInitials(from: "Jane"), "J")
        XCTAssertEqual(Account.computeInitials(from: ""), "")
    }

    func testUpdateAccountColorAndName() {
        var account = Account(id: "a1", email: "user@gmail.com", displayName: "Old Name", color: .blue)
        manager.addAccount(account)

        account.displayName = "New Name"
        account.color = .purple
        account.avatarLetter = String("New Name".prefix(1)).uppercased()
        manager.updateAccount(account)

        let updated = manager.account(for: "a1")
        XCTAssertEqual(updated?.displayName, "New Name")
        XCTAssertEqual(updated?.color, .purple)
        XCTAssertEqual(updated?.avatarLetter, "N")
        XCTAssertEqual(updated?.initials, "NN")
    }

    func testMultipleAccounts() {
        let a1 = Account(id: "a1", email: "one@gmail.com", displayName: "One", color: .blue)
        let a2 = Account(id: "a2", email: "two@gmail.com", displayName: "Two", color: .red)
        let a3 = Account(id: "a3", email: "three@gmail.com", displayName: "Three", color: .green)
        manager.addAccount(a1)
        manager.addAccount(a2)
        manager.addAccount(a3)
        XCTAssertEqual(manager.accounts.count, 3)
        manager.removeAccount(id: "a2")
        XCTAssertEqual(manager.accounts.count, 2)
        XCTAssertNil(manager.account(for: "a2"))
    }
}
