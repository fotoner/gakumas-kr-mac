import Foundation
import Security

// Synthetic PlayChain fixture. One process = one game launch. Fake data only.
// SecItem* go through fx_* (objc_msgSend, like PlayLoader's interposers) so the shim applies;
// direct Swift calls to PlayKeychain are statically dispatched and bypass it ("raw" rows).
guard let dbPath = ProcessInfo.processInfo.environment["GAKU_POC_DB"],
      !dbPath.contains("io.playcover.PlayCover") else {
    print("FAIL: GAKU_POC_DB must name a synthetic database")
    exit(3)
}

func check(_ ok: @autoclosure () -> Bool, _ label: String) {
    guard ok() else { print("FAIL: \(label)"); exit(1) }
    print("PASS: \(label)")
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
func label(_ data: Any?) -> String { (data as? Data).flatMap { String(data: $0, encoding: .utf8) } ?? "nil" }
func read(_ query: [String: Any]) -> (OSStatus, AnyObject?) {
    var result: AnyObject?
    let status = fx_copy(query, &result)
    return (status, result)
}

var args = Array(CommandLine.arguments.dropFirst())
let mode = args.isEmpty ? "" : args.removeFirst()

// ---- legacy Sep-20 flow (agrp set; read fix) --------------------------------------------
func legacy(_ mode: String) -> Never {
    let service = "org.mac-gaku.synthetic-login-poc"
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
    check(GakuInstallPlayChainCompat(PlayKeychain.self) == 7, "install game-local compatibility methods (read+add+delete)")
    let (status, result) = read(firebase("session"))
    check(status == errSecSuccess, "Firebase query succeeds")
    let items = result as? [[String: Any]]
    check(items?.count == 1, "Firebase receives an array containing one item")
    check(items?.first?[kSecValueData as String] as? Data == token, "synthetic session survives process restart")

    var multi = firebase("session")
    multi.removeValue(forKey: kSecAttrAccount as String)
    let (multiStatus, multiResult) = read(multi)
    let multiItems = multiResult as? [[String: Any]]
    check(multiStatus == 0 && multiItems?.count == 2, "numeric limit caps three distinct records at two")
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
    exit(0)
}
if ["seed", "baseline", "fixed", "update", "refreshed"].contains(mode) { legacy(mode) }

// ---- install checks ----------------------------------------------------------------------
if mode == "install-check" {
    out("install-nil", "\(GakuInstallPlayChainCompat(nil))")
    out("install-partial", "\(GakuInstallPlayChainCompat(fx_partial_class()))")
    out("install-partial-again", "\(GakuInstallPlayChainCompat(fx_partial_class()))")
    out("install-other-class", "\(GakuInstallPlayChainCompat(PlayKeychain.self))")
    exit(0)
}
guard mode == "run" else { print("FAIL: unknown mode \(mode)"); exit(2) }

// ---- Firebase Auth 12.10 AuthKeychainServices (legacy keychain, no access group) --------
let fbKey = "__FIRAPP_DEFAULT_firebase_user"
func fbQuery() -> [String: Any] { // genericPasswordQuery(key:)
    [kSecClass as String: kSecClassGenericPassword, kSecAttrAccount as String: "firebase_auth_1_" + fbKey,
     kSecAttrService as String: "firebase_auth_1:1:000000000000:ios:fakefakefake"]
}
func fbLegacyQuery() -> [String: Any] { // legacyGenericPasswordQuery(key:)
    [kSecClass as String: kSecClassGenericPassword, kSecAttrAccount as String: fbKey]
}
func agrpQuery() -> [String: Any] { // same item with an access group (not used by this game)
    var q = fbQuery()
    q[kSecAttrAccessGroup as String] = "fake.group"
    return q
}
var legacyEntryDeleted = false
var legacyItemDeleted = false
struct KeychainError: Error { let function: String; let status: OSStatus }
func getItemLegacy(_ query: [String: Any]) throws -> Data? {
    var q = query
    q[kSecReturnData as String] = true
    q[kSecReturnAttributes as String] = true
    q[kSecMatchLimit as String] = 2 // more than one item is detectable
    var result: AnyObject?
    let status = fx_copy(q, &result)
    if let items = result as? [[String: Any]], status == noErr {
        if items.isEmpty { throw KeychainError(function: "SecItemCopyMatching", status: status) }
        if items.count > 1 { out("fb-warn", "I-AUT000005 items=\(items.count)") }
        for item in items where item[kSecAttrService as String] != nil { return item[kSecValueData as String] as? Data }
        return items[0][kSecValueData as String] as? Data
    }
    if status == errSecItemNotFound { return nil }
    throw KeychainError(function: "SecItemCopyMatching", status: status)
}
func setItemLegacy(_ item: Data, _ query: [String: Any]) throws -> String {
    let attributes: [String: Any] = [kSecValueData as String: item,
                                     kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
    let combined = attributes.merging(query, uniquingKeysWith: { _, last in last })
    var status = fx_add(combined)
    var function = "SecItemAdd"
    if status == errSecDuplicateItem {
        function = "SecItemUpdate"
        status = fx_update(query, attributes)
    }
    if status != noErr { throw KeychainError(function: function, status: status) }
    return "\(function):\(st(status))"
}
func deleteItem(_ query: [String: Any]) throws -> OSStatus {
    let status = fx_delete(query)
    if status == noErr || status == errSecItemNotFound { return status }
    throw KeychainError(function: "SecItemDelete", status: status)
}
func fbData() throws -> Data? { // data(forKey:)
    if let data = try getItemLegacy(fbQuery()) { return data }
    if legacyEntryDeleted { return nil }
    if let data = try getItemLegacy(fbLegacyQuery()) {
        _ = try setItemLegacy(data, fbQuery())
        _ = fx_delete(fbLegacyQuery())
        return data
    }
    legacyEntryDeleted = true
    return nil
}
func fbRemove() throws -> String { // removeData(forKey:)
    let status = try deleteItem(fbQuery())
    if !legacyItemDeleted {
        _ = try deleteItem(fbLegacyQuery())
        legacyItemDeleted = true
    }
    return "SecItemDelete:\(st(status))"
}

// ---- GoogleUtilities GULKeychainUtils (Firebase Installations): get, then add or update --
func gulQuery() -> [String: Any] {
    [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "com.firebase.FIRInstallations.installations",
     kSecAttrAccount as String: "1:000000000000:ios:fakefakefake__FIRAPP_DEFAULT", kSecUseDataProtectionKeychain as String: true]
}
func gulGet() -> (Data?, OSStatus) {
    var q = gulQuery()
    q[kSecReturnData as String] = true
    q[kSecMatchLimit as String] = kSecMatchLimitOne
    let (status, result) = read(q)
    return (status == errSecSuccess ? result as? Data : nil, status)
}
func gulSet(_ item: Data) -> String {
    let (existing, getStatus) = gulGet()
    if getStatus != errSecSuccess && getStatus != errSecItemNotFound { return "get-error:\(st(getStatus))" }
    if existing == nil {
        var q = gulQuery()
        q[kSecValueData as String] = item
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return "SecItemAdd:\(st(fx_add(q)))"
    }
    return "SecItemUpdate:\(st(fx_update(gulQuery(), [kSecValueData as String: item])))"
}

// ---- Adjust-like (add only when missing) and AppMeasurement-like '_pfo' (blind add) -----
func simpleQuery(_ service: String, _ account: String) -> [String: Any] {
    [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
}
func simpleGet(_ query: [String: Any]) -> Data? {
    var q = query
    q[kSecReturnData as String] = true
    q[kSecMatchLimit as String] = kSecMatchLimitOne
    let (status, result) = read(q)
    return status == errSecSuccess ? result as? Data : nil
}
func simpleAdd(_ query: [String: Any], _ data: Data) -> OSStatus {
    var q = query
    q[kSecValueData as String] = data
    return fx_add(q)
}
let adjust = simpleQuery("deviceInfo", "adjust_uuid")
let pfo = simpleQuery("jp.co.fake.bundle", "_pfo")
let inet: [String: Any] = [kSecClass as String: kSecClassInternetPassword, kSecAttrServer as String: "fake.example",
                           kSecAttrAccount as String: "fake"]

var shim = "full"
if let flag = args.first, flag.hasPrefix("--") { shim = String(flag.dropFirst(2)); args.removeFirst() }
switch shim {
case "full": out("install", "\(GakuInstallPlayChainCompat(PlayKeychain.self))")
case "no-shim": out("install", "none")
case "v1-only": out("install", "\(GakuFixtureInstallReadOnly(PlayKeychain.self))")
case "naive-add": GakuFixtureSetNaiveAdd(true); out("install", "\(GakuInstallPlayChainCompat(PlayKeychain.self))")
default: print("FAIL: unknown shim \(shim)"); exit(2)
}

for command in args {
    let parts = command.split(separator: ":", maxSplits: 1).map(String.init)
    let name = parts[0]
    let value = Data((parts.count > 1 ? parts[1] : "").utf8)
    do {
        switch name {
        case "fb-get": out(name, label(try fbData()))
        case "fb-set": out(name, try setItemLegacy(value, fbQuery()))
        case "fb-remove": out(name, try fbRemove())
        case "agrp-set": out(name, try setItemLegacy(value, agrpQuery()))
        case "agrp-add": out(name, st(simpleAdd(agrpQuery(), value)))
        case "agrp-get": out(name, label(try getItemLegacy(agrpQuery())))
        case "raw-add": // statically dispatched: the unswizzled PlayChain append of older builds
            var q = fbQuery()
            q[kSecValueData as String] = value
            q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            out(name, st(PlayKeychain.add(q as NSDictionary, result: nil)))
        case "gul-set": out(name, gulSet(value))
        case "gul-get": out(name, label(gulGet().0))
        case "gul-remove": out(name, st(fx_delete(gulQuery())))
        case "adj-init":
            if let data = simpleGet(adjust) { out(name, "existing:\(label(data))") }
            else { out(name, "SecItemAdd:\(st(simpleAdd(adjust, value)))") }
        case "pfo-add": out(name, st(simpleAdd(pfo, value)))
        case "pfo-get": out(name, label(simpleGet(pfo)))
        case "inet-add": out(name, st(simpleAdd(inet, value)))
        case "raw-other": // another account's item under a shared service, written by the old append
            var q = simpleQuery("shared.svc", "other")
            q[kSecValueData as String] = value
            out(name, st(PlayKeychain.add(q as NSDictionary, result: nil)))
        case "svc-only-set": // an item with no account: a different item for the real Keychain
            out(name, try setItemLegacy(value, [kSecClass as String: kSecClassGenericPassword,
                                                kSecAttrService as String: "shared.svc"]))
        case "nonutf8-add":
            var q = simpleQuery("fake.bytes", "")
            q[kSecAttrAccount as String] = Data([0xff, 0xfe, 0x00, 0x80])
            out(name, st(simpleAdd(q, value)))
        case "delete-missing": out(name, st(fx_delete(simpleQuery("fake.absent", "absent"))))
        case "install-again": out(name, "\(GakuInstallPlayChainCompat(PlayKeychain.self))")
        case "touch": // handshake with the harness (e.g. while it holds a DB lock)
            FileManager.default.createFile(atPath: parts[1], contents: nil)
        case "wait-file":
            var waited = 0
            while !FileManager.default.fileExists(atPath: parts[1]) && waited < 1500 { usleep(10_000); waited += 1 }
            if waited == 1500 { out(name, "timeout") }
        case "race":
            let query = simpleQuery("fake.race", "race")
            let lock = NSLock()
            var statuses: [OSStatus] = []
            DispatchQueue.concurrentPerform(iterations: 16) { index in
                let status = simpleAdd(query, Data("race-\(index)".utf8))
                lock.lock(); statuses.append(status); lock.unlock()
            }
            let success = statuses.filter { $0 == errSecSuccess }.count
            let duplicate = statuses.filter { $0 == errSecDuplicateItem }.count
            out(name, "success=\(success) duplicate=\(duplicate) other=\(16 - success - duplicate)")
        default: print("FAIL: unknown command \(command)"); exit(2)
        }
    } catch let error as KeychainError {
        out(name, "THROWS \(error.function) \(st(error.status))")
    }
}
exit(0)
