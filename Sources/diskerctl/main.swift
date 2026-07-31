import DiskerCore
import Foundation

// Headless driver for DiskerCore. Exists so scan correctness and performance can be
// checked against `du` without going through the GUI.
//
//   diskerctl scan <path> [--depth N]
//   diskerctl mole

func formatBytes(_ bytes: UInt64) -> String {
    let formatter = ByteCountFormatter()
    formatter.countStyle = .file
    return formatter.string(fromByteCount: Int64(bytes))
}

func printTree(_ node: FileNode, depth: Int, maxDepth: Int, indent: String = "") {
    guard depth <= maxDepth else { return }
    let marker: String
    switch node.kind {
    case .directory: marker = "▸"
    case .aggregate: marker = "·"
    case .symlink: marker = "→"
    case .file: marker = " "
    }
    var suffix = ""
    if node.flags.contains(.inaccessible) { suffix = "  [unreadable]" }
    if node.flags.contains(.crossedDevice) { suffix = "  [other volume]" }
    print("\(indent)\(marker) \(formatBytes(node.size).padded(to: 10))  \(node.name)\(suffix)")

    for child in node.children.prefix(15) {
        printTree(child, depth: depth + 1, maxDepth: maxDepth, indent: indent + "  ")
    }
}

extension String {
    func padded(to width: Int) -> String {
        count >= width ? self : String(repeating: " ", count: width - count) + self
    }
}

let arguments = CommandLine.arguments

guard arguments.count >= 2 else {
    print("usage: diskerctl scan <path> [--depth N]")
    print("       diskerctl volumes")
    print("       diskerctl recommend")
    print("       diskerctl mole")
    exit(1)
}

switch arguments[1] {
case "scan":
    guard arguments.count >= 3 else {
        print("usage: diskerctl scan <path> [--depth N]")
        exit(1)
    }
    let path = arguments[2]
    var maxDepth = 2
    if let flagIndex = arguments.firstIndex(of: "--depth"), flagIndex + 1 < arguments.count {
        maxDepth = Int(arguments[flagIndex + 1]) ?? 2
    }

    let scanner = VolumeScanner()
    let result = try await scanner.scan(path: path) { progress in
        FileHandle.standardError.write(
            Data("\r  \(progress.filesScanned) files…".utf8))
    }
    FileHandle.standardError.write(Data("\r\u{1B}[K".utf8))

    printTree(result.root, depth: 0, maxDepth: maxDepth)
    print("")
    print("  total       \(formatBytes(result.root.size))")
    print("  files       \(result.root.fileCount)")
    print("  duration    \(String(format: "%.2fs", result.duration))")
    if result.deduplicatedBytes > 0 {
        print("  deduped     \(formatBytes(result.deduplicatedBytes)) (hardlinks / clones)")
    }
    if result.inaccessibleCount > 0 {
        print("  unreadable  \(result.inaccessibleCount) directories — total is a lower bound")
    }

case "volumes":
    if arguments.contains("--verbose") {
        print("All mount points reported by FileManager:")
        let keys: [URLResourceKey] = [
            .volumeNameKey, .volumeTotalCapacityKey, .volumeIsInternalKey,
            .volumeIsRemovableKey, .volumeIsBrowsableKey, .volumeIsLocalKey,
        ]
        for url in FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: keys, options: []) ?? []
        {
            let values = try? url.resourceValues(forKeys: Set(keys))
            print(
                "  \(url.path)\n"
                    + "     name=\(values?.volumeName ?? "?") "
                    + "capacity=\(values?.volumeTotalCapacity ?? -1) "
                    + "local=\(String(describing: values?.volumeIsLocal)) "
                    + "browsable=\(String(describing: values?.volumeIsBrowsable)) "
                    + "internal=\(String(describing: values?.volumeIsInternal)) "
                    + "removable=\(String(describing: values?.volumeIsRemovable))")
        }
        print("")
    }
    let volumes = VolumeCatalog.mountedVolumes()
    guard !volumes.isEmpty else {
        print("No volumes found.")
        exit(1)
    }
    for volume in volumes {
        let kind = volume.isRemovable ? "removable" : (volume.isInternal ? "internal" : "external")
        print("  \(formatBytes(volume.totalCapacity).padded(to: 10))  \(volume.name)  [\(kind)]")
        print("  \(String(repeating: " ", count: 12))\(volume.path)")
    }
    print("\n  default: \(VolumeCatalog.defaultVolume()?.name ?? "none")")

case "recommend":
    let path = arguments.count >= 3 ? arguments[2] : NSHomeDirectory()
    let result = try await VolumeScanner().scan(path: path)
    let recommendations = RecommendationEngine.analyze(result: result)

    var lastTier: Recommendation.Tier?
    var total: UInt64 = 0
    for item in recommendations.prefix(30) {
        if item.tier != lastTier {
            print("\n\(item.tier.label)")
            lastTier = item.tier
        }
        print("  \(formatBytes(item.size).padded(to: 10))  \(item.title)")
        print("  \(String(repeating: " ", count: 12))\(item.displayPath)")
        total &+= item.size
    }
    print("\n  \(recommendations.count) suggestions, \(formatBytes(total)) shown")
    print("  full disk access: \(FullDiskAccess.isGranted ? "granted" : "NOT granted")")

case "mole":
    let client = MoleClient()
    guard let path = client.locateBinary() else {
        print("Mole not found. Install with: brew install mole")
        exit(1)
    }
    print("Found mole at \(path)")
    let report = try await client.dryRun()
    switch report {
    case .parsed(let categories, let total):
        for category in categories {
            print("\n\(category.name)")
            for item in category.items {
                print("  \(formatBytes(item.size).padded(to: 10))  \(item.name)")
            }
        }
        print("\n  reclaimable \(formatBytes(total))")
    case .unparseable(let reason):
        print("Could not parse Mole output: \(reason)")
    }

default:
    print("unknown command '\(arguments[1])'")
    exit(1)
}
