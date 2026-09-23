import Foundation

@objc public protocol HostsHelperProtocol {
    func apply(domains: [String], withReply reply: @escaping (Bool, String?) -> Void)
    func removeManagedSection(withReply reply: @escaping (Bool, String?) -> Void)
    func status(withReply reply: @escaping (Bool, Int, String?) -> Void)
    func flushDNSCache(withReply reply: @escaping (Bool, String?) -> Void)
    /// `config` to JSON z `FirewallConfig`.
    func applyFirewall(config: Data, withReply reply: @escaping (Bool, String?) -> Void)
    func firewallStatus(withReply reply: @escaping (Bool, Int, String?) -> Void)
    func setNativeFirewall(enabled: Bool, stealth: Bool, withReply reply: @escaping (Bool, String?) -> Void)
}

public enum HostsHelperConstants {
    public static let machServiceName = "com.italiano88.MacAdBlock.HostsHelper"
    public static let installedHelperPath = "/Library/PrivilegedHelperTools/com.italiano88.MacAdBlock.HostsHelper"
    public static let installedPlistPath = "/Library/LaunchDaemons/com.italiano88.MacAdBlock.HostsHelper.plist"
    public static let daemonPlistName = "com.italiano88.MacAdBlock.HostsHelper.plist"
}
