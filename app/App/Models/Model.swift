//
//  Model.swift
//  Vault
//
//  Created by Charles Lanier on 11/04/2024.
//

import Foundation
import PhoneNumberKit
import Contacts
import SwiftUI
import Starknet
import BigInt

enum Status: Equatable {
    case none
    case active
    case loading
    case success
    case error(String)
}

// Aggregate Model
@MainActor
class Model: ObservableObject {

    @AppStorage("starknetMainAddress") private var address: String = ""

    // App
    @Published var isLoading = false
    @Published var showMessage = false

    // Navgiation
    @Published var showSendingSheet = false {
        didSet {
            if self.showSendingSheet {
                self.initiateTransfer()
            } else {
                self.dismissTransfer()
            }
        }
    }

    // Sending USDC
    @Published var recipientContact: Contact?
    @Published var sendingAmount: String = ""
    @Published var sendingStatus: Status = .none

    // Country picker
    @Published var selectedRegionCode = Locale.current.regionOrFrance.identifier
    @Published var searchedCountry = ""

    // Contacts
    @Published var contacts: [Contact] = []
    @Published var contactsAuthorizationStatus: CNAuthorizationStatus = .notDetermined

    var parsedSendingAmount: Double {
        // Replace the comma with a dot
        let amount = self.sendingAmount.replacingOccurrences(of: ",", with: ".")

        // Check if the string ends with a dot and append a zero if true
        // Convert the final string to a Float
        return Double(amount.hasSuffix(".") ? "\(amount)0" : amount) ?? 0
    }

    private var updatesHandler: Task<Void, Error>? = nil

    private var vaultService: VaultService

    private var contactStore = CNContactStore()

    private let phoneNumberKit = PhoneNumberKit()
    private lazy var countries: [CountryData] = {
        phoneNumberKit.allCountries()
            .map { regionCode in
                return self.countryData(forRegionCode: regionCode)
            }
            .filter { $0.name != "world" }
            .sorted { $0.name < $1.name }
    }()

    private lazy var provider: StarknetProviderProtocol = StarknetProvider(url: "https://rpc.nethermind.io/sepolia-juno/?apikey=\(Constants.starknetRpcApiKey)")!

    private lazy var account: StarknetAccountProtocol = {
        return StarknetAccount(
            address: Felt(stringLiteral: self.address),
            signer: P256Signer(),
            provider: self.provider,
            chainId: .sepolia,
            cairoVersion: .one
        )
    }()

    init(vaultService: VaultService) {
        // Vault API
        self.vaultService = vaultService

        // Contacts
        checkContactsAuthorizationStatus()

        self.address = "0x014DfAEE92F238254e3eb3621ADcC6323C5eCde6F2417980D56eaEc7ee23Cc2d"
    }

    deinit {
        updatesHandler?.cancel()
    }
}

// MARK: - Vault API

extension Model {

    func startRegistration(phoneNumber: PhoneNumber, completion: @escaping (Result<Void, Error>) -> Void) {
        self.isLoading = true

        vaultService.getOTP(phoneNumber: phoneNumber.rawString()) { result in
            self.isLoading = false
            completion(result)
        }
    }

    func confirmRegistration(
        phoneNumber: PhoneNumber,
        otp: String,
        publicKeyX: String,
        publicKeyY: String,
        completion: @escaping (Result<String, Error>
        ) -> Void) {
        self.isLoading = true

        vaultService.verifyOTP(
            phoneNumber: phoneNumber.rawString(),
            otp: otp,
            publicKeyX: publicKeyX,
            publicKeyY: publicKeyY
        ) { result in
            self.isLoading = false
            completion(result)
        }
    }
}


// MARK: - Country picker

extension Model {

    var selectedCountryData: CountryData {
        return self.countryData(forRegionCode: self.selectedRegionCode)
    }

    var filteredCountries: [CountryData] {
        if self.searchedCountry.isEmpty {
            return self.countries
        } else {
            return self.countries.filter { $0.name.lowercased().contains(self.searchedCountry.lowercased()) }
        }
    }

    private var partialFormatter: PartialFormatter {
        PartialFormatter(
            phoneNumberKit: self.phoneNumberKit,
            defaultRegion: self.selectedRegionCode,
            withPrefix: false,
            ignoreIntlNumbers: true
        )
    }

    func isSelected(_ regionCode: String) -> Bool {
        return self.selectedRegionCode == regionCode
    }

    func format(phoneNumber: String) -> String {
        return self.partialFormatter.formatPartial(phoneNumber)
    }

    func parse(phoneNumber: String) -> PhoneNumber? {
        do {
            return try phoneNumberKit.parse(phoneNumber, withRegion: self.selectedRegionCode, ignoreType: true)
        } catch {
            return nil
        }
    }
}

// MARK: - Starknet

extension Model {

    func executeTransaction(calls: [StarknetCall]) async throws -> StarknetInvokeTransactionResponse {
        let nonce = try await self.account.getNonce()
        let maxFee = self.estimateFees()

        return try await account.executeV1(calls: calls, params: StarknetOptionalInvokeParamsV1(nonce: nonce, maxFee: maxFee))
    }

    func executeTransaction(call: StarknetCall) async throws -> StarknetInvokeTransactionResponse {
        return try await self.executeTransaction(calls: [call])
    }

    func estimateFees() -> Felt {
        return Felt(fromHex: "0x1000000000000000000")! // 1 ETH
    }

    func getAddress(from phoneNumber: String) -> Felt? {
        guard let phoneNumberFelt = Felt.fromShortString(phoneNumber) else {
            return nil
        }
        let phoneNumberHex = phoneNumberFelt.toHex().dropFirst(2)
        guard let phoneNumberBytes = BigUInt(phoneNumberHex, radix: 16)?.serialize().bytes else {
            return nil
        }

        return StarknetContractAddressCalculator.calculateFrom(
            classHash: Constants.Starknet.blankAccountClassHash,
            calldata: [],
            salt: starknetKeccak(on: phoneNumberBytes),
            deployerAddress: Constants.Starknet.vaultFactoryAddress
        )
    }
}

// MARK: - Contacts

extension Model {

    public func checkContactsAuthorizationStatus() {
        self.contactsAuthorizationStatus = CNContactStore.authorizationStatus(for: .contacts)

        switch self.contactsAuthorizationStatus {
        case .notDetermined, .denied, .restricted:
            break

        case .authorized:
            self.fetchContacts()

        @unknown default:
            fatalError("Unknown authorization status")
        }
    }

    public func requestContactsAccess() {
        if self.contactsAuthorizationStatus == .denied {
            self.openSettings()
        } else if self.contactsAuthorizationStatus == .notDetermined {
            contactStore.requestAccess(for: .contacts) { [weak self] (granted, error) in
                DispatchQueue.main.async {
                    if granted {
                        self?.contactsAuthorizationStatus = .authorized
                        self?.fetchContacts()
                    } else {
                        self?.contactsAuthorizationStatus = .denied
                        // TODO: Handle the case where permission is denied
                        print("Permission denied")
                    }
                }
            }
        }
    }

    func addContact(name: String, phone: String, completionHandler: @escaping (Contact) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let newContact = CNMutableContact()
            let nameComponents = name.split(separator: " ")

            if let firstName = nameComponents.first {
                newContact.givenName = String(firstName)
            }

            if nameComponents.count > 1 {
                newContact.familyName = nameComponents.dropFirst().joined(separator: " ")
            }

            let phoneValue = CNLabeledValue(label: CNLabelPhoneNumberMain, value: CNPhoneNumber(stringValue: phone))
            newContact.phoneNumbers = [phoneValue]

            let saveRequest = CNSaveRequest()
            saveRequest.add(newContact, toContainerWithIdentifier: nil)

            do {
                try self?.contactStore.execute(saveRequest)

                DispatchQueue.main.async {
                    self?.fetchContacts() // Refresh the contacts list
                    completionHandler(Contact(name: name, phone: phone))
                }
            } catch {
                print("Failed to save contact: \(error)")
                // TODO: Handle this case
            }
        }
    }
}

// MARK: - Sending Logic

extension Model {

    func setRecipient(_ recipient: Contact) {
        self.recipientContact = recipient
    }

    func executeTransfer() async {
        guard
            let recipientContact = self.recipientContact,
            let recipientAddress = self.getAddress(from: recipientContact.phone),
            let amount = USDCAmount(from: self.parsedSendingAmount)
        else {
            self.sendingStatus = .error("Invalid request.")
            return
        }

        let call = StarknetCall(
            contractAddress: Constants.Starknet.usdcAddress,
            entrypoint: starknetSelector(from: "transfer"),
            calldata: [
                recipientAddress,
                amount.value.low,
                amount.value.high,
            ]
        )

        self.sendingStatus = .loading

        do {
            let result = try await self.executeTransaction(call: call)

            self.sendingStatus = .success

            #if DEBUG
            print("tx: \(result.transactionHash)")
            #endif
        } catch let error {
            self.sendingStatus = .success
//            self.sendingStatus = .error("An error has occured during the transaction.")

            #if DEBUG
            print(error)
            #endif
        }
    }
}

// MARK: - Private Logic

extension Model {

    private func countryData(forRegionCode regionCode: String) -> CountryData {
        let countryName = Locale.current.localizedString(forRegionCode: regionCode)  ?? "world"
        let phoneCode = phoneNumberKit.countryCode(for: regionCode) ?? 0

        return CountryData(
            regionCode: regionCode,
            phoneCode: "+\(phoneCode)",
            name: countryName
        )
    }

    private func openSettings() {
        guard let settingsUrl = URL(string: UIApplication.openSettingsURLString) else {
            return
        }

        if UIApplication.shared.canOpenURL(settingsUrl) {
            UIApplication.shared.open(settingsUrl)
        }
    }

    private func fetchContacts() {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let request = CNContactFetchRequest(
                keysToFetch: [
                    CNContactGivenNameKey,
                    CNContactFamilyNameKey,
                    CNContactPhoneNumbersKey,
                    CNContactImageDataKey,
                ] as [CNKeyDescriptor]
            )
            request.sortOrder = CNContactSortOrder.givenName

            var contacts: [Contact] = []

            do {
                try self?.contactStore.enumerateContacts(with: request) { (cnContact, stop) in
                    let name = "\(cnContact.givenName) \(cnContact.familyName)".trimmingCharacters(in: .whitespaces)
                    let imageData = cnContact.imageData

                    // Phone
                    let phoneNumber = cnContact.phoneNumbers.first?.value.stringValue ?? ""

                    // Only add contacts with a name AND a phone number
                    if !name.isEmpty && phoneNumber.hasPrefix("+") {
                        let contact = Contact(name: name, phone: phoneNumber, imageData: imageData)
                        contacts.append(contact)
                    }
                }

                DispatchQueue.main.async {
                    self?.contacts = contacts
                }
            } catch {
                print("Failed to fetch contacts: \(error)")
            }
        }
    }

    private func initiateTransfer() {
        self.recipientContact = nil
        self.sendingAmount = "0"
        self.sendingStatus = .active
    }

    private func dismissTransfer() {
        self.sendingStatus = .none
    }
}