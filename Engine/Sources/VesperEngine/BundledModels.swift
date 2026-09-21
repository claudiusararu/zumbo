import Foundation
import os

/// The speech models that ship inside the app bundle, installed into
/// FluidAudio's own cache the first time the app runs.
///
/// Why a copy rather than pointing FluidAudio at the bundle: 0.15.7 lets only
/// one of the three loaders take a directory. `AsrModels.downloadAndLoad` has
/// a `to:` parameter, but `CustomVocabularyContext.loadWithCtcTokens` resolves
/// the CTC booster through `CtcModels.defaultCacheDirectory` with no override,
/// and `VadManager` falls back to its own `~/Library/Application
/// Support/FluidAudio` base whenever a directory is not passed all the way
/// down. Mixing "the bundle for ASR, the cache for the other two" would leave
/// two of the three models downloading on first launch, which is exactly what
/// bundling them is meant to prevent. So all three are copied into the cache
/// FluidAudio already uses, once, and every loader afterwards finds them
/// locally through its normal path. The copy also means an add-on download
/// (speaker labels) and a bundled model live in one place, so `ModelHub`'s
/// own completeness/recovery checks apply to both.
///
/// Cost: about 560 MB copied once, on first launch, from the read-only bundle
/// to Application Support. The alternative - shipping nothing and downloading
/// the same bytes - costs the same disk and needs a network.
///
/// Folder names are FluidAudio's `Repo.folderName` values for 0.15.7, not
/// names of our own: `parakeet-tdt-0.6b-v3-coreml` (`.parakeetV3`),
/// `parakeet-ctc-110m-coreml` (`.parakeetCtc110m`) and `silero-vad-coreml`
/// (`.vad`). If FluidAudio is ever unpinned, these have to be rechecked
/// against `ModelNames.Repo.folderName` or the copies land beside the cache
/// instead of in it and everything silently re-downloads.
///
/// Speaker labels (sortformer, ~230 MB) are deliberately not here: that is an
/// add-on the owner turns on in Settings > Models, downloaded on demand by
/// `SpeakerModelManager`.
public enum BundledModels {

    private static let log = Logger(subsystem: "com.claudiusararu.zumbo", category: "bundled-models")

    /// Bundle folder name -> one file that must exist inside it for the copy
    /// to be worth making. Guards against a half-built bundle shipping a
    /// truncated model that FluidAudio would then have to repair.
    private static let models: [(folder: String, sentinel: String)] = [
        ("parakeet-tdt-0.6b-v3-coreml", "Preprocessor.mlmodelc"),
        ("parakeet-ctc-110m-coreml", "AudioEncoder.mlmodelc"),
        ("silero-vad-coreml", "silero-vad-unified-256ms-v6.2.1.mlmodelc"),
    ]

    /// FluidAudio 0.15.7's cache root:
    /// `~/Library/Application Support/FluidAudio/Models`.
    /// Mirrors `MLModelConfigurationUtils.defaultModelsDirectory`, which is
    /// public but takes a `Repo` this package deliberately does not name.
    static var cacheDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FluidAudio", isDirectory: true)
            .appendingPathComponent("Models", isDirectory: true)
    }

    /// Copies any bundled model that is not already in the cache. Cheap and
    /// idempotent once the copies exist (three `fileExists` calls), so every
    /// model-loading entry point can call it without coordinating.
    ///
    /// Never throws: a failed copy is not fatal, it just means FluidAudio
    /// downloads that model the way it always did.
    public static func installIfNeeded(bundle: Bundle = .main) {
        guard let resources = bundle.resourceURL else { return }
        let source = resources.appendingPathComponent("Models", isDirectory: true)
        let fm = FileManager.default
        guard fm.fileExists(atPath: source.path) else { return }

        let cache = cacheDirectory
        for model in models {
            let destination = cache.appendingPathComponent(model.folder, isDirectory: true)
            guard !fm.fileExists(atPath: destination.path) else { continue }
            let bundled = source.appendingPathComponent(model.folder, isDirectory: true)
            guard fm.fileExists(atPath: bundled.appendingPathComponent(model.sentinel).path) else {
                log.info("no bundled copy of \(model.folder, privacy: .public)")
                continue
            }
            do {
                try fm.createDirectory(at: cache, withIntermediateDirectories: true)
                // Into a temporary name first, then one atomic move: a copy
                // interrupted by a quit must never leave a half-written model
                // at the real path, where FluidAudio would read it as a
                // complete one.
                let staging = cache.appendingPathComponent(
                    ".\(model.folder).installing", isDirectory: true)
                if fm.fileExists(atPath: staging.path) { try fm.removeItem(at: staging) }
                try fm.copyItem(at: bundled, to: staging)
                try fm.moveItem(at: staging, to: destination)
                log.info("installed bundled \(model.folder, privacy: .public)")
            } catch {
                log.error(
                    "could not install bundled \(model.folder, privacy: .public): \(error.localizedDescription, privacy: .public)"
                )
            }
        }
    }
}
