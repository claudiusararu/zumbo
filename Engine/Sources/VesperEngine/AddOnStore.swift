import CryptoKit
import Foundation
import os

/// Where an add-on's catalog, manifest and zip live. One bucket, one base
/// URL, used by every add-on (today: speaker labels; later: the speech
/// engine's repair re-download).
public enum AddOnCatalog {
    /// Cloudflare R2 bucket `vesper-models`, attached to the custom domain
    /// models.zumbo.app (certificate active, verified with curl 2026-09-20).
    public static let baseURL = URL(string: "https://models.zumbo.app")!

    static let catalogPath = "catalog.json"
}

/// The bucket root's `catalog.json`: which manifest is current for each
/// add-on. Old app builds that only know about `speaker-labels` keep
/// working after a new add-on is added, and a new model version is a new
/// versioned folder plus one line here.
struct AddOnCatalogFile: Codable {
    struct Entry: Codable {
        let version: Int
        let manifest: String
    }
    let addons: [String: Entry]
}

/// One add-on version's manifest, uploaded next to its zip.
public struct AddOnManifest: Codable, Sendable, Equatable {
    public let id: String
    public let version: Int
    public let displayVersion: String
    public let zipSizeBytes: Int64
    public let installedSizeBytes: Int64
    public let sha256: String
    public let minAppBuild: Int
    /// Path inside the zip (and so inside the installed directory) that the
    /// consumer hands to whatever loads the add-on - for speaker labels, the
    /// compiled Sortformer model `MLModel(contentsOf:)` loads.
    public let rootPath: String

    /// The zip's path on the bucket, derived from the manifest's own path by
    /// convention (`scripts/package-addon.sh` writes both into the same
    /// versioned folder): `<addonID>/v<version>/<addonID>-v<version>.zip`.
    var zipObjectPath: String {
        "\(id)/v\(version)/\(id)-v\(version).zip"
    }
}

/// The `installed.json` marker written into an add-on version's install
/// directory once the zip is verified and unzipped. Its presence, read with
/// no network call, is the sole source of truth for "is this add-on
/// installed" at launch.
public struct AddOnInstalledMarker: Codable, Sendable, Equatable {
    public let version: Int
    public let installedSizeBytes: Int64
    public let rootPath: String
}

public enum AddOnError: Error, LocalizedError, Sendable {
    case addOnNotInCatalog(String)
    case badServerResponse
    case hashMismatch(expected: String, actual: String)
    case unzipFailed(String)

    public var errorDescription: String? {
        switch self {
        case .addOnNotInCatalog(let id): return "\(id) is not in the add-on catalog"
        case .badServerResponse: return "the server did not return the expected data"
        case .hashMismatch: return "the downloaded file did not match its checksum"
        case .unzipFailed(let message): return "could not unpack the download: \(message)"
        }
    }
}

/// Downloads, verifies and installs one add-on from our own R2 bucket - never
/// Hugging Face at runtime. Shared by `SpeakerModelManager` (the app and
/// `zumbo-cli meeting`) and `zumbo-cli addon install`.
///
/// `@MainActor` so `statusUpdates` can drive SwiftUI directly, matching
/// `SpeakerModelManager`'s existing pattern; the network/disk work inside
/// `install()` still runs off the main thread via `async`/`await` and a
/// background `URLSessionDownloadTask`.
@MainActor
public final class AddOnStore: NSObject {
    private let log = Logger(subsystem: "com.claudiusararu.zumbo", category: "addon-store")

    public let addOnID: String
    private let urlSession: URLSession
    private var downloadTask: URLSessionDownloadTask?
    private var progressContinuation: AsyncStream<(Int64, Int64)>.Continuation?

    public private(set) var status: SpeakerModelStatus = .notDownloaded
    private let statusContinuation: AsyncStream<SpeakerModelStatus>.Continuation
    public nonisolated let statusUpdates: AsyncStream<SpeakerModelStatus>

    public init(addOnID: String) {
        self.addOnID = addOnID
        let config = URLSessionConfiguration.default
        config.waitsForConnectivity = true
        self.urlSession = URLSession(configuration: config)
        var continuation: AsyncStream<SpeakerModelStatus>.Continuation!
        self.statusUpdates = AsyncStream { continuation = $0 }
        self.statusContinuation = continuation
        super.init()
        refreshFromDisk()
    }

    // MARK: - Paths

    public nonisolated static var addOnsRootDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Zumbo/AddOns")
    }

    /// `AddOns/<id>/v<version>/` - everything for one installed version.
    public func versionDirectory(version: Int) -> URL {
        Self.addOnsRootDirectory.appendingPathComponent(addOnID).appendingPathComponent("v\(version)")
    }

    /// Reads the marker for the highest version directory present, with no
    /// network call - used at launch and by `isReady`/`installedRootURL`.
    /// Pure and disk-only so it is unit-testable against a temp directory.
    public nonisolated static func installedMarker(addOnID: String, root: URL = AddOnStore.addOnsRootDirectory) -> (
        marker: AddOnInstalledMarker, versionDirectory: URL
    )? {
        let addOnDir = root.appendingPathComponent(addOnID)
        guard
            let entries = try? FileManager.default.contentsOfDirectory(
                at: addOnDir, includingPropertiesForKeys: nil)
        else { return nil }
        let versionDirs = entries.filter { $0.lastPathComponent.hasPrefix("v") }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
        for dir in versionDirs {
            let markerURL = dir.appendingPathComponent("installed.json")
            guard let data = try? Data(contentsOf: markerURL),
                let marker = try? JSONDecoder().decode(AddOnInstalledMarker.self, from: data)
            else { continue }
            return (marker, dir)
        }
        return nil
    }

    private func refreshFromDisk() {
        guard let (marker, _) = Self.installedMarker(addOnID: addOnID) else { return }
        setStatus(.ready(sizeBytes: marker.installedSizeBytes))
    }

    public var isReady: Bool {
        if case .ready = status { return true }
        return false
    }

    /// The root the consumer should load from, e.g. for speaker labels:
    /// `versionDirectory/rootPath` (the compiled Sortformer `.mlmodelc`).
    /// Nil unless a marker is on disk.
    public var installedRootURL: URL? {
        guard let (marker, dir) = Self.installedMarker(addOnID: addOnID) else { return nil }
        return dir.appendingPathComponent(marker.rootPath)
    }

    // MARK: - Install

    /// Fetches the catalog, then the manifest, downloads the zip, verifies
    /// its SHA-256 against the manifest before anything else happens, unzips
    /// it into place and writes the marker. Any failure leaves no partial
    /// files behind. Safe to call again after `cancel()` or a failure.
    public func install() async {
        setStatus(.downloading(fraction: 0, receivedBytes: 0, totalBytes: 0))
        do {
            let manifest = try await fetchManifest()
            let zipURL = try await downloadZip(manifest: manifest)
            defer { try? FileManager.default.removeItem(at: zipURL) }

            let destination = versionDirectory(version: manifest.version)
            // Hashing a 220 MB file and running `ditto` both block the
            // thread they run on for real time; do both off the main actor
            // so the progress UI and the rest of the app stay responsive.
            let markerURL = destination.appendingPathComponent("installed.json")
            try await Task.detached(priority: .utility) {
                try Self.verifyHash(of: zipURL, expected: manifest.sha256)
                try Self.install(zipURL: zipURL, manifest: manifest, into: destination, markerURL: markerURL)
            }.value

            setStatus(.ready(sizeBytes: manifest.installedSizeBytes))
            log.info("\(self.addOnID, privacy: .public) add-on installed, \(manifest.installedSizeBytes / 1_000_000) MB")
        } catch is CancellationError {
            setStatus(.cancelled)
        } catch {
            if (error as NSError).code == NSURLErrorCancelled {
                setStatus(.cancelled)
            } else {
                log.error("\(self.addOnID, privacy: .public) add-on install failed: \(error.localizedDescription, privacy: .public)")
                setStatus(.failed(error.localizedDescription))
            }
        }
        downloadTask = nil
    }

    /// Cancels an in-flight download and removes any partial file. Does not
    /// remove an already-installed version.
    public func cancel() {
        downloadTask?.cancel()
        downloadTask = nil
        setStatus(.cancelled)
    }

    /// Deletes the installed version's directory and returns the row to "not
    /// installed". Files only - never touches the network.
    public func remove() throws {
        guard let (_, dir) = Self.installedMarker(addOnID: addOnID) else { return }
        try FileManager.default.removeItem(at: dir)
        setStatus(.notDownloaded)
    }

    private func fetchManifest() async throws -> AddOnManifest {
        let catalogURL = AddOnCatalog.baseURL.appendingPathComponent(AddOnCatalog.catalogPath)
        let (catalogData, catalogResponse) = try await urlSession.data(from: catalogURL)
        try Self.checkOK(catalogResponse)
        let catalog = try JSONDecoder().decode(AddOnCatalogFile.self, from: catalogData)
        guard let entry = catalog.addons[addOnID] else { throw AddOnError.addOnNotInCatalog(addOnID) }

        let manifestURL = AddOnCatalog.baseURL.appendingPathComponent(entry.manifest)
        let (manifestData, manifestResponse) = try await urlSession.data(from: manifestURL)
        try Self.checkOK(manifestResponse)
        return try JSONDecoder().decode(AddOnManifest.self, from: manifestData)
    }

    private static func checkOK(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw AddOnError.badServerResponse
        }
    }

    /// Downloads the zip with a `URLSessionDownloadTask` (resumable: on
    /// failure the system hands back resume data, which the next `install()`
    /// call uses automatically) and reports byte-accurate progress on
    /// `statusUpdates`.
    private func downloadZip(manifest: AddOnManifest) async throws -> URL {
        let zipURL = AddOnCatalog.baseURL.appendingPathComponent(manifest.zipObjectPath)
        let delegate = DownloadProgressDelegate()
        delegate.onProgress = { [weak self] received, total in
            guard let self else { return }
            Task { @MainActor in
                let expected = total > 0 ? total : manifest.zipSizeBytes
                self.setStatus(
                    .downloading(
                        fraction: expected > 0 ? Double(received) / Double(expected) : 0,
                        receivedBytes: received, totalBytes: expected))
            }
        }

        let task = urlSession.downloadTask(with: zipURL)
        downloadTask = task
        return try await withTaskCancellationHandler(
            operation: {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, Error>) in
                    delegate.onFinish = { location in
                        // `location` is deleted by the system right after this
                        // delegate call returns; move it somewhere durable now.
                        let staged = FileManager.default.temporaryDirectory
                            .appendingPathComponent("zumbo-addon-\(UUID().uuidString).zip")
                        do {
                            try FileManager.default.moveItem(at: location, to: staged)
                            continuation.resume(returning: staged)
                        } catch {
                            continuation.resume(throwing: error)
                        }
                    }
                    delegate.onError = { error in
                        continuation.resume(throwing: error ?? AddOnError.badServerResponse)
                    }
                    task.delegate = delegate
                    self.retainedDelegate = delegate
                    task.resume()
                }
            },
            onCancel: { [weak task] in
                task?.cancel()
            })
    }

    /// Kept alive for the duration of one download so the `URLSessionTask`'s
    /// delegate reference (weak on some platforms) does not vanish mid-flight.
    private var retainedDelegate: DownloadProgressDelegate?

    private nonisolated static func verifyHash(of fileURL: URL, expected: String) throws {
        let actual = try Self.sha256Hex(of: fileURL)
        guard actual.caseInsensitiveCompare(expected) == .orderedSame else {
            throw AddOnError.hashMismatch(expected: expected, actual: actual)
        }
    }

    /// Streams the file in fixed-size chunks so a 220 MB zip never has to be
    /// loaded into memory at once.
    public nonisolated static func sha256Hex(of fileURL: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let chunk = try handle.read(upToCount: 4 * 1024 * 1024) ?? Data()
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Unzips with `/usr/bin/ditto -x -k` (no third-party unzip) into a
    /// staging directory, confirms `rootPath` is really inside it, then
    /// atomically swaps it into place - so a crash mid-unzip never leaves a
    /// half-installed directory that reads as "installed".
    private nonisolated static func install(zipURL: URL, manifest: AddOnManifest, into destination: URL, markerURL: URL) throws {
        let fm = FileManager.default
        let staging = fm.temporaryDirectory.appendingPathComponent("zumbo-addon-unzip-\(UUID().uuidString)")
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-x", "-k", zipURL.path, staging.path]
        let stderrPipe = Pipe()
        process.standardError = stderrPipe
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let message = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw AddOnError.unzipFailed(message)
        }

        let rootInStaging = staging.appendingPathComponent(manifest.rootPath)
        guard fm.fileExists(atPath: rootInStaging.path) else {
            throw AddOnError.unzipFailed("expected \(manifest.rootPath) was not in the archive")
        }

        try? fm.removeItem(at: destination)
        try fm.createDirectory(
            at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.moveItem(at: staging, to: destination)

        let marker = AddOnInstalledMarker(
            version: manifest.version, installedSizeBytes: manifest.installedSizeBytes, rootPath: manifest.rootPath)
        let markerData = try JSONEncoder().encode(marker)
        try markerData.write(to: markerURL)
    }

    private func setStatus(_ new: SpeakerModelStatus) {
        status = new
        statusContinuation.yield(new)
    }
}

/// Bridges `URLSessionDownloadTask`'s delegate callbacks (background thread)
/// to the closures `AddOnStore` awaits on the main actor.
private final class DownloadProgressDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    var onProgress: ((Int64, Int64) -> Void)?
    var onFinish: ((URL) -> Void)?
    var onError: ((Error?) -> Void)?

    func urlSession(
        _ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64
    ) {
        onProgress?(totalBytesWritten, totalBytesExpectedToWrite)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        onFinish?(location)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error else { return }
        onError?(error)
    }
}
