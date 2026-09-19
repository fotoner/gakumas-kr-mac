import Foundation
import Security
import ObjectiveC

@_silgen_name("GakuInstallPlayChainCompat")
func installCompat(_ cls: AnyClass) -> Bool

// Dispatch through Objective-C, exactly like PlayTools' SecItemCopyMatching interposer.
typealias CopyIMP = @convention(c) (AnyObject, Selector, NSDictionary, UnsafeMutablePointer<Unmanaged<CFTypeRef>?>?) -> OSStatus
func read(_ query: [String: Any]) -> (OSStatus, AnyObject?) {
    let cls: AnyClass = PlayKeychain.self
    let sel = NSSelectorFromString("copyMatching:result:")
    let method = class_getClassMethod(cls, sel)!
    let call = unsafeBitCast(method_getImplementation(method), to: CopyIMP.self)
    var result: Unmanaged<CFTypeRef>?
    let status = call(cls, sel, query as NSDictionary, &result)
    return (status, result?.takeRetainedValue())
}
func check(_ ok: @autoclosure () -> Bool, _ label: String) {
    guard ok() else { print("FAIL: \(label)"); exit(1) }
    print("PASS: \(label)")
}
let service = "org.mac-gaku.synthetic-login-poc"
let mode = CommandLine.arguments[1]
let token = Data((mode == "refreshed" ? "synthetic-session-v2" : "synthetic-session-v1-NOT-A-REAL-CREDENTIAL").utf8)
func base(_ account: String) -> [String: Any] {
    [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
     kSecAttrAccessGroup as String: "synthetic", kSecAttrAccount as String: account]
}
func firebase(_ account: String) -> [String: Any] {
    var q = base(account)
    q[kSecMatchLimit as String] = 2
    q[kSecReturnAttributes as String] = true
    q[kSecReturnData as String] = true
    return q
}
if mode == "seed" {
    for account in ["session", "second", "third"] {
        var q = base(account)
        q[kSecValueData as String] = account == "session" ? token : Data(account.utf8)
        check(PlayKeychain.add(q as NSDictionary, result: nil) == errSecSuccess, "persist synthetic \(account)")
    }
    exit(0)
}
if mode == "baseline" {
    let (status, result) = read(firebase("session"))
    check(status == errSecSuccess, "upstream reports success")
    check(result is NSDictionary && !(result is NSArray), "reproduced Firebase array-cast failure after process restart")
    exit(0)
}
check(installCompat(PlayKeychain.self), "install game-local compatibility method")
let (status, result) = read(firebase("session"))
check(status == errSecSuccess, "Firebase query succeeds")
let items = result as? [[String: Any]]
check(items?.count == 1, "Firebase receives an array containing one item")
check(items?.first?[kSecValueData as String] as? Data == token, "synthetic session survives process restart")

var multi = firebase("session")
multi.removeValue(forKey: kSecAttrAccount as String)
let (multiStatus, multiResult) = read(multi)
let multiItems = multiResult as? [[String: Any]]
check(multiStatus == 0 && multiItems?.count == 2, "numeric limit caps three records at two; duplicates remain detectable")
check(Set(multiItems!.compactMap { $0[kSecAttrAccount as String] as? String }).count == 2, "each match retains its own identity")
check(multiItems!.allSatisfy { item in
    let account = item[kSecAttrAccount as String] as! String
    return item[kSecValueData as String] as? Data == (account == "session" ? token : Data(account.utf8))
}, "each match retains its own data")
let (missingStatus, missingResult) = read(firebase("absent"))
check(missingStatus == errSecItemNotFound && missingResult == nil, "missing session is still not found")
var single = firebase("session")
single[kSecMatchLimit as String] = kSecMatchLimitOne
check(read(single).1 is NSDictionary, "single-result callers retain dictionary semantics")
single[kSecReturnData as String] = false
let attrs = read(single).1 as? NSDictionary
check(attrs?[kSecValueData] == nil, "attributes-only queries do not expose data")

if mode == "update" {
    let next = Data("synthetic-session-v2".utf8)
    check(PlayKeychain.update(base("session") as NSDictionary,
                             attributesToUpdate: [kSecValueData as String: next] as NSDictionary) == 0,
          "persist refreshed synthetic session")
}
