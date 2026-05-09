import Foundation

struct CLIOptions {
    var command: String
    var home: String = NSHomeDirectory()
    var roots: [String] = []
    var minFreePercent: Double = 10.0
    var execute: Bool = false
    var json: Bool = false
    var logDir: String?
    var intervalMinutes: Int = 60
}

struct DiskSnapshot: Codable {
    let path: String
    let totalBytes: Int64
    let freeBytes: Int64
    let freePercent: Double
}

struct CleanableRecord: Codable {
    let category: String
    let path: String
    let sizeBytes: Int64
    let reason: String
}

struct ScanPayload: Codable {
    let tool: String
    let command: String
    let home: String
    let roots: [String]
    let candidateCount: Int
    let totalBytes: Int64
    let items: [CleanableRecord]
}

struct CleanPayload: Codable {
    let tool: String
    let command: String
    let mode: String
    let status: String
    let minFreePercent: Double
    let diskBefore: DiskSnapshot
    let diskAfter: DiskSnapshot
    let candidateCount: Int
    let deletedCount: Int
    let totalCandidateBytes: Int64
    let deletedBytesEstimate: Int64
    let errors: [String]
    let items: [CleanableRecord]
}

struct StatusPayload: Codable {
    let tool: String
    let command: String
    let status: String
    let minFreePercent: Double
    let disk: DiskSnapshot
}

struct MessagePayload: Codable {
    let tool: String
    let command: String
    let status: String
    let message: String
    let path: String?
}

enum CLIError: Error, CustomStringConvertible {
    case missingValue(String)
    case unknownArgument(String)
    case unknownCommand(String)
    case unsafePath(String)
    case unsafeRoot(String)
    case unsafeHome(String)

    var description: String {
        switch self {
        case .missingValue(let flag): return "missing value for \(flag)"
        case .unknownArgument(let arg): return "unknown argument: \(arg)"
        case .unknownCommand(let command): return "unknown command: \(command)"
        case .unsafePath(let path): return "unsafe path rejected: \(path)"
        case .unsafeRoot(let path): return "unsafe root rejected: \(path)"
        case .unsafeHome(let path): return "unsafe home rejected: \(path)"
        }
    }
}

let fm = FileManager.default

func parseOptions() throws -> CLIOptions {
    var args = Array(CommandLine.arguments.dropFirst())
    guard !args.isEmpty else { return CLIOptions(command: "help") }
    let command = args.removeFirst()
    var options = CLIOptions(command: command)

    var index = 0
    while index < args.count {
        let arg = args[index]
        func value() throws -> String {
            guard index + 1 < args.count else { throw CLIError.missingValue(arg) }
            index += 1
            return args[index]
        }

        switch arg {
        case "--home": options.home = try value()
        case "--root": options.roots.append(try value())
        case "--min-free-percent":
            guard let parsed = Double(try value()) else { throw CLIError.missingValue(arg) }
            options.minFreePercent = parsed
        case "--execute": options.execute = true
        case "--dry-run": options.execute = false
        case "--json": options.json = true
        case "--log-dir": options.logDir = try value()
        case "--interval-minutes":
            guard let parsed = Int(try value()) else { throw CLIError.missingValue(arg) }
            options.intervalMinutes = parsed
        default:
            throw CLIError.unknownArgument(arg)
        }
        index += 1
    }

    if options.roots.isEmpty {
        options.roots = [options.home]
    }
    guard (0...100).contains(options.minFreePercent) else { throw CLIError.unknownArgument("--min-free-percent must be between 0 and 100") }
    guard (1...10080).contains(options.intervalMinutes) else { throw CLIError.unknownArgument("--interval-minutes must be between 1 and 10080") }
    try validateRoots(home: options.home, roots: options.roots)
    return options
}

func canonicalPath(_ path: String) -> String {
    (path as NSString).expandingTildeInPath.standardizedFileURL.path
}

extension String {
    var standardizedFileURL: URL { URL(fileURLWithPath: self).standardizedFileURL }
}

func unsafeBroadPaths() -> Set<String> {
    ["/", "/Users", "/Applications", "/Library", "/System", "/bin", "/sbin", "/usr", "/usr/bin", "/usr/sbin", "/opt", "/tmp", "/private/tmp", "/var", "/private/var"]
}

func validateRoots(home: String, roots: [String]) throws {
    let normalizedHome = canonicalPath(home)
    let explicitlyDenied = unsafeBroadPaths()
    if explicitlyDenied.contains(normalizedHome) { throw CLIError.unsafeHome(normalizedHome) }
    for root in roots.map(canonicalPath) {
        if explicitlyDenied.contains(root) { throw CLIError.unsafeRoot(root) }
        let underHome = root == normalizedHome || root.hasPrefix(normalizedHome.hasSuffix("/") ? normalizedHome : normalizedHome + "/")
        if !underHome { throw CLIError.unsafeRoot(root) }
    }
}

func diskSnapshot(for path: String) -> DiskSnapshot {
    let probe = canonicalPath(path)
    do {
        let attrs = try fm.attributesOfFileSystem(forPath: probe)
        let total = (attrs[.systemSize] as? NSNumber)?.int64Value ?? 0
        let free = (attrs[.systemFreeSize] as? NSNumber)?.int64Value ?? 0
        let percent = total > 0 ? (Double(free) / Double(total)) * 100.0 : 0.0
        return DiskSnapshot(path: probe, totalBytes: total, freeBytes: free, freePercent: percent)
    } catch {
        return DiskSnapshot(path: probe, totalBytes: 0, freeBytes: 0, freePercent: 0)
    }
}

func directorySize(_ path: String) -> Int64 {
    guard let enumerator = fm.enumerator(
        at: URL(fileURLWithPath: path),
        includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey],
        options: [.skipsHiddenFiles, .skipsPackageDescendants]
    ) else { return 0 }

    var total: Int64 = 0
    for case let url as URL in enumerator {
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey]) else { continue }
        if values.isSymbolicLink == true { continue }
        if values.isRegularFile == true, let size = values.fileSize {
            total += Int64(size)
        }
    }
    return total
}

func containsProjectMarker(in directory: String) -> Bool {
    guard let contents = try? fm.contentsOfDirectory(atPath: directory) else { return false }
    return contents.contains { name in
        name.hasSuffix(".csproj") ||
        name.hasSuffix(".fsproj") ||
        name.hasSuffix(".vbproj") ||
        name.hasSuffix(".sln") ||
        name == "Directory.Build.props" ||
        name == "Directory.Build.targets" ||
        name == "global.json" ||
        name == "packages.config"
    }
}

func isSymbolicLink(_ path: String) -> Bool {
    if let values = try? URL(fileURLWithPath: path).resourceValues(forKeys: [.isSymbolicLinkKey]) {
        return values.isSymbolicLink == true
    }
    return false
}

func rootsContain(path: String, roots: [String]) -> Bool {
    let normalized = canonicalPath(path)
    return roots.map(canonicalPath).contains { root in
        normalized == root || normalized.hasPrefix(root.hasSuffix("/") ? root : root + "/")
    }
}

func scanIDEBuildArtifacts(home: String, roots: [String]) -> [CleanableRecord] {
    var records: [CleanableRecord] = []
    let normalizedRoots = roots.map(canonicalPath)
    let deniedPrefixes = ["/System", "/bin", "/sbin", "/usr/bin", "/usr/sbin"]

    for root in normalizedRoots where fm.fileExists(atPath: root) {
        guard !deniedPrefixes.contains(where: { root == $0 || root.hasPrefix($0 + "/") }) else { continue }
        guard let enumerator = fm.enumerator(
            at: URL(fileURLWithPath: root),
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        ) else { continue }

        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]), values.isDirectory == true else { continue }
            if values.isSymbolicLink == true {
                enumerator.skipDescendants()
                continue
            }

            let name = url.lastPathComponent
            guard name == "bin" || name == "obj" else { continue }
            let path = url.path
            guard rootsContain(path: path, roots: normalizedRoots) else { continue }
            let parent = url.deletingLastPathComponent().path
            guard containsProjectMarker(in: parent) else { continue }
            let size = directorySize(path)
            records.append(CleanableRecord(
                category: "developerBuildArtifacts",
                path: path,
                sizeBytes: size,
                reason: "Visual Studio/.NET project \(name) output under project marker"
            ))
            enumerator.skipDescendants()
        }
    }

    var uniqueByPath: [String: CleanableRecord] = [:]
    for record in records {
        uniqueByPath[record.path] = record
    }
    return uniqueByPath.values.sorted { $0.path < $1.path }
}

func isSafeDeletionTarget(_ item: CleanableRecord, home: String, roots: [String]) -> Bool {
    if isSymbolicLink(item.path) { return false }
    if rootsContain(path: item.path, roots: roots) { return true }
    if item.category == "developerPackageCaches" || item.category == "userCaches" {
        return rootsContain(path: item.path, roots: [home])
    }
    return false
}

func scanDeveloperPackageCaches(home: String) -> [CleanableRecord] {
    let normalizedHome = canonicalPath(home)
    let relativeCachePaths = [
        ".nuget/packages",
        ".npm/_cacache",
        ".cache/pip",
        ".cache/yarn",
        ".cache/pnpm",
        "Library/Caches/Homebrew",
    ]

    var records: [CleanableRecord] = []
    for relative in relativeCachePaths {
        let path = (normalizedHome as NSString).appendingPathComponent(relative)
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue, !isSymbolicLink(path) else { continue }
        let size = directorySize(path)
        records.append(CleanableRecord(
            category: "developerPackageCaches",
            path: canonicalPath(path),
            sizeBytes: size,
            reason: "Developer package/cache directory under home: \(relative)"
        ))
    }
    return records
}

func scanUserCaches(home: String) -> [CleanableRecord] {
    let normalizedHome = canonicalPath(home)
    let cacheRoots = [
        (normalizedHome as NSString).appendingPathComponent("Library/Caches"),
        (normalizedHome as NSString).appendingPathComponent(".cache"),
    ]
    var records: [CleanableRecord] = []
    for cacheRoot in cacheRoots {
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: cacheRoot, isDirectory: &isDir), isDir.boolValue, !isSymbolicLink(cacheRoot) else { continue }
        guard let children = try? fm.contentsOfDirectory(atPath: cacheRoot) else { continue }
        for child in children where child != "." && child != ".." {
            let path = (cacheRoot as NSString).appendingPathComponent(child)
            var childIsDir: ObjCBool = false
            guard fm.fileExists(atPath: path, isDirectory: &childIsDir), !isSymbolicLink(path) else { continue }
            let size = childIsDir.boolValue ? directorySize(path) : ((try? fm.attributesOfItem(atPath: path)[.size] as? Int64) ?? 0)
            guard size > 1024 * 1024 else { continue }
            records.append(CleanableRecord(
                category: "userCaches",
                path: canonicalPath(path),
                sizeBytes: size,
                reason: "User cache entry under \((cacheRoot as NSString).lastPathComponent)"
            ))
        }
    }
    return records
}

func scanCandidates(home: String, roots: [String]) -> [CleanableRecord] {
    var uniqueByPath: [String: CleanableRecord] = [:]
    for record in scanIDEBuildArtifacts(home: home, roots: roots) + scanDeveloperPackageCaches(home: home) + scanUserCaches(home: home) {
        uniqueByPath[record.path] = record
    }
    return uniqueByPath.values.sorted { $0.path < $1.path }
}

func encodeJSON<T: Encodable>(_ payload: T) -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try! encoder.encode(payload)
    return String(data: data, encoding: .utf8)!
}

func printPayload<T: Encodable>(_ payload: T, json: Bool) {
    if json {
        print(encodeJSON(payload))
    } else {
        print(encodeJSON(payload))
    }
}

func writeLogIfNeeded<T: Encodable>(_ payload: T, logDir: String?) {
    guard let logDir else { return }
    let dir = canonicalPath(logDir)
    try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
    let formatter = ISO8601DateFormatter()
    let stamp = formatter.string(from: Date()).replacingOccurrences(of: ":", with: "")
    let body = encodeJSON(payload)
    try? body.write(toFile: (dir as NSString).appendingPathComponent("\(stamp).json"), atomically: true, encoding: .utf8)
    try? body.write(toFile: (dir as NSString).appendingPathComponent("latest.json"), atomically: true, encoding: .utf8)
}

func handleStatus(_ options: CLIOptions) -> Int32 {
    let disk = diskSnapshot(for: options.home)
    let status = disk.freePercent >= options.minFreePercent ? "healthy" : "below_threshold"
    printPayload(StatusPayload(tool: "puremaccli", command: "status", status: status, minFreePercent: options.minFreePercent, disk: disk), json: options.json)
    return disk.freePercent >= options.minFreePercent ? 0 : 1
}

func handleScan(_ options: CLIOptions) -> Int32 {
    let items = scanCandidates(home: options.home, roots: options.roots)
    let payload = ScanPayload(
        tool: "puremaccli",
        command: "scan",
        home: canonicalPath(options.home),
        roots: options.roots.map(canonicalPath),
        candidateCount: items.count,
        totalBytes: items.reduce(0) { $0 + $1.sizeBytes },
        items: items
    )
    printPayload(payload, json: options.json)
    return 0
}

func handleClean(_ options: CLIOptions) -> Int32 {
    let before = diskSnapshot(for: options.home)
    if before.freePercent >= options.minFreePercent {
        let payload = CleanPayload(
            tool: "puremaccli",
            command: "clean",
            mode: options.execute ? "execute" : "dry-run",
            status: "no_action_needed",
            minFreePercent: options.minFreePercent,
            diskBefore: before,
            diskAfter: before,
            candidateCount: 0,
            deletedCount: 0,
            totalCandidateBytes: 0,
            deletedBytesEstimate: 0,
            errors: [],
            items: []
        )
        writeLogIfNeeded(payload, logDir: options.logDir)
        printPayload(payload, json: options.json)
        return 0
    }
    let items = scanCandidates(home: options.home, roots: options.roots)
    var deleted = 0
    var deletedBytes: Int64 = 0
    var errors: [String] = []

    if options.execute && before.freePercent < options.minFreePercent {
        for item in items {
            do {
                guard isSafeDeletionTarget(item, home: options.home, roots: options.roots) else { throw CLIError.unsafePath(item.path) }
                try fm.removeItem(atPath: item.path)
                deleted += 1
                deletedBytes += item.sizeBytes
            } catch {
                errors.append("\(item.path): \(error)")
            }
        }
    }

    let after = diskSnapshot(for: options.home)
    let status: String
    if after.freePercent >= options.minFreePercent {
        status = "success"
    } else if !errors.isEmpty {
        status = "partial"
    } else if options.execute {
        status = "partial"
    } else {
        status = "dry_run"
    }

    let payload = CleanPayload(
        tool: "puremaccli",
        command: "clean",
        mode: options.execute ? "execute" : "dry-run",
        status: status,
        minFreePercent: options.minFreePercent,
        diskBefore: before,
        diskAfter: after,
        candidateCount: items.count,
        deletedCount: deleted,
        totalCandidateBytes: items.reduce(0) { $0 + $1.sizeBytes },
        deletedBytesEstimate: deletedBytes,
        errors: errors,
        items: items
    )
    writeLogIfNeeded(payload, logDir: options.logDir)
    printPayload(payload, json: options.json)
    return errors.isEmpty ? 0 : 1
}

func executablePath() -> String {
    URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL.path
}

func handleInstallAgent(_ options: CLIOptions) -> Int32 {
    let label = "com.kovaforge.puremac.cleanup"
    let launchAgents = (canonicalPath(options.home) as NSString).appendingPathComponent("Library/LaunchAgents")
    let plistPath = (launchAgents as NSString).appendingPathComponent("\(label).plist")
    let logDir = (canonicalPath(options.home) as NSString).appendingPathComponent("Library/Logs/PureMac")
    try? fm.createDirectory(atPath: launchAgents, withIntermediateDirectories: true)
    try? fm.createDirectory(atPath: logDir, withIntermediateDirectories: true)
    var programArguments = [
        executablePath(),
        "clean",
        "--home", canonicalPath(options.home),
    ]
    for root in options.roots {
        programArguments.append(contentsOf: ["--root", canonicalPath(root)])
    }
    programArguments.append(contentsOf: [
        "--min-free-percent", String(options.minFreePercent),
        "--execute",
        "--json",
        "--log-dir", "\(logDir)/cleanup-runs",
    ])

    let plist: [String: Any] = [
        "Label": label,
        "ProgramArguments": programArguments,
        "StartInterval": max(60, options.intervalMinutes * 60),
        "RunAtLoad": true,
        "StandardOutPath": "\(logDir)/launchd-cleanup.out.log",
        "StandardErrorPath": "\(logDir)/launchd-cleanup.err.log",
    ]

    do {
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: URL(fileURLWithPath: plistPath), options: .atomic)
        printPayload(MessagePayload(tool: "puremaccli", command: "install-agent", status: "installed", message: "LaunchAgent plist written; load with launchctl bootstrap gui/$(id -u) \(plistPath)", path: plistPath), json: options.json)
        return 0
    } catch {
        fputs("\(error)\n", stderr)
        return 2
    }
}

func handleUninstallAgent(_ options: CLIOptions) -> Int32 {
    let plistPath = (canonicalPath(options.home) as NSString).appendingPathComponent("Library/LaunchAgents/com.kovaforge.puremac.cleanup.plist")
    try? fm.removeItem(atPath: plistPath)
    printPayload(MessagePayload(tool: "puremaccli", command: "uninstall-agent", status: "removed", message: "LaunchAgent plist removed if present", path: plistPath), json: options.json)
    return 0
}

func printHelp() -> Int32 {
    print("""
    puremaccli - first-party PureMac CLI for OpenClaw and Hermes

    Commands:
      status --home /Users/mike --min-free-percent 10 --json
      scan --home /Users/mike --root /Users/mike/Projects --json
      clean --home /Users/mike --root /Users/mike/Projects --dry-run --json
      clean --home /Users/mike --root /Users/mike/Projects --execute --json
      install-agent --home /Users/mike --interval-minutes 60 --json
      uninstall-agent --home /Users/mike --json
    """)
    return 0
}

let exitCode: Int32

do {
    let options = try parseOptions()
    switch options.command {
    case "help", "--help", "-h": exitCode = printHelp()
    case "status": exitCode = handleStatus(options)
    case "scan": exitCode = handleScan(options)
    case "clean": exitCode = handleClean(options)
    case "install-agent": exitCode = handleInstallAgent(options)
    case "uninstall-agent": exitCode = handleUninstallAgent(options)
    default: throw CLIError.unknownCommand(options.command)
    }
} catch {
    fputs("puremaccli: \(error)\n", stderr)
    exitCode = 2
}

exit(exitCode)
