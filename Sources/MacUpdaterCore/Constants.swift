public enum MacUpdaterConstants {
    public static let caskMappingsByBundleIdentifier: [String: String] = [
        "com.google.Chrome": "google-chrome",
        "com.google.Chrome.beta": "google-chrome@beta",
        "com.google.Chrome.dev": "google-chrome@dev",
        "com.google.Chrome.canary": "google-chrome@canary",
    ]

    public static let customCaskMappings: [String: String] = [
        "CleanMyMac_5": "cleanmymac",
        "zoom.us": "zoom",
        "logioptionsplus": "logi-options+",
        "Gemini 2": "gemini",
        "Parallels Desktop": "parallels",
        "Docker": "docker-desktop"
    ]

    /// REL-15 — an **override**, not the detection list. Running-app detection is generic
    /// (`RunningCaskDetector` matches each cask's bundle URL against the live applications), so
    /// it covers the whole catalog. This map only supplies the process/app name to quit and
    /// reopen for the handful of casks whose running process name cannot be read from the app
    /// itself (e.g. the `zoom` cask runs as `zoom.us`, `visual-studio-code` as `Code`).
    public static let restartMap: [String: RestartInfo] = [
        "claude": RestartInfo(processName: "Claude", appName: "Claude"),
        "visual-studio-code": RestartInfo(processName: "Code", appName: "Visual Studio Code"),
        "postman": RestartInfo(processName: "Postman", appName: "Postman"),
        "cursor": RestartInfo(processName: "Cursor", appName: "Cursor"),
        "arc": RestartInfo(processName: "Arc", appName: "Arc"),
        "warp": RestartInfo(processName: "Warp", appName: "Warp"),
        "slack": RestartInfo(processName: "Slack", appName: "Slack"),
        "zoom": RestartInfo(processName: "zoom.us", appName: "zoom.us"),
        "figma": RestartInfo(processName: "Figma", appName: "Figma"),
        "obsidian": RestartInfo(processName: "Obsidian", appName: "Obsidian"),
        "iterm2": RestartInfo(processName: "iTerm2", appName: "iTerm2"),
        "ghostty": RestartInfo(processName: "Ghostty", appName: "Ghostty"),
        "notion": RestartInfo(processName: "Notion", appName: "Notion"),
        "raycast": RestartInfo(processName: "Raycast", appName: "Raycast"),
        "1password": RestartInfo(processName: "1Password 7", appName: "1Password 7"),
        "1password7": RestartInfo(processName: "1Password 7", appName: "1Password 7")
    ]
}
