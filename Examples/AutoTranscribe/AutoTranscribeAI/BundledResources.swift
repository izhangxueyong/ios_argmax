import Foundation

/// Resolves bundled files under both packaging styles:
///  * Xcode folder references -> files at the app bundle root or in `Models/`
///  * SwiftPM / xtool -> resources inside `<Product>_<Target>.bundle`
///
/// This lives in AutoTranscribeAI so both the app target (which imports this
/// module) and the AI target share one lookup implementation. It never changes
/// the behaviour of an Xcode build: if no resource bundle exists, the original
/// `Bundle.main` paths are still the first candidates checked.
public enum BundledResources {
    /// Main bundle first, then every resource bundle shipped inside it.
    public static var searchBundles: [Bundle] {
        var bundles: [Bundle] = [.main]
        let root = Bundle.main.bundleURL
        let names = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        for name in names where name.hasSuffix(".bundle") {
            if let bundle = Bundle(url: root.appendingPathComponent(name, isDirectory: true)) {
                bundles.append(bundle)
            }
        }
        return bundles
    }

    /// Finds a file such as `recording.wav` in the main bundle, in the
    /// `Resources/` or `Models/` folders, or inside a SwiftPM resource bundle.
    public static func url(forResource name: String,
                           withExtension ext: String? = nil,
                           subdirectory subdir: String? = nil) -> URL? {
        var subdirs: [String?] = [subdir]
        if subdir == nil { subdirs += ["Resources", "Models"] }

        for bundle in searchBundles {
            for candidate in subdirs {
                if let url = bundle.url(forResource: name, withExtension: ext, subdirectory: candidate),
                   FileManager.default.fileExists(atPath: url.path) {
                    return url
                }
            }
            // Plain path probe covers `.copy` folder references, which
            // Bundle.url(forResource:) does not always expose.
            let filename = ext.map { "\(name).\($0)" } ?? name
            var bases = [bundle.bundleURL]
            for candidate in subdirs.compactMap({ $0 }) {
                bases.append(bundle.bundleURL.appendingPathComponent(candidate, isDirectory: true))
            }
            for base in bases {
                let url = base.appendingPathComponent(filename, isDirectory: false)
                if FileManager.default.fileExists(atPath: url.path) { return url }
            }
        }
        return nil
    }

    /// Finds a bundled model directory such as `ai-models`, `whisper-base`,
    /// `whisper-turbo` at the bundle root, under `Models/`, or in a resource
    /// bundle. Returns nil when nothing is present (i.e. models not bundled).
    public static func directory(named name: String) -> URL? {
        for bundle in searchBundles {
            var candidates: [URL] = []
            if let url = bundle.url(forResource: name, withExtension: nil) {
                candidates.append(url)
            }
            if let url = bundle.url(forResource: name, withExtension: nil, subdirectory: "Models") {
                candidates.append(url)
            }
            let bases = [
                bundle.bundleURL,
                bundle.bundleURL.appendingPathComponent("Models", isDirectory: true)
            ]
            for base in bases {
                candidates.append(base.appendingPathComponent(name, isDirectory: true))
            }
            for url in candidates {
                var isDir: ObjCBool = false
                if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir),
                   isDir.boolValue {
                    return url
                }
            }
        }
        return nil
    }
}
