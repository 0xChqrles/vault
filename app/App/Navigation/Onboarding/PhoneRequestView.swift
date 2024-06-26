//
//  AskSurnameView.swift
//  Vault
//
//  Created by Charles Lanier on 21/03/2024.
//

import SwiftUI
import PhoneNumberKit

struct PhoneRequestView: View {

    @EnvironmentObject private var registrationModel: RegistrationModel

    @State private var presentingNextView = false
    @State private var phoneNumber = ""
    @State private var parsedPhoneNumber: PhoneNumber?

    var body: some View {
        OnboardingPage(isLoading: $registrationModel.isLoading) {
            VStack(alignment: .center, spacing: 64) {
                VStack(alignment: .center, spacing: 24) {
                    Text("A Personalized Touch").textTheme(.headlineLarge)

                    Text("Enter your phone number. We will send you a confirmation code.")
                        .textTheme(.headlineSubtitle)
                        .multilineTextAlignment(.center)
                }

                VStack(alignment: .center, spacing: 32) {
                    PhoneInput(phoneNumber: $phoneNumber, parsedPhoneNumber: $parsedPhoneNumber, shouldFocusOnAppear: true)

                    VStack(alignment: .center, spacing: 16) {
                        // TODO: implement login
                        PrimaryButton("Sign up", disabled: self.parsedPhoneNumber == nil) {
                            registrationModel.startRegistration(phoneNumber: self.parsedPhoneNumber!) { result in
                                switch result {
                                case .success():
                                    presentingNextView = true

                                case .failure(let error):
                                    print(error)
                                    // TODO: handle error
                                }
                            }
                        }
                    }
                }
            }

            Spacer()
        }
        .navigationDestination(isPresented: $presentingNextView) {
            PhoneValidationView(phoneNumber: parsedPhoneNumber)
        }
    }
}

#if DEBUG
struct PhoneRequestViewPreviews : PreviewProvider {

    @StateObject static var registrationModel = RegistrationModel(vaultService: VaultService())

    static var previews: some View {
        NavigationStack {
            PhoneRequestView()
                .environmentObject(self.registrationModel)
        }
    }
}
#endif
