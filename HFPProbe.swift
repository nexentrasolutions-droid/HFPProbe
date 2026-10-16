import SwiftUI
import AVFoundation
import UniformTypeIdentifiers

@main
struct HFPProbeApp: App {
    var body: some Scene {
        WindowGroup { ProbeView() }
    }
}

enum ProbeMode: String, CaseIterable, Identifiable {
    case standard = "Standard"
    case voice = "Sprache"
    case mixed = "Musik-Mix"
    var id: String { rawValue }
}

@MainActor
final class Probe: ObservableObject {
    @Published var mode = ProbeMode.standard
    @Published var status = "Gestoppt"
    @Published var log = ""
    @Published var ready = false

    private let session = AVAudioSession.sharedInstance()
    private var player: AVAudioPlayer?
    private var observers: [NSObjectProtocol] = []
    private var timer: Timer?
    private var generation = 0
    private var active = false

    init() {
        note("System: \(UIDevice.current.systemVersion)")
        observers.append(NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.note("Routenwechsel: \(self.route)")
                if self.active && !self.hasHFP {
                    self.stopTone()
                    self.ready = false
                    self.status = "HFP verloren; erneut aktivieren"
                }
            }
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: nil, queue: .main
        ) { [weak self] notification in
            let kind = (notification.userInfo?[
                AVAudioSessionInterruptionTypeKey
            ] as? NSNumber)?.uintValue
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.stop()
                self.note("Unterbrechung: \(kind == 1 ? "Beginn" : "Ende")")
                self.status = "Unterbrochen; manuell neu aktivieren"
            }
        })
    }

    deinit {
        observers.forEach {
            NotificationCenter.default.removeObserver($0)
        }
    }

    private var hasHFP: Bool {
        session.currentRoute.outputs.contains {
            $0.portType == .bluetoothHFP
        }
    }

    private var route: String {
        let input = session.currentRoute.inputs.map {
            "\($0.portName) [\($0.portType.rawValue)]"
        }.joined(separator: ", ")
        let output = session.currentRoute.outputs.map {
            "\($0.portName) [\($0.portType.rawValue)]"
        }.joined(separator: ", ")
        return "IN: \(input); OUT: \(output)"
    }

    func note(_ message: String) {
        log += "\(Date().ISO8601Format()) \(message)\n"
    }

    func snapshot() {
        note("\(route); Rate: \(session.sampleRate) Hz")
    }

    private func failure(_ message: String) -> NSError {
        NSError(domain: "HFPProbe", code: 1,
                userInfo: [NSLocalizedDescriptionKey: message])
    }

    func activate() async {
        stop()
        let attempt = generation
        let selected = mode
        status = "Verbindung wird eingerichtet"
        note("Aktivierung: \(selected.rawValue)")

        do {
            var options: AVAudioSession.CategoryOptions = [.allowBluetooth]
            if selected == .mixed { options.insert(.mixWithOthers) }

            try session.setCategory(
                .playAndRecord,
                mode: selected == .voice ? .voiceChat : .default,
                options: options
            )
            try session.setActive(true)
            active = true

            var input: AVAudioSessionPortDescription?
            for _ in 0..<30 {
                guard attempt == generation else { return }
                input = session.availableInputs?.first {
                    $0.portType == .bluetoothHFP
                }
                if input != nil { break }
                try await Task.sleep(nanoseconds: 100_000_000)
            }
            guard let input else {
                throw failure("Kein Bluetooth-Freisprecheingang gefunden.")
            }
            try session.setPreferredInput(input)

            for _ in 0..<30 {
                guard attempt == generation else { return }
                if hasHFP { break }
                try await Task.sleep(nanoseconds: 100_000_000)
            }
            guard attempt == generation else { return }
            snapshot()
            guard hasHFP else {
                throw failure("Kein bestätigter HFP-Ausgang.")
            }
            ready = true
            status = "HFP bereit"
        } catch {
            guard attempt == generation else { return }
            stop()
            status = error.localizedDescription
            note("Fehler: \(error.localizedDescription)")
        }
    }

    func play(_ data: Data? = nil) {
        guard ready, hasHFP else {
            note("Wiedergabe gesperrt: kein HFP-Ausgang.")
            return
        }
        stopTone()
        do {
            let next = try AVAudioPlayer(data: data ?? Self.tone())
            next.numberOfLoops = -1
            next.volume = 0.2
            next.prepareToPlay()
            guard hasHFP else {
                throw failure("HFP-Ausgang verloren.")
            }
            player = next
            guard next.play() else {
                throw failure("Wiedergabe konnte nicht starten.")
            }
            status = "Wiedergabe: maximal 60 Sekunden"
            note(data == nil ? "Testton gestartet" : "Audiodatei gestartet")
            snapshot()
            timer = Timer.scheduledTimer(
                withTimeInterval: 60, repeats: false
            ) { [weak self] _ in
                Task { @MainActor [weak self] in self?.stopTone() }
            }
        } catch {
            stopTone()
            status = error.localizedDescription
            note("Wiedergabefehler: \(error.localizedDescription)")
        }
    }

    func importAudio(_ result: Result<[URL], Error>) {
        do {
            guard let url = try result.get().first else { return }
            let access = url.startAccessingSecurityScopedResource()
            defer {
                if access { url.stopAccessingSecurityScopedResource() }
            }
            let size = try url.resourceValues(forKeys: [.fileSizeKey])
            guard (size.fileSize ?? 0) <= 20_000_000 else {
                throw failure("Bitte eine Audiodatei unter 20 MB wählen.")
            }
            play(try Data(contentsOf: url))
        } catch {
            note("Dateifehler: \(error.localizedDescription)")
            status = error.localizedDescription
        }
    }

    func stopTone() {
        timer?.invalidate()
        timer = nil
        player?.stop()
        player = nil
        status = ready ? "HFP bereit; Wiedergabe gestoppt" : "Gestoppt"
        note("Wiedergabe gestoppt")
    }

    func stop() {
        generation += 1
        ready = false
        stopTone()
        if active {
            do {
                try session.setActive(
                    false, options: .notifyOthersOnDeactivation
                )
                active = false
            } catch {
                note("Deaktivierungsfehler: \(error.localizedDescription)")
            }
        }
        status = "Gestoppt"
    }

    private static func tone() -> Data {
        let rate = 16_000
        let count = rate
        var data = Data()
        func append<T: FixedWidthInteger>(_ value: T) {
            var little = value.littleEndian
            Swift.withUnsafeBytes(of: &little) {
                data.append(contentsOf: $0)
            }
        }
        data.append(contentsOf: "RIFF".utf8)
        append(UInt32(36 + count * 2))
        data.append(contentsOf: "WAVEfmt ".utf8)
        append(UInt32(16))
        append(UInt16(1))
        append(UInt16(1))
        append(UInt32(rate))
        append(UInt32(rate * 2))
        append(UInt16(2))
        append(UInt16(16))
        data.append(contentsOf: "data".utf8)
        append(UInt32(count * 2))
        for i in 0..<count {
            let phase = 2 * Double.pi * 440 * Double(i) / Double(rate)
            append(Int16(sin(phase) * 8_000))
        }
        return data
    }
}

struct ProbeView: View {
    @StateObject private var probe = Probe()
    @State private var importing = false

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                Picker("Modus", selection: $probe.mode) {
                    ForEach(ProbeMode.allCases) {
                        Text($0.rawValue).tag($0)
                    }
                }
                .pickerStyle(.segmented)
                .onChange(of: probe.mode) { _ in probe.stop() }

                Text(probe.status).font(.headline)

                Button("HFP aktivieren") {
                    Task { await probe.activate() }
                }
                Button("Leisen Testton starten") { probe.play() }
                    .disabled(!probe.ready)
                Button("Audiodatei wählen") { importing = true }
                    .disabled(!probe.ready)
                Button("Wiedergabe stoppen") { probe.stopTone() }
                Button("Alles deaktivieren") { probe.stop() }
                Button("Route protokollieren") { probe.snapshot() }

                Text("Musik-Mix: Musik in einer anderen App starten, hier Musik-Mix wählen und HFP aktivieren. Ergebnis offen.")
                    .font(.footnote)

                ShareLink(item: probe.log) {
                    Label("Diagnose teilen", systemImage: "square.and.arrow.up")
                }

                ScrollView {
                    Text(probe.log)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding()
            .navigationTitle("Bluetooth-Audiotest")
            .fileImporter(
                isPresented: $importing,
                allowedContentTypes: [.audio],
                allowsMultipleSelection: false
            ) { probe.importAudio($0) }
        }
    }
}
