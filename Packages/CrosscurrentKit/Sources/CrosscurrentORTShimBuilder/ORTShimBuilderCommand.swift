import Foundation

private enum BuilderError: LocalizedError {
    case usage(String)
    case failed(String)

    var errorDescription: String? {
        switch self {
        case let .usage(value), let .failed(value): value
        }
    }
}

@main
private enum ORTShimBuilderCommand {
    static func main() throws {
        let root = try repositoryRoot()
        guard let modelDirectoryPath = argument("--model-dir") else {
            throw BuilderError.usage("Pass --model-dir <validated ORT candidate directory>.")
        }
        let modelDirectory = URL(fileURLWithPath: modelDirectoryPath, isDirectory: true)
        let archive = modelDirectory.appending(path: "runtime/onnxruntime-osx-arm64-1.29.0.tgz")
        guard FileManager.default.fileExists(atPath: archive.path) else {
            throw BuilderError.failed("Validated ONNX Runtime archive is missing: \(archive.path)")
        }
        let runtimeRoot = archive.deletingLastPathComponent()
        let listing = try run("/usr/bin/tar", ["-tzf", archive.path])
        let entries = listing.split(separator: "\n").map(String.init)
        guard !entries.isEmpty,
              entries.allSatisfy({ !$0.hasPrefix("/") && !$0.split(separator: "/").contains("..") })
        else { throw BuilderError.failed("ONNX Runtime archive contains an unsafe path.") }
        _ = try run("/usr/bin/tar", ["-xzf", archive.path, "-C", runtimeRoot.path])

        let distribution = runtimeRoot.appending(path: "onnxruntime-osx-arm64-1.29.0", directoryHint: .isDirectory)
        let include = distribution.appending(path: "include", directoryHint: .isDirectory)
        let library = distribution.appending(path: "lib", directoryHint: .isDirectory)
        let source = root.appending(path: "Qualification/ORTShim.cpp")
        let output = runtimeRoot.appending(path: "libcrosscurrent_ort_qualification.dylib")
        let relativeRPath = "@loader_path/onnxruntime-osx-arm64-1.29.0/lib"
        _ = try run("/usr/bin/xcrun", [
            "clang++", "-std=c++17", "-O2", "-dynamiclib",
            "-I", include.path,
            "-L", library.path,
            "-lonnxruntime",
            "-Wl,-rpath,\(relativeRPath)",
            "-install_name", "@rpath/libcrosscurrent_ort_qualification.dylib",
            source.path,
            "-o", output.path,
        ])
        print(output.path)
    }

    @discardableResult
    private static func run(_ executable: String, _ arguments: [String]) throws -> String {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = output
        try process.run()
        process.waitUntilExit()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        let text = String(decoding: data, as: UTF8.self)
        guard process.terminationStatus == 0 else {
            throw BuilderError.failed("\(executable) failed: \(text)")
        }
        return text
    }

    private static func argument(_ name: String) -> String? {
        guard let index = CommandLine.arguments.firstIndex(of: name),
              CommandLine.arguments.indices.contains(index + 1)
        else { return nil }
        return CommandLine.arguments[index + 1]
    }

    private static func repositoryRoot() throws -> URL {
        var current = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        while current.path != "/" {
            if FileManager.default.fileExists(atPath: current.appending(path: "AGENTS.md").path) {
                return current
            }
            current.deleteLastPathComponent()
        }
        throw BuilderError.usage("Run inside the Crosscurrent repository.")
    }
}
