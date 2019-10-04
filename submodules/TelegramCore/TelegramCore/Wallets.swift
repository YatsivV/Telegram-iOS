import Foundation
#if os(macOS)
import PostboxMac
import SwiftSignalKitMac
import MtProtoKitMac
import TelegramApiMac
#else
import Postbox
import SwiftSignalKit
import MtProtoKit
import TelegramApi
#endif

public struct TonKeychainEncryptedData: Codable, Equatable {
    public let publicKey: Data
    public let data: Data
    
    public init(publicKey: Data, data: Data) {
        self.publicKey = publicKey
        self.data = data
    }
}

public enum TonKeychainEncryptDataError {
    case generic
}

public enum TonKeychainDecryptDataError {
    case generic
    case publicKeyMismatch
    case cancelled
}

public struct TonKeychain {
    public let encryptionPublicKey: () -> Signal<Data?, NoError>
    public let encrypt: (Data) -> Signal<TonKeychainEncryptedData, TonKeychainEncryptDataError>
    public let decrypt: (TonKeychainEncryptedData) -> Signal<Data, TonKeychainDecryptDataError>
    
    public init(encryptionPublicKey: @escaping () -> Signal<Data?, NoError>, encrypt: @escaping (Data) -> Signal<TonKeychainEncryptedData, TonKeychainEncryptDataError>, decrypt: @escaping (TonKeychainEncryptedData) -> Signal<Data, TonKeychainDecryptDataError>) {
        self.encryptionPublicKey = encryptionPublicKey
        self.encrypt = encrypt
        self.decrypt = decrypt
    }
}

private final class TonInstanceImpl {
    private let queue: Queue
    private let basePath: String
    private let config: String
    private let blockchainName: String
    private let network: Network?
    private var instance: TON?
    
    init(queue: Queue, basePath: String, config: String, blockchainName: String, network: Network?) {
        self.queue = queue
        self.basePath = basePath
        self.config = config
        self.blockchainName = blockchainName
        self.network = network
    }
    
    func withInstance(_ f: (TON) -> Void) {
        let instance: TON
        if let current = self.instance {
            instance = current
        } else {
            let network = self.network
            instance = TON(keystoreDirectory: self.basePath + "/ton-keystore", config: self.config, blockchainName: self.blockchainName, performExternalRequest: { request in
                if let network = network {
                    Logger.shared.log("TON Proxy", "request: \(request.data.count)")
                    let _ = (
                        network.request(Api.functions.wallet.sendLiteRequest(body: Buffer(data: request.data)))
                        |> timeout(20.0, queue: .concurrentDefaultQueue(), alternate: .fail(MTRpcError(errorCode: 500, errorDescription: "NETWORK_ERROR")))
                    ).start(next: { result in
                        switch result {
                        case let .liteResponse(response):
                            let data = response.makeData()
                            Logger.shared.log("TON Proxy", "response: \(data.count)")
                            request.onResult(data, nil)
                        }
                    }, error: { error in
                        request.onResult(nil, error.errorDescription)
                    })
                } else {
                    request.onResult(nil, "NETWORK_DISABLED")
                }
            }, enableExternalRequests: network != nil)
            self.instance = instance
        }
        f(instance)
    }
}

public final class TonInstance {
    private let queue: Queue
    private let impl: QueueLocalObject<TonInstanceImpl>
    
    public init(basePath: String, config: String, blockchainName: String, network: Network?) {
        self.queue = .mainQueue()
        let queue = self.queue
        self.impl = QueueLocalObject(queue: queue, generate: {
            return TonInstanceImpl(queue: queue, basePath: basePath, config: config, blockchainName: blockchainName, network: network)
        })
    }
    
    fileprivate func exportKey(key: TONKey, localPassword: Data) -> Signal<[String], NoError> {
        return Signal { subscriber in
            let disposable = MetaDisposable()
            
            self.impl.with { impl in
                impl.withInstance { ton in
                    let cancel = ton.export(key, localPassword: localPassword).start(next: { wordList in
                        guard let wordList = wordList as? [String] else {
                            assertionFailure()
                            return
                        }
                        subscriber.putNext(wordList)
                        subscriber.putCompletion()
                    })
                    disposable.set(ActionDisposable {
                        cancel?.dispose()
                    })
                }
            }
            
            return disposable
        }
    }
    
    fileprivate func createWallet(keychain: TonKeychain, localPassword: Data) -> Signal<(WalletInfo, [String]), CreateWalletError> {
        return Signal { subscriber in
            let disposable = MetaDisposable()
            self.impl.with { impl in
                impl.withInstance { ton in
                    let cancel = ton.createKey(withLocalPassword: localPassword, mnemonicPassword: Data()).start(next: { key in
                        guard let key = key as? TONKey else {
                            assertionFailure()
                            return
                        }
                        let cancel = keychain.encrypt(key.secret).start(next: { encryptedSecretData in
                            let _ = self.exportKey(key: key, localPassword: localPassword).start(next: { wordList in
                                subscriber.putNext((WalletInfo(publicKey: WalletPublicKey(rawValue: key.publicKey), encryptedSecret: encryptedSecretData), wordList))
                                subscriber.putCompletion()
                            }, error: { error in
                                subscriber.putError(.generic)
                            })
                        }, error: { _ in
                            subscriber.putError(.generic)
                        }, completed: {
                        })
                    }, error: { _ in
                    }, completed: {
                    })
                    disposable.set(ActionDisposable {
                        cancel?.dispose()
                    })
                }
            }
            
            return disposable
        }
    }
    
    fileprivate func importWallet(keychain: TonKeychain, wordList: [String], localPassword: Data) -> Signal<WalletInfo, ImportWalletInternalError> {
        return Signal { subscriber in
            let disposable = MetaDisposable()
            
            self.impl.with { impl in
                impl.withInstance { ton in
                    let cancel = ton.importKey(withLocalPassword: localPassword, mnemonicPassword: Data(), wordList: wordList).start(next: { key in
                        guard let key = key as? TONKey else {
                            subscriber.putError(.generic)
                            return
                        }
                        let cancel = keychain.encrypt(key.secret).start(next: { encryptedSecretData in
                            subscriber.putNext(WalletInfo(publicKey: WalletPublicKey(rawValue: key.publicKey), encryptedSecret: encryptedSecretData))
                            subscriber.putCompletion()
                        }, error: { _ in
                            subscriber.putError(.generic)
                        }, completed: {
                        })
                    }, error: { _ in
                        subscriber.putError(.generic)
                    }, completed: {
                    })
                    disposable.set(ActionDisposable {
                        cancel?.dispose()
                    })
                }
            }
            
            return disposable
        }
    }
    
    fileprivate func walletAddress(publicKey: WalletPublicKey) -> Signal<String, NoError> {
        return Signal { subscriber in
            let disposable = MetaDisposable()
            
            self.impl.with { impl in
                impl.withInstance { ton in
                    let cancel = ton.getWalletAccountAddress(withPublicKey: publicKey.rawValue).start(next: { address in
                        guard let address = address as? String else {
                            return
                        }
                        subscriber.putNext(address)
                        subscriber.putCompletion()
                    }, error: { _ in
                    }, completed: {
                    })
                    disposable.set(ActionDisposable {
                        cancel?.dispose()
                    })
                }
            }
            
            return disposable
        }
    }
    
    private func getWalletStateRaw(address: String) -> Signal<TONAccountState, GetWalletStateError> {
        return Signal { subscriber in
            let disposable = MetaDisposable()
            
            self.impl.with { impl in
                impl.withInstance { ton in
                    let cancel = ton.getAccountState(withAddress: address).start(next: { state in
                        guard let state = state as? TONAccountState else {
                            return
                        }
                        subscriber.putNext(state)
                    }, error: { error in
                        if let error = error as? TONError {
                            if error.text.hasPrefix("LITE_SERVER_") {
                                subscriber.putError(.network)
                            } else {
                                subscriber.putError(.generic)
                            }
                        } else {
                            subscriber.putError(.generic)
                        }
                    }, completed: {
                        subscriber.putCompletion()
                    })
                    disposable.set(ActionDisposable {
                        cancel?.dispose()
                    })
                }
            }
            
            return disposable
        }
    }
    
    fileprivate func getWalletState(address: String) -> Signal<(WalletState, Int64), GetWalletStateError> {
        return self.getWalletStateRaw(address: address)
        |> map { state in
            return (WalletState(balance: state.balance, lastTransactionId: state.lastTransactionId.flatMap(WalletTransactionId.init(tonTransactionId:))), state.syncUtime)
        }
    }
    
    fileprivate func walletLastTransactionId(address: String) -> Signal<WalletTransactionId?, WalletLastTransactionIdError> {
        return Signal { subscriber in
            let disposable = MetaDisposable()
            
            self.impl.with { impl in
                impl.withInstance { ton in
                    let cancel = ton.getAccountState(withAddress: address).start(next: { state in
                        guard let state = state as? TONAccountState else {
                            subscriber.putNext(nil)
                            return
                        }
                        subscriber.putNext(state.lastTransactionId.flatMap(WalletTransactionId.init(tonTransactionId:)))
                    }, error: { error in
                        if let error = error as? TONError {
                            if error.text.hasPrefix("ДITE_SERVER_") {
                                subscriber.putError(.network)
                            } else {
                                subscriber.putError(.generic)
                            }
                        } else {
                            subscriber.putError(.generic)
                        }
                    }, completed: {
                        subscriber.putCompletion()
                    })
                    disposable.set(ActionDisposable {
                        cancel?.dispose()
                    })
                }
            }
            
            return disposable
        }
    }
    
    fileprivate func getWalletTransactions(address: String, previousId: WalletTransactionId) -> Signal<[WalletTransaction], GetWalletTransactionsError> {
        return Signal { subscriber in
            let disposable = MetaDisposable()
            
            self.impl.with { impl in
                impl.withInstance { ton in
                    let cancel = ton.getTransactionList(withAddress: address, lt: previousId.lt, hash: previousId.transactionHash).start(next: { transactions in
                        guard let transactions = transactions as? [TONTransaction] else {
                            subscriber.putError(.generic)
                            return
                        }
                        subscriber.putNext(transactions.map(WalletTransaction.init(tonTransaction:)))
                    }, error: { error in
                        if let error = error as? TONError {
                            if error.text.hasPrefix("LITE_SERVER_") {
                                subscriber.putError(.network)
                            } else {
                                subscriber.putError(.generic)
                            }
                        } else {
                            subscriber.putError(.generic)
                        }
                    }, completed: {
                        subscriber.putCompletion()
                    })
                    disposable.set(ActionDisposable {
                        cancel?.dispose()
                    })
                }
            }
            
            return disposable
        }
    }
    
    fileprivate func sendGramsFromWallet(decryptedSecret: Data, localPassword: Data, walletInfo: WalletInfo, fromAddress: String, toAddress: String, amount: Int64, textMessage: Data, forceIfDestinationNotInitialized: Bool, timeout: Int32, randomId: Int64) -> Signal<PendingWalletTransaction, SendGramsFromWalletError> {
        let key = TONKey(publicKey: walletInfo.publicKey.rawValue, secret: decryptedSecret)
        return Signal { subscriber in
            let disposable = MetaDisposable()
            
            self.impl.with { impl in
                impl.withInstance { ton in
                    let cancel = ton.sendGrams(from: key, localPassword: localPassword, fromAddress: fromAddress, toAddress: toAddress, amount: amount, textMessage: textMessage, forceIfDestinationNotInitialized: forceIfDestinationNotInitialized, timeout: timeout, randomId: randomId).start(next: { result in
                        guard let result = result as? TONSendGramsResult else {
                            subscriber.putError(.generic)
                            return
                        }
                        subscriber.putNext(PendingWalletTransaction(timestamp: Int64(Date().timeIntervalSince1970), validUntilTimestamp: result.sentUntil, bodyHash: result.bodyHash, address: toAddress, value: amount, comment: textMessage))
                        subscriber.putCompletion()
                    }, error: { error in
                        if let error = error as? TONError {
                            if error.text.hasPrefix("INVALID_ACCOUNT_ADDRESS") {
                                subscriber.putError(.invalidAddress)
                            } else if error.text.hasPrefix("DANGEROUS_TRANSACTION") {
                                subscriber.putError(.destinationIsNotInitialized)
                            } else if error.text.hasPrefix("MESSAGE_TOO_LONG") {
                                subscriber.putError(.messageTooLong)
                            } else if error.text.hasPrefix("NOT_ENOUGH_FUNDS") {
                                subscriber.putError(.notEnoughFunds)
                            } else if error.text.hasPrefix("LITE_SERVER_") {
                                subscriber.putError(.network)
                            } else {
                                subscriber.putError(.generic)
                            }
                        } else {
                            subscriber.putError(.generic)
                        }
                    }, completed: {
                        subscriber.putCompletion()
                    })
                    disposable.set(ActionDisposable {
                        cancel?.dispose()
                    })
                }
            }
            
            return disposable
        }
    }
    
    fileprivate func walletRestoreWords(publicKey: WalletPublicKey, decryptedSecret: Data, localPassword: Data) -> Signal<[String], WalletRestoreWordsError> {
        return Signal { subscriber in
            let disposable = MetaDisposable()
            
            self.impl.with { impl in
                impl.withInstance { ton in
                    let cancel = ton.export(TONKey(publicKey: publicKey.rawValue, secret: decryptedSecret), localPassword: localPassword).start(next: { wordList in
                        guard let wordList = wordList as? [String] else {
                            subscriber.putError(.generic)
                            return
                        }
                        subscriber.putNext(wordList)
                    }, error: { _ in
                        subscriber.putError(.generic)
                    }, completed: {
                        subscriber.putCompletion()
                    })
                    disposable.set(ActionDisposable {
                        cancel?.dispose()
                    })
                }
            }
            
            return disposable
        }
    }
    
    fileprivate func deleteAllLocalWalletsData() -> Signal<Never, DeleteAllLocalWalletsDataError> {
        return Signal { subscriber in
            let disposable = MetaDisposable()
            
            self.impl.with { impl in
                impl.withInstance { ton in
                    let cancel = ton.deleteAllKeys().start(next: { _ in
                        assertionFailure()
                    }, error: { _ in
                        subscriber.putError(.generic)
                    }, completed: {
                        subscriber.putCompletion()
                    })
                    disposable.set(ActionDisposable {
                        cancel?.dispose()
                    })
                }
            }
            
            return disposable
        }
    }
    fileprivate func encrypt(_ decryptedData: Data, secret: Data) -> Signal<Data, NoError> {
        return Signal { subscriber in
            let disposable = MetaDisposable()
            
            self.impl.with { impl in
                impl.withInstance { ton in
                    subscriber.putNext(ton.encrypt(decryptedData, secret: secret))
                    subscriber.putCompletion()
                }
            }
            
            return disposable
        }
    }
    fileprivate func decrypt(_ encryptedData: Data, secret: Data) -> Signal<Data?, NoError> {
        return Signal { subscriber in
            let disposable = MetaDisposable()
            
            self.impl.with { impl in
                impl.withInstance { ton in
                    subscriber.putNext(ton.decrypt(encryptedData, secret: secret))
                    subscriber.putCompletion()
                }
            }
            
            return disposable
        }
    }
}

public struct WalletPublicKey: Codable, Hashable {
    public var rawValue: String
    
    public init(rawValue: String) {
        self.rawValue = rawValue
    }
}

public struct WalletInfo: PostboxCoding, Codable, Equatable {
    public let publicKey: WalletPublicKey
    public let encryptedSecret: TonKeychainEncryptedData
    
    public init(publicKey: WalletPublicKey, encryptedSecret: TonKeychainEncryptedData) {
        self.publicKey = publicKey
        self.encryptedSecret = encryptedSecret
    }
    
    public init(decoder: PostboxDecoder) {
        self.publicKey = WalletPublicKey(rawValue: decoder.decodeStringForKey("publicKey", orElse: ""))
        if let publicKey = decoder.decodeDataForKey("encryptedSecretPublicKey"), let secret = decoder.decodeDataForKey("encryptedSecretData") {
            self.encryptedSecret = TonKeychainEncryptedData(publicKey: publicKey, data: secret)
        } else {
            self.encryptedSecret = TonKeychainEncryptedData(publicKey: Data(), data: Data())
        }
    }
    
    public func encode(_ encoder: PostboxEncoder) {
        encoder.encodeString(self.publicKey.rawValue, forKey: "publicKey")
        encoder.encodeData(self.encryptedSecret.publicKey, forKey: "encryptedSecretPublicKey")
        encoder.encodeData(self.encryptedSecret.data, forKey: "encryptedSecretData")
    }
}

public struct CombinedWalletState: Codable, Equatable {
    public var walletState: WalletState
    public var timestamp: Int64
    public var topTransactions: [WalletTransaction]
    public var pendingTransactions: [PendingWalletTransaction]
}

public struct WalletStateRecord: PostboxCoding, Equatable {
    public let info: WalletInfo
    public var exportCompleted: Bool
    public var state: CombinedWalletState?
    
    public init(info: WalletInfo, exportCompleted: Bool, state: CombinedWalletState?) {
        self.info = info
        self.exportCompleted = exportCompleted
        self.state = state
    }
    
    public init(decoder: PostboxDecoder) {
        self.info = decoder.decodeDataForKey("info").flatMap { data in
            return try? JSONDecoder().decode(WalletInfo.self, from: data)
        } ?? WalletInfo(publicKey: WalletPublicKey(rawValue: ""), encryptedSecret: TonKeychainEncryptedData(publicKey: Data(), data: Data()))
        self.exportCompleted = decoder.decodeInt32ForKey("exportCompleted", orElse: 0) != 0
        self.state = decoder.decodeDataForKey("state").flatMap { data in
            return try? JSONDecoder().decode(CombinedWalletState.self, from: data)
        }
    }
    
    public func encode(_ encoder: PostboxEncoder) {
        if let data = try? JSONEncoder().encode(self.info) {
            encoder.encodeData(data, forKey: "info")
        }
        encoder.encodeInt32(self.exportCompleted ? 1 : 0, forKey: "exportCompleted")
        if let state = self.state, let data = try? JSONEncoder().encode(state) {
            encoder.encodeData(data, forKey: "state")
        } else {
            encoder.encodeNil(forKey: "state")
        }
    }
}

public struct WalletCollection: PreferencesEntry {
    public var wallets: [WalletStateRecord]
    
    public init(wallets: [WalletStateRecord]) {
        self.wallets = wallets
    }
    
    public init(decoder: PostboxDecoder) {
        var wallets: [WalletStateRecord] = decoder.decodeObjectArrayWithDecoderForKey("wallets")
        for i in (0 ..< wallets.count).reversed() {
            if wallets[i].info.publicKey.rawValue.isEmpty {
                wallets.remove(at: i)
            }
        }
        self.wallets = wallets
    }
    
    public func encode(_ encoder: PostboxEncoder) {
        encoder.encodeObjectArray(self.wallets, forKey: "wallets")
    }
    
    public func isEqual(to: PreferencesEntry) -> Bool {
        guard let other = to as? WalletCollection else {
            return false
        }
        if self.wallets != other.wallets {
            return false
        }
        return true
    }
}

public func availableWallets(postbox: Postbox) -> Signal<WalletCollection, NoError> {
    return postbox.transaction { transaction -> WalletCollection in
        return (transaction.getPreferencesEntry(key: PreferencesKeys.walletCollection) as? WalletCollection) ?? WalletCollection(wallets: [])
    }
}

public enum CreateWalletError {
    case generic
}

public func tonlibEncrypt(tonInstance: TonInstance, decryptedData: Data, secret: Data) -> Signal<Data, NoError> {
    return tonInstance.encrypt(decryptedData, secret: secret)
}
public func tonlibDecrypt(tonInstance: TonInstance, encryptedData: Data, secret: Data) -> Signal<Data?, NoError> {
    return tonInstance.decrypt(encryptedData, secret: secret)
}

public func createWallet(postbox: Postbox, tonInstance: TonInstance, keychain: TonKeychain, localPassword: Data) -> Signal<(WalletInfo, [String]), CreateWalletError> {
    return tonInstance.createWallet(keychain: keychain, localPassword: localPassword)
    |> mapToSignal { walletInfo, wordList -> Signal<(WalletInfo, [String]), CreateWalletError> in
        return postbox.transaction { transaction -> (WalletInfo, [String]) in
            transaction.updatePreferencesEntry(key: PreferencesKeys.walletCollection, { current in
                var walletCollection = (current as? WalletCollection) ?? WalletCollection(wallets: [])
                walletCollection.wallets = [WalletStateRecord(info: walletInfo, exportCompleted: false, state: nil)]
                return walletCollection
            })
            return (walletInfo, wordList)
        }
        |> castError(CreateWalletError.self)
    }
}

public func confirmWalletExported(postbox: Postbox, walletInfo: WalletInfo) -> Signal<Never, NoError> {
    return postbox.transaction { transaction -> Void in
        transaction.updatePreferencesEntry(key: PreferencesKeys.walletCollection, { current in
            var walletCollection = (current as? WalletCollection) ?? WalletCollection(wallets: [])
            for i in 0 ..< walletCollection.wallets.count {
                if walletCollection.wallets[i].info.publicKey == walletInfo.publicKey {
                    walletCollection.wallets[i].exportCompleted = true
                }
            }
            return walletCollection
        })
    }
    |> ignoreValues
}

private enum ImportWalletInternalError {
    case generic
}

public enum ImportWalletError {
    case generic
}

public func importWallet(postbox: Postbox, tonInstance: TonInstance, keychain: TonKeychain, wordList: [String], localPassword: Data) -> Signal<WalletInfo, ImportWalletError> {
    return tonInstance.importWallet(keychain: keychain, wordList: wordList, localPassword: localPassword)
    |> `catch` { error -> Signal<WalletInfo, ImportWalletError> in
        switch error {
        case .generic:
            return .fail(.generic)
        }
    }
    |> mapToSignal { walletInfo -> Signal<WalletInfo, ImportWalletError> in
        return postbox.transaction { transaction -> WalletInfo in
            transaction.updatePreferencesEntry(key: PreferencesKeys.walletCollection, { current in
                var walletCollection = (current as? WalletCollection) ?? WalletCollection(wallets: [])
                walletCollection.wallets = [WalletStateRecord(info: walletInfo, exportCompleted: true, state: nil)]
                return walletCollection
            })
            return walletInfo
        }
        |> castError(ImportWalletError.self)
    }
}

public enum DeleteAllLocalWalletsDataError {
    case generic
}

public func deleteAllLocalWalletsData(postbox: Postbox, network: Network, tonInstance: TonInstance) -> Signal<Never, DeleteAllLocalWalletsDataError> {
    return tonInstance.deleteAllLocalWalletsData()
    |> then(
        postbox.transaction { transaction -> Void in
            transaction.updatePreferencesEntry(key: PreferencesKeys.walletCollection, { current in
                let walletCollection = WalletCollection(wallets: [])
                return walletCollection
            })
        }
        |> castError(DeleteAllLocalWalletsDataError.self)
        |> ignoreValues
    )
}

public enum WalletRestoreWordsError {
    case generic
}

public func walletRestoreWords(tonInstance: TonInstance, publicKey: WalletPublicKey, decryptedSecret: Data, localPassword: Data) -> Signal<[String], WalletRestoreWordsError> {
    return tonInstance.walletRestoreWords(publicKey: publicKey, decryptedSecret: decryptedSecret, localPassword: localPassword)
}

public struct WalletState: Codable, Equatable {
    public let balance: Int64
    public let lastTransactionId: WalletTransactionId?
    
    public init(balance: Int64, lastTransactionId: WalletTransactionId?) {
        self.balance = balance
        self.lastTransactionId = lastTransactionId
    }
}

public func walletAddress(publicKey: WalletPublicKey, tonInstance: TonInstance) -> Signal<String, NoError> {
    return tonInstance.walletAddress(publicKey: publicKey)
}

private enum GetWalletStateError {
    case generic
    case network
}

private func getWalletState(address: String, tonInstance: TonInstance) -> Signal<(WalletState, Int64), GetWalletStateError> {
    return tonInstance.getWalletState(address: address)
}

public enum GetCombinedWalletStateError {
    case generic
    case network
}

public enum CombinedWalletStateResult {
    case cached(CombinedWalletState?)
    case updated(CombinedWalletState)
}

public enum CombinedWalletStateSubject {
    case wallet(WalletInfo)
    case address(String)
}

public func getCombinedWalletState(postbox: Postbox, subject: CombinedWalletStateSubject, tonInstance: TonInstance, onlyCached: Bool = false) -> Signal<CombinedWalletStateResult, GetCombinedWalletStateError> {
    switch subject {
    case let .wallet(walletInfo):
        return postbox.transaction { transaction -> CombinedWalletState? in
            let walletCollection = (transaction.getPreferencesEntry(key: PreferencesKeys.walletCollection) as? WalletCollection) ?? WalletCollection(wallets: [])
            for item in walletCollection.wallets {
                if item.info.publicKey == walletInfo.publicKey {
                    return item.state
                }
            }
            return nil
        }
        |> castError(GetCombinedWalletStateError.self)
        |> mapToSignal { cachedState -> Signal<CombinedWalletStateResult, GetCombinedWalletStateError> in
            if onlyCached {
                return .single(.cached(cachedState))
            }
            return .single(.cached(cachedState))
            |> then(
                tonInstance.walletAddress(publicKey: walletInfo.publicKey)
                |> castError(GetCombinedWalletStateError.self)
                |> mapToSignal { address -> Signal<CombinedWalletStateResult, GetCombinedWalletStateError> in
                    return getWalletState(address: address, tonInstance: tonInstance)
                    |> retryTonRequest(isNetworkError: { error in
                        if case .network = error {
                            return true
                        } else {
                            return false
                        }
                    })
                    |> mapError { error -> GetCombinedWalletStateError in
                        if case .network = error {
                            return .network
                        } else {
                            return .generic
                        }
                    }
                    |> mapToSignal { walletState, syncUtime -> Signal<CombinedWalletStateResult, GetCombinedWalletStateError> in
                        let topTransactions: Signal<[WalletTransaction], GetCombinedWalletStateError>
                        if walletState.lastTransactionId == cachedState?.walletState.lastTransactionId {
                            topTransactions = .single(cachedState?.topTransactions ?? [])
                        } else {
                            topTransactions = getWalletTransactions(address: address, previousId: nil, tonInstance: tonInstance)
                            |> mapError { error -> GetCombinedWalletStateError in
                                if case .network = error {
                                    return .network
                                } else {
                                    return .generic
                                }
                            }
                        }
                        return topTransactions
                        |> mapToSignal { topTransactions -> Signal<CombinedWalletStateResult, GetCombinedWalletStateError> in
                            let lastTransactionTimestamp = topTransactions.last?.timestamp
                            var listTransactionBodyHashes = Set<Data>()
                            for transaction in topTransactions {
                                if let message = transaction.inMessage {
                                    listTransactionBodyHashes.insert(message.bodyHash)
                                }
                                for message in transaction.outMessages {
                                    listTransactionBodyHashes.insert(message.bodyHash)
                                }
                            }
                            let pendingTransactions = (cachedState?.pendingTransactions ?? []).filter { transaction in
                                if transaction.validUntilTimestamp <= syncUtime {
                                    return false
                                } else if let lastTransactionTimestamp = lastTransactionTimestamp, transaction.validUntilTimestamp <= lastTransactionTimestamp {
                                    return false
                                } else {
                                    if listTransactionBodyHashes.contains(transaction.bodyHash) {
                                        return false
                                    }
                                    return true
                                }
                            }
                            let combinedState = CombinedWalletState(walletState: walletState, timestamp: syncUtime, topTransactions: topTransactions, pendingTransactions: pendingTransactions)
                            return postbox.transaction { transaction -> CombinedWalletStateResult in
                                transaction.updatePreferencesEntry(key: PreferencesKeys.walletCollection, { current in
                                    var walletCollection = (current as? WalletCollection) ?? WalletCollection(wallets: [])
                                    for i in 0 ..< walletCollection.wallets.count {
                                        if walletCollection.wallets[i].info.publicKey == walletInfo.publicKey {
                                            walletCollection.wallets[i].state = combinedState
                                        }
                                    }
                                    return walletCollection
                                })
                                return .updated(combinedState)
                            }
                            |> castError(GetCombinedWalletStateError.self)
                        }
                    }
                }
            )
        }
    case let .address(address):
        let updated = getWalletState(address: address, tonInstance: tonInstance)
        |> mapError { _ -> GetCombinedWalletStateError in
            return .generic
        }
        |> mapToSignal { walletState, syncUtime -> Signal<CombinedWalletStateResult, GetCombinedWalletStateError> in
            let topTransactions: Signal<[WalletTransaction], GetCombinedWalletStateError>
            
            topTransactions = getWalletTransactions(address: address, previousId: nil, tonInstance: tonInstance)
            |> mapError { _ -> GetCombinedWalletStateError in
                return .generic
            }
            return topTransactions
            |> mapToSignal { topTransactions -> Signal<CombinedWalletStateResult, GetCombinedWalletStateError> in
                let combinedState = CombinedWalletState(walletState: walletState, timestamp: syncUtime, topTransactions: topTransactions, pendingTransactions: [])
                return .single(.updated(combinedState))
            }
        }
        return .single(.cached(nil))
        |> then(updated)
    }
}

public enum SendGramsFromWalletError {
    case generic
    case secretDecryptionFailed
    case invalidAddress
    case destinationIsNotInitialized
    case messageTooLong
    case notEnoughFunds
    case network
}

public func sendGramsFromWallet(postbox: Postbox, network: Network, tonInstance: TonInstance, walletInfo: WalletInfo, decryptedSecret: Data, localPassword: Data, toAddress: String, amount: Int64, textMessage: Data, forceIfDestinationNotInitialized: Bool, timeout: Int32, randomId: Int64) -> Signal<[PendingWalletTransaction], SendGramsFromWalletError> {
    return walletAddress(publicKey: walletInfo.publicKey, tonInstance: tonInstance)
    |> castError(SendGramsFromWalletError.self)
    |> mapToSignal { fromAddress -> Signal<[PendingWalletTransaction], SendGramsFromWalletError> in
        return tonInstance.sendGramsFromWallet(decryptedSecret: decryptedSecret, localPassword: localPassword, walletInfo: walletInfo, fromAddress: fromAddress, toAddress: toAddress, amount: amount, textMessage: textMessage, forceIfDestinationNotInitialized: forceIfDestinationNotInitialized, timeout: timeout, randomId: randomId)
        |> mapToSignal { result -> Signal<[PendingWalletTransaction], SendGramsFromWalletError> in
            return postbox.transaction { transaction -> [PendingWalletTransaction] in
                var updatedPendingTransactions: [PendingWalletTransaction] = []
                transaction.updatePreferencesEntry(key: PreferencesKeys.walletCollection, { current in
                    var walletCollection = (current as? WalletCollection) ?? WalletCollection(wallets: [])
                    for i in 0 ..< walletCollection.wallets.count {
                        if walletCollection.wallets[i].info.publicKey == walletInfo.publicKey {
                            if var state = walletCollection.wallets[i].state {
                                state.pendingTransactions.insert(result, at: 0)
                                walletCollection.wallets[i].state = state
                                updatedPendingTransactions = state.pendingTransactions
                            }
                        }
                    }
                    return walletCollection
                })
                return updatedPendingTransactions
            }
            |> castError(SendGramsFromWalletError.self)
        }
    }
}

public struct WalletTransactionId: Codable, Hashable {
    public var lt: Int64
    public var transactionHash: Data
}

private extension WalletTransactionId {
    init(tonTransactionId: TONTransactionId) {
        self.lt = tonTransactionId.lt
        self.transactionHash = tonTransactionId.transactionHash
    }
}

public final class WalletTransactionMessage: Codable, Equatable {
    public let value: Int64
    public let source: String
    public let destination: String
    public let textMessage: String
    public let bodyHash: Data
    
    init(value: Int64, source: String, destination: String, textMessage: String, bodyHash: Data) {
        self.value = value
        self.source = source
        self.destination = destination
        self.textMessage = textMessage
        self.bodyHash = bodyHash
    }
    
    public static func ==(lhs: WalletTransactionMessage, rhs: WalletTransactionMessage) -> Bool {
        if lhs.value != rhs.value {
            return false
        }
        if lhs.source != rhs.source {
            return false
        }
        if lhs.destination != rhs.destination {
            return false
        }
        if lhs.textMessage != rhs.textMessage {
            return false
        }
        if lhs.bodyHash != rhs.bodyHash {
            return false
        }
        return true
    }
}

private extension WalletTransactionMessage {
    convenience init(tonTransactionMessage: TONTransactionMessage) {
        self.init(value: tonTransactionMessage.value, source: tonTransactionMessage.source, destination: tonTransactionMessage.destination, textMessage: tonTransactionMessage.textMessage, bodyHash: tonTransactionMessage.bodyHash)
    }
}

public final class PendingWalletTransaction: Codable, Equatable {
    public let timestamp: Int64
    public let validUntilTimestamp: Int64
    public let bodyHash: Data
    public let address: String
    public let value: Int64
    public let comment: Data
    
    public init(timestamp: Int64, validUntilTimestamp: Int64, bodyHash: Data, address: String, value: Int64, comment: Data) {
        self.timestamp = timestamp
        self.validUntilTimestamp = validUntilTimestamp
        self.bodyHash = bodyHash
        self.address = address
        self.value = value
        self.comment = comment
    }
    
    public static func ==(lhs: PendingWalletTransaction, rhs: PendingWalletTransaction) -> Bool {
        if lhs.timestamp != rhs.timestamp {
            return false
        }
        if lhs.validUntilTimestamp != rhs.validUntilTimestamp {
            return false
        }
        if lhs.bodyHash != rhs.bodyHash {
            return false
        }
        if lhs.value != rhs.value {
            return false
        }
        if lhs.comment != rhs.comment {
            return false
        }
        return true
    }
}

public final class WalletTransaction: Codable, Equatable {
    public let data: Data
    public let transactionId: WalletTransactionId
    public let timestamp: Int64
    public let storageFee: Int64
    public let otherFee: Int64
    public let inMessage: WalletTransactionMessage?
    public let outMessages: [WalletTransactionMessage]
    
    public var transferredValueWithoutFees: Int64 {
        var value: Int64 = 0
        if let inMessage = self.inMessage {
            value += inMessage.value
        }
        for message in self.outMessages {
            value -= message.value
        }
        return value
    }
    
    init(data: Data, transactionId: WalletTransactionId, timestamp: Int64, storageFee: Int64, otherFee: Int64, inMessage: WalletTransactionMessage?, outMessages: [WalletTransactionMessage]) {
        self.data = data
        self.transactionId = transactionId
        self.timestamp = timestamp
        self.storageFee = storageFee
        self.otherFee = otherFee
        self.inMessage = inMessage
        self.outMessages = outMessages
    }
    
    public static func ==(lhs: WalletTransaction, rhs: WalletTransaction) -> Bool {
        if lhs.data != rhs.data {
            return false
        }
        if lhs.transactionId != rhs.transactionId {
            return false
        }
        if lhs.timestamp != rhs.timestamp {
            return false
        }
        if lhs.storageFee != rhs.storageFee {
            return false
        }
        if lhs.otherFee != rhs.otherFee {
            return false
        }
        if lhs.inMessage != rhs.inMessage {
            return false
        }
        if lhs.outMessages != rhs.outMessages {
            return false
        }
        return true
    }
}

private extension WalletTransaction {
    convenience init(tonTransaction: TONTransaction) {
        self.init(data: tonTransaction.data, transactionId: WalletTransactionId(tonTransactionId: tonTransaction.transactionId), timestamp: tonTransaction.timestamp, storageFee: tonTransaction.storageFee, otherFee: tonTransaction.otherFee, inMessage: tonTransaction.inMessage.flatMap(WalletTransactionMessage.init(tonTransactionMessage:)), outMessages: tonTransaction.outMessages.map(WalletTransactionMessage.init(tonTransactionMessage:)))
    }
}

public enum GetWalletTransactionsError {
    case generic
    case network
}

public func getWalletTransactions(address: String, previousId: WalletTransactionId?, tonInstance: TonInstance) -> Signal<[WalletTransaction], GetWalletTransactionsError> {
    return getWalletTransactionsOnce(address: address, previousId: previousId, tonInstance: tonInstance)
    |> mapToSignal { transactions in
        guard let lastTransaction = transactions.last, transactions.count >= 2 else {
            return .single(transactions)
        }
        return getWalletTransactionsOnce(address: address, previousId: lastTransaction.transactionId, tonInstance: tonInstance)
        |> map { additionalTransactions in
            var result = transactions
            var existingIds = Set(result.map { $0.transactionId })
            for transaction in additionalTransactions {
                if !existingIds.contains(transaction.transactionId) {
                    existingIds.insert(transaction.transactionId)
                    result.append(transaction)
                }
            }
            return result
        }
    }
}

private func retryTonRequest<T, E>(isNetworkError: @escaping (E) -> Bool) -> (Signal<T, E>) -> Signal<T, E> {
    return { signal in
        return signal
        |> retry(retryOnError: isNetworkError, delayIncrement: 0.2, maxDelay: 5.0, maxRetries: 3, onQueue: Queue.concurrentDefaultQueue())
    }
}

private enum WalletLastTransactionIdError {
    case generic
    case network
}

private func getWalletTransactionsOnce(address: String, previousId: WalletTransactionId?, tonInstance: TonInstance) -> Signal<[WalletTransaction], GetWalletTransactionsError> {
    let previousIdValue: Signal<WalletTransactionId?, GetWalletTransactionsError>
    if let previousId = previousId {
        previousIdValue = .single(previousId)
    } else {
        previousIdValue = tonInstance.walletLastTransactionId(address: address)
        |> retryTonRequest(isNetworkError: { error in
            if case .network = error {
                return true
            } else {
                return false
            }
        })
        |> mapError { error -> GetWalletTransactionsError in
            if case .network = error {
                return .network
            } else {
                return .generic
            }
        }
    }
    return previousIdValue
    |> mapToSignal { previousId in
        if let previousId = previousId {
            return tonInstance.getWalletTransactions(address: address, previousId: previousId)
            |> retryTonRequest(isNetworkError: { error in
                if case .network = error {
                    return true
                } else {
                    return false
                }
            })
        } else {
            return .single([])
        }
    }
}

public enum GetServerWalletSaltError {
    case generic
}

public func getServerWalletSalt(network: Network) -> Signal<Data, GetServerWalletSaltError> {
    return network.request(Api.functions.wallet.getKeySecretSalt(revoke: .boolFalse))
    |> mapError { _ -> GetServerWalletSaltError in
        return .generic
    }
    |> map { result -> Data in
        switch result {
        case let .secretSalt(salt):
            return salt.makeData()
        }
    }
}
