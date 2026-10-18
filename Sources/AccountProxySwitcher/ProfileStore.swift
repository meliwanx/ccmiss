import Foundation
import Darwin

enum ProfileStoreError: LocalizedError {
    case invalidMetadata
    case unreadableMetadata
    case unwritableMetadata
    case missingCredentials
    case unreadableCredentials
    case unwritableCredentials

    var errorDescription: String? {
        switch self {
        case .invalidMetadata: return "账号配置数据无效，请检查名称和服务器信息。"
        case .unreadableMetadata: return "无法读取本地账号配置；原文件已保留。"
        case .unwritableMetadata: return "无法保存本地账号配置，请检查文件夹权限和可用空间。"
        case .missingCredentials: return "此账号尚无本地代理链接，请重新填写一次代理链接。"
        case .unreadableCredentials: return "无法读取本地代理链接文件；原文件已保留。"
        case .unwritableCredentials: return "无法保存本地代理链接，请检查文件夹权限和可用空间。"
        }
    }
}

/// Account labels remain separate from complete proxy URLs. Credentials are local
/// owner-only files by the user's preference; legacy credential storage is never accessed.
final class ProfileStore {
    let directory: URL

    init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AccountProxySwitcher", isDirectory: true)
    }

    private var profilesURL: URL { directory.appendingPathComponent("profiles.json", isDirectory: false) }
    private var credentialsURL: URL { directory.appendingPathComponent("credentials.json", isDirectory: false) }

    func loadProfiles() throws -> [ProxyProfile] {
        try prepareDirectory()
        do {
            try rejectSymbolicLink(profilesURL)
            guard FileManager.default.fileExists(atPath: profilesURL.path) else { return [] }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let profiles = try decoder.decode([ProxyProfile].self, from: Data(contentsOf: profilesURL))
            try validateProfiles(profiles)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: profilesURL.path)
            return profiles
        } catch let error as ProfileStoreError {
            throw error
        } catch {
            throw ProfileStoreError.unreadableMetadata
        }
    }

    func saveProfiles(_ profiles: [ProxyProfile]) throws {
        try validateProfiles(profiles)
        try prepareDirectory()
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(profiles)
            try atomicWrite(data, to: profilesURL)
        } catch let error as ProfileStoreError {
            throw error
        } catch {
            throw ProfileStoreError.unwritableMetadata
        }
    }

    func saveURI(_ uri: String, for id: UUID) throws {
        let canonical = try SOCKSProxy(uri: uri).canonicalURI
        var credentials = try loadCredentials()
        credentials[id.uuidString] = canonical
        try saveCredentials(credentials)
    }

    func loadURI(for id: UUID) throws -> String {
        guard let uri = try loadCredentials()[id.uuidString] else {
            throw ProfileStoreError.missingCredentials
        }
        return uri
    }

    func deleteURI(for id: UUID) throws {
        var credentials = try loadCredentials()
        guard credentials.removeValue(forKey: id.uuidString) != nil else { return }
        try saveCredentials(credentials)
    }

    private func loadCredentials() throws -> [String: String] {
        try prepareDirectory()
        do {
            try rejectSymbolicLink(credentialsURL)
            guard FileManager.default.fileExists(atPath: credentialsURL.path) else { return [:] }
            let values = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: credentialsURL))
            var credentials: [String: String] = [:]
            for (key, uri) in values {
                guard let id = UUID(uuidString: key) else { throw ProfileStoreError.unreadableCredentials }
                let normalizedKey = id.uuidString
                let canonical = try SOCKSProxy(uri: uri).canonicalURI
                if let existing = credentials[normalizedKey], existing != canonical {
                    throw ProfileStoreError.unreadableCredentials
                }
                credentials[normalizedKey] = canonical
            }
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: credentialsURL.path)
            return credentials
        } catch {
            throw ProfileStoreError.unreadableCredentials
        }
    }

    private func saveCredentials(_ credentials: [String: String]) throws {
        try prepareDirectory()
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            try atomicWrite(encoder.encode(credentials), to: credentialsURL)
        } catch {
            throw ProfileStoreError.unwritableCredentials
        }
    }

    private func prepareDirectory() throws {
        do {
            try rejectSymbolicLink(directory)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        } catch {
            throw ProfileStoreError.unwritableMetadata
        }
    }

    private func rejectSymbolicLink(_ url: URL) throws {
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            guard attributes[.type] as? FileAttributeType != .typeSymbolicLink else {
                throw ProfileStoreError.unwritableMetadata
            }
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return
        }
    }

    private func atomicWrite(_ data: Data, to url: URL) throws {
        try rejectSymbolicLink(url)
        let temporary = directory.appendingPathComponent(".\(url.lastPathComponent)-\(UUID().uuidString).tmp")
        let descriptor = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw ProfileStoreError.unwritableMetadata }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer {
            try? handle.close()
            try? FileManager.default.removeItem(at: temporary)
        }
        guard fchmod(descriptor, S_IRUSR | S_IWUSR) == 0 else { throw ProfileStoreError.unwritableMetadata }
        try handle.write(contentsOf: data)
        try handle.synchronize()
        try handle.close()
        try rejectSymbolicLink(url)
        guard rename(temporary.path, url.path) == 0 else { throw ProfileStoreError.unwritableMetadata }
    }

    private func validateProfiles(_ profiles: [ProxyProfile]) throws {
        guard Set(profiles.map(\.id)).count == profiles.count else { throw ProfileStoreError.invalidMetadata }
        for profile in profiles {
            guard !profile.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  profile.name.utf8.count <= 1024, profile.accountDescription.utf8.count <= 16_384,
                  profile.username.map({ !$0.isEmpty && $0.utf8.count <= 255 }) ?? true else {
                throw ProfileStoreError.invalidMetadata
            }
            let proxy = SOCKSProxy(host: profile.host, port: profile.port, username: profile.username, password: nil)
            do { _ = try SOCKSProxy(uri: proxy.canonicalURI) }
            catch { throw ProfileStoreError.invalidMetadata }
        }
    }
}
