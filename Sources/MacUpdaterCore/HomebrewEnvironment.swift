public enum HomebrewEnvironment {
    public static let processPath = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

    public static var environment: [String: String] {
        ["PATH": processPath]
    }
}
