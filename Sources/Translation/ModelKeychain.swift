import Foundation
import Security

enum ModelKeychain {
    private static func query(_ endpoint: URL) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "com.transeen.models", kSecAttrAccount as String: endpoint.absoluteString]
    }
    static func read(endpoint: URL) throws -> String {
        var q = query(endpoint)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &result)
        if status == errSecItemNotFound { return "" }
        guard status == errSecSuccess, let data = result as? Data else { throw ModelError.message("无法读取模型密钥，请在设置中重新保存。") }
        return String(decoding: data, as: UTF8.self)
    }
    static func save(_ value: String, endpoint: URL) throws {
        let q = query(endpoint)
        if value.isEmpty {
            let status = SecItemDelete(q as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw ModelError.message("无法删除模型密钥。") }
            return
        }
        let data = Data(value.utf8)
        var status = SecItemUpdate(q as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = q; item[kSecValueData as String] = data
            status = SecItemAdd(item as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw ModelError.message("无法保存模型密钥。") }
    }
}
