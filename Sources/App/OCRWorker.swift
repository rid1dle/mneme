import AppKit
import ImageIO
import Vision

/// Reads the text in images so search finds it. A just-copied image is read about 2 s later (if the Mac is cool);
/// the backlog only while the user has been away a minute and the Mac is cool, one image at a time.
@MainActor
final class OCRWorker {
    private let store: Store
    private let storeQueue: DispatchQueue
    private let onRead: () -> Void
    private let work = DispatchQueue(label: "local.mneme.ocr", qos: .utility)
    private var busy = false
    private var timer: Timer?

    init(store: Store, storeQueue: DispatchQueue, onRead: @escaping () -> Void) {
        self.store = store
        self.storeQueue = storeQueue
        self.onRead = onRead
    }

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.readBacklog() }
        }
        timer?.tolerance = 10
    }

    func readSoon(_ item: Item) {
        guard item.kind == .image else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            MainActor.assumeIsolated {
                guard mayReadNewImage(thermal: ProcessInfo.processInfo.thermalState) else { return }
                self.read([item.id]) {}
            }
        }
    }

    private static var idleSeconds: Double {
        CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
    }

    private static func gateOpen() -> Bool {
        mayRunBackgroundWork(idleSeconds: idleSeconds, thermal: ProcessInfo.processInfo.thermalState)
    }

    private func readBacklog() {
        guard !busy, Self.gateOpen() else { return }
        storeQueue.async { [store] in
            let ids = ((try? store.pendingOCR(limit: 1)) ?? []).map(\.id)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard !ids.isEmpty else { return }
                    self.read(ids) { if Self.gateOpen() { self.readBacklog() } }
                }
            }
        }
    }

    private func read(_ ids: [UUID], then: @escaping () -> Void) {
        guard !busy, let id = ids.first else { return }
        busy = true
        storeQueue.async { [store, work] in
            let data = (try? store.representations(id))?.first { PasteType.images.contains($0.type) }?.data
                ?? (try? store.item(id)).flatMap { $0.flatMap(imageFile(of:)) }.flatMap { try? Data(contentsOf: $0, options: .mappedIfSafe) }
            work.async {
                let text = data.flatMap(Self.recognize) ?? ""
                self.storeQueue.async {
                    try? self.store.setOCRText(id, text: text)
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated {
                            self.busy = false
                            if !text.isEmpty { self.onRead() }
                            then()
                        }
                    }
                }
            }
        }
    }

    /// Reads the image in a short-lived copy of Mneme (`--read-text`, image on stdin, text on stdout): Vision keeps
    /// its models loaded for the life of a process (+16 MB measured), so they leave with the helper instead.
    nonisolated private static func recognize(_ data: Data) -> String? {
        guard let exe = Bundle.main.executablePath else { return nil }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = ["--read-text"]
        let input = Pipe(), output = Pipe()
        p.standardInput = input
        p.standardOutput = output
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let kill = DispatchWorkItem { if p.isRunning { p.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 30, execute: kill)
        try? input.fileHandleForWriting.write(contentsOf: data)
        try? input.fileHandleForWriting.close()
        let out = output.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        kill.cancel()
        return p.terminationStatus == 0 ? String(data: out, encoding: .utf8) : nil
    }
}

/// The helper's side: text lines found in the image, scaled to at most 2400 px first to bound memory.
enum TextReader {
    static func run() -> Never {
        let data = FileHandle.standardInput.readDataToEndOfFile()
        guard let src = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let image = CGImageSourceCreateThumbnailAtIndex(src, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: 2400,
              ] as CFDictionary) else { exit(1) }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = true
        do { try VNImageRequestHandler(cgImage: image).perform([request]) } catch { exit(1) }
        let text = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
        FileHandle.standardOutput.write(Data(text.utf8))
        exit(0)
    }
}
