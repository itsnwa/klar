import Contacts
import Foundation

/// The user's own card in Contacts ("My Card"), for filling name, email,
/// phone and address boxes.
nonisolated struct ContactCard: Sendable {
    let displayName: String
    /// Values keyed by HTML autocomplete tokens (`given-name`, `email`,
    /// `postal-code`, …), as the autofill script's `fillContact` expects.
    let fillValues: [String: String]

    /// What the card can fill into a form whose visible contact boxes take
    /// `fieldTypes` (autocomplete tokens): the categories to show the user,
    /// in a stable order, and only the values belonging to them.
    func offer(forFieldTypes fieldTypes: [String]) -> (categories: [String], values: [String: String]) {
        let wanted = Set(fieldTypes.map(Self.category(of:)))
        let values = fillValues.filter { wanted.contains(Self.category(of: $0.key)) }
        let categories = ["name", "company", "email", "phone", "address"].filter { category in
            values.keys.contains { Self.category(of: $0) == category }
        }
        return (categories, values)
    }

    private static func category(of token: String) -> String {
        switch token {
        case "name", "given-name", "additional-name", "family-name": return "name"
        case "organization": return "company"
        case "email": return "email"
        case "tel", "tel-national": return "phone"
        default: return "address"
        }
    }
}

@MainActor
final class ContactCardProvider {
    static let shared = ContactCardProvider()

    private let store = CNContactStore()

    var isAuthorized: Bool {
        CNContactStore.authorizationStatus(for: .contacts) == .authorized
    }

    private init() {}

    /// Asks for Contacts access if it hasn't been decided yet.
    func requestAccess() async -> Bool {
        if isAuthorized { return true }
        do {
            return try await store.requestAccess(for: .contacts)
        } catch {
            logError(.passwords, "Contacts access request failed: \(error.localizedDescription)")
            return false
        }
    }

    /// My Card, or nil without Contacts access or a card.
    func card() async -> ContactCard? {
        guard isAuthorized else { return nil }
        do {
            return try await Task.detached(priority: .userInitiated) {
                // A store of its own: CNContactStore isn't Sendable.
                let store = CNContactStore()
                let keys: [CNKeyDescriptor] = [
                    CNContactFormatter.descriptorForRequiredKeys(for: .fullName),
                    CNContactGivenNameKey as CNKeyDescriptor,
                    CNContactMiddleNameKey as CNKeyDescriptor,
                    CNContactFamilyNameKey as CNKeyDescriptor,
                    CNContactOrganizationNameKey as CNKeyDescriptor,
                    CNContactEmailAddressesKey as CNKeyDescriptor,
                    CNContactPhoneNumbersKey as CNKeyDescriptor,
                    CNContactPostalAddressesKey as CNKeyDescriptor
                ]
                return Self.card(from: try store.unifiedMeContactWithKeys(toFetch: keys))
            }.value
        } catch {
            logDebug(.passwords, "no My Card in Contacts: \(error.localizedDescription)")
            return nil
        }
    }

    private nonisolated static func card(from contact: CNContact) -> ContactCard? {
        var values: [String: String] = [:]
        func set(_ token: String, _ value: String?) {
            guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return }
            values[token] = value
        }

        let fullName = CNContactFormatter.string(from: contact, style: .fullName)
        set("name", fullName)
        set("given-name", contact.givenName)
        set("additional-name", contact.middleName)
        set("family-name", contact.familyName)
        set("organization", contact.organizationName)
        let email = contact.emailAddresses.first.map { $0.value as String }
        set("email", email)
        let phone = contact.phoneNumbers.first?.value.stringValue
        set("tel", phone)

        if let address = contact.postalAddresses.first?.value {
            let streetLines = address.street.components(separatedBy: .newlines).filter { !$0.isEmpty }
            set("street-address", address.street)
            set("address-line1", streetLines.first)
            set("address-line2", streetLines.dropFirst().joined(separator: ", "))
            set("address-level2", address.city)
            set("address-level1", address.state)
            set("postal-code", address.postalCode)
            set("country-name", address.country)
            set("country", address.isoCountryCode.uppercased())
        }

        guard !values.isEmpty else { return nil }
        return ContactCard(displayName: fullName ?? email ?? "My Card", fillValues: values)
    }
}
