import Foundation
import Security

// Synthetic PlayChain fixture. One process = one game launch. Fake data only.
// SecItem* go through fx_* (objc_msgSend, like PlayLoader's interposers) so the shim applies;
// 'raw-add' calls PlayKeychain directly (static dispatch): the unswizzled append of older builds.
guard let dbPath = ProcessInfo.processInfo.environment["GAKU_POC_DB"],
      !dbPath.contains("io.playcover.PlayCover") else {
    print("FAIL: GAKU_POC_DB must name a synthetic database")
    exit(3)
}

func st(_ status: OSStatus) -> String {
    switch status {
    case errSecSuccess: return "0"
    case errSecDuplicateItem: return "errSecDuplicateItem"
    case errSecItemNotFound: return "errSecItemNotFound"
    case errSecIO: return "errSecIO"
    default: return "\(status)"
    }
}
func out(_ key: String, _ value: String) { print("OUT \(key)=\(value)") }

// ---- Firebase Auth AuthKeychainServices: generic password, no access group ---------------
let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                            kSecAttrAccount as String: "firebase_auth_1___FIRAPP_DEFAULT_firebase_user",
                            kSecAttrService as String: "firebase_auth_1:1:000000000000:ios:fakefakefake"]
func attributes(_ value: Data) -> [String: Any] {
    [kSecValueData as String: value, kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
}
func item(_ value: Data) -> [String: Any] { attributes(value).merging(query) { _, last in last } }
struct KeychainError: Error { let function: String; let status: OSStatus }

// getItemLegacy: numeric limit so more than one item is detectable (I-AUT000005).
func get() throws -> String {
    var q = query
    q[kSecReturnData as String] = true
    q[kSecReturnAttributes as String] = true
    q[kSecMatchLimit as String] = 2
    var result: AnyObject?
    let status = fx_copy(q, &result)
    if status == errSecItemNotFound { return "nil" }
    guard status == errSecSuccess, let items = result as? [[String: Any]],
          let data = items.first?[kSecValueData as String] as? Data else {
        throw KeychainError(function: "SecItemCopyMatching", status: status)
    }
    return (items.count > 1 ? "I-AUT000005:" : "") + String(decoding: data, as: UTF8.self)
}
// setItemLegacy: SecItemAdd, and SecItemUpdate on errSecDuplicateItem.
func set(_ value: Data) throws -> String {
    var status = fx_add(item(value))
    var function = "SecItemAdd"
    if status == errSecDuplicateItem {
        function = "SecItemUpdate"
        status = fx_update(query, attributes(value))
    }
    if status != errSecSuccess { throw KeychainError(function: function, status: status) }
    return "\(function):\(st(status))"
}

out("install", "\(GakuInstallPlayChainCompat(PlayKeychain.self))")
for command in CommandLine.arguments.dropFirst() {
    let parts = command.split(separator: ":", maxSplits: 1).map(String.init)
    let name = parts[0]
    let value = Data((parts.count > 1 ? parts[1] : "").utf8)
    do {
        switch name {
        case "fb-get": out(name, try get())
        case "fb-set": out(name, try set(value))
        case "fb-remove": out(name, st(fx_delete(query))) // signOut -> removeData -> SecItemDelete
        case "add": out(name, st(fx_add(item(value)))) // blind SecItemAdd
        case "raw-add": out(name, st(PlayKeychain.add(item(value) as NSDictionary, result: nil)))
        default: print("FAIL: unknown command \(command)"); exit(2)
        }
    } catch let error as KeychainError {
        out(name, "THROWS \(error.function) \(st(error.status))")
    }
}
exit(0)
