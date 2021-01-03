import AppKit
import AppleAPI
import Combine
import Path
import LegibleError
import KeychainAccess
import Path
import Version

class AppState: ObservableObject {
    private let client = AppleAPI.Client()
    private var cancellables = Set<AnyCancellable>()
    private var selectPublisher: AnyCancellable?
    private var uninstallPublisher: AnyCancellable?
    
    @Published var authenticationState: AuthenticationState = .unauthenticated
    @Published var availableXcodes: [AvailableXcode] = [] {
        willSet {
            updateAllXcodes(availableXcodes: newValue, selectedXcodePath: selectedXcodePath)
        }
    }
    var allXcodes: [Xcode] = []
    @Published var selectedXcodePath: String? {
        willSet {
            updateAllXcodes(availableXcodes: availableXcodes, selectedXcodePath: newValue)
        }
    }
    @Published var updatePublisher: AnyCancellable?
    var isUpdating: Bool { updatePublisher != nil }
    @Published var error: AlertContent?
    @Published var authError: AlertContent?
    @Published var presentingSignInAlert = false
    @Published var isProcessingAuthRequest = false
    @Published var secondFactorData: SecondFactorData?
    @Published var xcodeBeingConfirmedForUninstallation: Xcode?
    @Published var helperInstallState: HelperInstallState = .notInstalled
    
    init() {
        try? loadCachedAvailableXcodes()
        checkIfHelperIsInstalled()
    }
    
    // MARK: - Authentication
    
    func validateSession() -> AnyPublisher<Void, Error> {
        return client.validateSession()
            .receive(on: DispatchQueue.main)
            .handleEvents(receiveCompletion: { completion in 
                if case .failure = completion {
                    self.authenticationState = .unauthenticated
                    self.presentingSignInAlert = true
                }
            })
            .eraseToAnyPublisher()
    }
    
    func signInIfNeeded() -> AnyPublisher<Void, Error> {
        validateSession()
            .catch { (error) -> AnyPublisher<Void, Error> in
                guard
                    let username = Current.defaults.string(forKey: "username"),
                    let password = try? Current.keychain.getString(username)
                else {
                    return Fail(error: error) 
                        .eraseToAnyPublisher()
                }

                return self.signIn(username: username, password: password)
                    .map { _ in Void() }
                    .eraseToAnyPublisher()
            }
            .eraseToAnyPublisher()
    }
    
    func signIn(username: String, password: String) {
        signIn(username: username, password: password)
            .sink(
                receiveCompletion: { _ in }, 
                receiveValue: { _ in }
            )
            .store(in: &cancellables)
    }
    
    func signIn(username: String, password: String) -> AnyPublisher<AuthenticationState, Error> {
        try? Current.keychain.set(password, key: username)
        Current.defaults.set(username, forKey: "username")
        
        isProcessingAuthRequest = true
        return client.login(accountName: username, password: password)
            .receive(on: DispatchQueue.main)
            .handleEvents(
                receiveOutput: { authenticationState in 
                    self.authenticationState = authenticationState
                },
                receiveCompletion: { completion in
                    self.handleAuthenticationFlowCompletion(completion)
                    self.isProcessingAuthRequest = false
                }
            )
            .eraseToAnyPublisher()
    }
    
    func handleTwoFactorOption(_ option: TwoFactorOption, authOptions: AuthOptionsResponse, serviceKey: String, sessionID: String, scnt: String) {
        self.presentingSignInAlert = false
        self.secondFactorData = SecondFactorData(
            option: option,
            authOptions: authOptions,
            sessionData: AppleSessionData(serviceKey: serviceKey, sessionID: sessionID, scnt: scnt)
        )
    }

    func requestSMS(to trustedPhoneNumber: AuthOptionsResponse.TrustedPhoneNumber, authOptions: AuthOptionsResponse, sessionData: AppleSessionData) {        
        isProcessingAuthRequest = true
        client.requestSMSSecurityCode(to: trustedPhoneNumber, authOptions: authOptions, sessionData: sessionData)
            .receive(on: DispatchQueue.main)
            .sink(
                receiveCompletion: { completion in
                    self.handleAuthenticationFlowCompletion(completion)
                    self.isProcessingAuthRequest = false
                }, 
                receiveValue: { authenticationState in 
                    self.authenticationState = authenticationState
                    if case let AuthenticationState.waitingForSecondFactor(option, authOptions, sessionData) = authenticationState {
                        self.handleTwoFactorOption(option, authOptions: authOptions, serviceKey: sessionData.serviceKey, sessionID: sessionData.sessionID, scnt: sessionData.scnt)
                    }
                }
            )
            .store(in: &cancellables)
    }
    
    func choosePhoneNumberForSMS(authOptions: AuthOptionsResponse, sessionData: AppleSessionData) {
        secondFactorData = SecondFactorData(option: .smsPendingChoice, authOptions: authOptions, sessionData: sessionData)
    }
    
    func submitSecurityCode(_ code: SecurityCode, sessionData: AppleSessionData) {
        isProcessingAuthRequest = true
        client.submitSecurityCode(code, sessionData: sessionData)
            .receive(on: DispatchQueue.main)
            .sink(
                receiveCompletion: { completion in
                    self.handleAuthenticationFlowCompletion(completion)
                    self.isProcessingAuthRequest = false
                },
                receiveValue: { authenticationState in
                    self.authenticationState = authenticationState
                }
            )
            .store(in: &cancellables)
    }
    
    private func handleAuthenticationFlowCompletion(_ completion: Subscribers.Completion<Error>) {
        switch completion {
        case let .failure(error):
            if case .invalidUsernameOrPassword = error as? AuthenticationError,
               let username = Current.defaults.string(forKey: "username") {
                // remove any keychain password if we fail to log with an invalid username or password so it doesn't try again.
                try? Current.keychain.remove(username)
            }

            // This error message is not user friendly... need to extract some meaningful data in the different cases
            self.authError = AlertContent(title: "Error signing in", message: error.legibleLocalizedDescription)
        case .finished:
            switch self.authenticationState {
            case .authenticated, .unauthenticated:
                self.presentingSignInAlert = false
                self.secondFactorData = nil
            case let .waitingForSecondFactor(option, authOptions, sessionData):
                self.handleTwoFactorOption(option, authOptions: authOptions, serviceKey: sessionData.serviceKey, sessionID: sessionData.sessionID, scnt: sessionData.scnt)
            }
        }
    }
    
    func signOut() {
        let username = Current.defaults.string(forKey: "username")
        Current.defaults.removeObject(forKey: "username")
        if let username = username {
            try? Current.keychain.remove(username)
        }
        AppleAPI.Current.network.session.configuration.httpCookieStorage?.removeCookies(since: .distantPast)
        authenticationState = .unauthenticated
    }
    
    // MARK: - Helper
    
    func installHelper() {
        Current.helper.install()
        checkIfHelperIsInstalled()
    }
    
    private func checkIfHelperIsInstalled() {
        helperInstallState = .unknown

        Current.helper.checkIfLatestHelperIsInstalled()
            .receive(on: DispatchQueue.main)
            .sink(
                receiveValue: { installed in
                    self.helperInstallState = installed ? .installed : .notInstalled
                }
            )
            .store(in: &cancellables)
    }
    
    // MARK: - Install
    
    func install(id: Xcode.ID) {
        // TODO:
    }
    
    // MARK: - Uninstall
    func uninstall(id: Xcode.ID) {
        guard
            let installedXcode = Current.files.installedXcodes(Path.root/"Applications").first(where: { $0.version == id }),
            uninstallPublisher == nil
        else { return }
        
        uninstallPublisher = uninstallXcode(path: installedXcode.path)
            .flatMap { [unowned self] _ in
                self.updateSelectedXcodePath()
            }
            .sink(
                receiveCompletion: { [unowned self] completion in
                    if case let .failure(error) = completion {
                        self.error = AlertContent(title: "Error uninstalling Xcode", message: error.legibleLocalizedDescription)
                    }
                    self.uninstallPublisher = nil
                },
                receiveValue: { _ in }
        )
    }
    
    func reveal(id: Xcode.ID) {
        // TODO: show error if not
        guard let installedXcode = Current.files.installedXcodes(Path.root/"Applications").first(where: { $0.version == id }) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([installedXcode.path.url])
    }

    func select(id: Xcode.ID) {
        if helperInstallState == .notInstalled {
            installHelper()
        }

        guard 
            let installedXcode = Current.files.installedXcodes(Path.root/"Applications").first(where: { $0.version == id }),
            selectPublisher == nil
        else { return }
        
        selectPublisher = HelperClient().switchXcodePath(installedXcode.path.string)
            .flatMap { [unowned self] _ in
                self.updateSelectedXcodePath()
            }
            .sink(
                receiveCompletion: { [unowned self] completion in
                    if case let .failure(error) = completion {
                        self.error = AlertContent(title: "Error selecting Xcode", message: error.legibleLocalizedDescription)
                    }
                    self.selectPublisher = nil
                },
                receiveValue: { _ in }
            )
    }
    
    func open(id: Xcode.ID) {
        guard let installedXcode = Current.files.installedXcodes(Path.root/"Applications").first(where: { $0.version == id }) else { return }
        NSWorkspace.shared.openApplication(at: installedXcode.path.url, configuration: .init())
    }
    
    func copyPath(id: Xcode.ID) {
        guard let installedXcode = Current.files.installedXcodes(Path.root/"Applications").first(where: { $0.version == id }) else { return }
        NSPasteboard.general.declareTypes([.URL, .string], owner: nil)
        NSPasteboard.general.writeObjects([installedXcode.path.url as NSURL])
        NSPasteboard.general.setString(installedXcode.path.string, forType: .string)
    }
    
    // MARK: - Private
    
    private func updateAllXcodes(availableXcodes: [AvailableXcode], selectedXcodePath: String?) {
        let installedXcodes = Current.files.installedXcodes(Path.root/"Applications")
        var allXcodeVersions = availableXcodes.map { $0.version }
        for installedXcode in installedXcodes {
            // If an installed version isn't listed online, add the installed version
            if !allXcodeVersions.contains(where: { version in
                version.isEquivalentForDeterminingIfInstalled(toInstalled: installedXcode.version)
            }) {
                allXcodeVersions.append(installedXcode.version)
            }
            // If an installed version is the same as one that's listed online which doesn't have build metadata, replace it with the installed version with build metadata
            else if let index = allXcodeVersions.firstIndex(where: { version in
                version.isEquivalentForDeterminingIfInstalled(toInstalled: installedXcode.version) &&
                version.buildMetadataIdentifiers.isEmpty
            }) {
                allXcodeVersions[index] = installedXcode.version
            }
        }

        allXcodes = allXcodeVersions
            .sorted(by: >)
            .map { xcodeVersion in
                let installedXcode = installedXcodes.first(where: { xcodeVersion.isEquivalentForDeterminingIfInstalled(toInstalled: $0.version) })
                let availableXcode = availableXcodes.first { $0.version == xcodeVersion }
                return Xcode(
                    version: xcodeVersion,
                    installState: installedXcode != nil ? .installed : .notInstalled,
                    selected: installedXcode != nil && selectedXcodePath?.hasPrefix(installedXcode!.path.string) == true, 
                    path: installedXcode?.path.string,
                    icon: (installedXcode?.path.string).map(NSWorkspace.shared.icon(forFile:)),
                    requiredMacOSVersion: availableXcode?.requiredMacOSVersion,
                    releaseNotesURL: availableXcode?.releaseNotesURL,
                    sdks: availableXcode?.sdks,
                    compilers: availableXcode?.compilers
                )
            }
    }
    
    
    private func uninstallXcode(path: Path) -> AnyPublisher<Void, Error> {
        return Deferred {
            Future { promise in
                do {
                    try Current.files.trashItem(at: path.url)
                    promise(.success(()))
                } catch {
                    promise(.failure(error))
                }
            }
        }
        .eraseToAnyPublisher()
    }

    // MARK: - Nested Types

    enum HelperInstallState: Equatable {
        case unknown
        case notInstalled
        case installed
    }

    struct AlertContent: Identifiable {
        var title: String
        var message: String
        var id: String { title + message }
    }

    struct SecondFactorData {
        let option: TwoFactorOption
        let authOptions: AuthOptionsResponse
        let sessionData: AppleSessionData
    }
}
