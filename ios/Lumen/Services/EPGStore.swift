import Foundation
import Observation
import SwiftUI

/// Un programma della guida TV.
struct EPGProgram: Codable, Hashable {
    var start: Date
    var stop: Date
    var title: String
    var desc: String?

    var isNow: Bool { let n = Date(); return start <= n && n < stop }
    var progress: Double {
        let total = stop.timeIntervalSince(start)
        return total > 0 ? min(1, max(0, Date().timeIntervalSince(start) / total)) : 0
    }
}

/// Guida TV (EPG) in formato XMLTV, anche compressa (.xml.gz).
/// L'indirizzo arriva dall'intestazione della playlist (url-tvg) o si inserisce a mano.
/// Si conservano solo i programmi delle prossime 36 ore per i canali importati.
@MainActor
@Observable
final class EPGStore {
    static let shared = EPGStore()

    private(set) var programs: [String: [EPGProgram]] = [:]   // id della diretta (indirizzo) → programmi
    private(set) var lastUpdate: Date?
    private(set) var isUpdating = false
    private(set) var status: String?
    var url: String {
        didSet { UserDefaults.standard.set(url, forKey: "lumen.epg.url") }
    }

    nonisolated private static var file: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("epg.json")
    }

    private struct Saved: Codable {
        var programs: [String: [EPGProgram]]
        var lastUpdate: Date
    }

    private init() {
        url = UserDefaults.standard.string(forKey: "lumen.epg.url") ?? ""
        Task { [weak self] in
            let saved = await Task.detached(priority: .utility) { () -> Saved? in
                guard let data = try? Data(contentsOf: EPGStore.file) else { return nil }
                return try? JSONDecoder().decode(Saved.self, from: data)
            }.value
            guard let self, let saved, self.programs.isEmpty else { return }
            self.programs = saved.programs
            self.lastUpdate = saved.lastUpdate
        }
    }

    /// Indirizzo trovato nella playlist: usato se non ne è già impostato uno.
    func suggest(_ epg: String) {
        if url.trimmingCharacters(in: .whitespaces).isEmpty { url = epg }
    }

    func now(for channel: LinkMedia) -> EPGProgram? { programs[channel.id]?.first { $0.isNow } }

    func upcoming(for channel: LinkMedia) -> [EPGProgram] {
        let n = Date()
        return (programs[channel.id] ?? []).filter { $0.stop > n }
    }

    /// Aggiorna se la guida ha più di 12 ore.
    func refreshIfNeeded(channels: [LinkMedia]) async {
        if url.trimmingCharacters(in: .whitespaces).isEmpty, let found = PlaylistStore.shared.detectEPGURL() { url = found }
        if let last = lastUpdate, Date().timeIntervalSince(last) < 12 * 3600 { return }
        await refresh(channels: channels)
    }

    func refresh(channels: [LinkMedia]) async {
        let address = url.trimmingCharacters(in: .whitespaces)
        guard !isUpdating, !channels.isEmpty, let source = URL(string: address), source.scheme?.hasPrefix("http") == true else {
            if url.isEmpty { status = "Nessun indirizzo della guida TV." }
            return
        }
        isUpdating = true
        status = "Scaricamento della guida…"
        defer { isUpdating = false }

        var request = URLRequest(url: source, timeoutInterval: 240)
        request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 Lumen", forHTTPHeaderField: "User-Agent")
        guard let pair = try? await URLSession.shared.download(for: request),
              let http = pair.1 as? HTTPURLResponse, (200..<400).contains(http.statusCode) else {
            status = "Impossibile scaricare la guida TV."
            return
        }
        status = "Lettura dei programmi…"
        // tvg-id aggiornati dalle playlist salvate (le dirette importate prima non li avevano).
        var tvg: [String: String] = [:]
        for p in PlaylistStore.shared.playlists {
            for m in PlaylistStore.shared.media(of: p) where m.isLive { if let t = m.tvgId { tvg[m.id] = t } }
        }
        let targets: [(id: String, tvg: String?, name: String)] = channels.map { (id: $0.id, tvg: $0.tvgId ?? tvg[$0.id], name: $0.title) }
        let tmp = pair.0
        let result = await Task.detached(priority: .userInitiated) { () -> [String: [EPGProgram]]? in
            defer { try? FileManager.default.removeItem(at: tmp) }
            guard var data = try? Data(contentsOf: tmp) else { return nil }
            if data.starts(with: [0x1f, 0x8b]) { guard let raw = Gzip.decompress(data) else { return nil }; data = raw }
            return XMLTVParser.parse(data, targets: targets)
        }.value
        guard let result else { status = "La guida TV non è in un formato valido (XMLTV)."; return }
        programs = result
        lastUpdate = Date()
        let matched = result.values.filter { !$0.isEmpty }.count
        status = "Guida aggiornata: \(matched) canali su \(channels.count)."
        let saved = Saved(programs: result, lastUpdate: lastUpdate!)
        let file = Self.file
        Task.detached(priority: .utility) {
            if let data = try? JSONEncoder().encode(saved) { try? data.write(to: file, options: .atomic) }
        }
    }

    nonisolated static func normalize(_ name: String) -> String {
        var s = name.lowercased().folding(options: [.diacriticInsensitive], locale: nil)
        // prefissi tipo "IT:", "|IT|", "[IT]" e qualità
        s = s.replacingOccurrences(of: #"^\s*(\|[^|]{1,6}\||\[[^\]]{1,8}\]|[a-z]{2,3}\s*[:\-|])\s*"#, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: #"\b(fhd|uhd|hd|sd|4k|hevc|h265|1080p?|720p?|backup|bk)\b"#, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: #"\.(it|tv|com)$"#, with: "", options: .regularExpression)
        return s.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }.joined()
    }
}

/// Lettura XMLTV a flusso: canali (id, nomi) e programmi nella finestra -2h … +36h.
final class XMLTVParser: NSObject, XMLParserDelegate {
    private var channelNames: [String: [String]] = [:]
    private var programs: [String: [EPGProgram]] = [:]
    private var currentChannel: String?
    private var currentProgramChannel: String?
    private var start: Date?
    private var stop: Date?
    private var title = ""
    private var desc = ""
    private var text = ""
    private var element = ""
    private let from = Date().addingTimeInterval(-2 * 3600)
    private let to = Date().addingTimeInterval(36 * 3600)
    private let formatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMddHHmmss Z"
        return f
    }()

    static func parse(_ data: Data, targets: [(id: String, tvg: String?, name: String)]) -> [String: [EPGProgram]]? {
        let p = XMLTVParser()
        let parser = XMLParser(data: data)
        parser.delegate = p
        guard parser.parse() || !p.programs.isEmpty else { return nil }
        // Abbinamento: prima tvg-id, poi nome del canale
        var byName: [String: String] = [:]
        for (cid, names) in p.channelNames {
            for n in names { let k = EPGStore.normalize(n); if !k.isEmpty, byName[k] == nil { byName[k] = cid } }
            let k = EPGStore.normalize(cid); if !k.isEmpty, byName[k] == nil { byName[k] = cid }
        }
        var out: [String: [EPGProgram]] = [:]
        for t in targets {
            var cid: String?
            if let tvg = t.tvg, p.programs[tvg] != nil { cid = tvg }
            if cid == nil, let tvg = t.tvg { cid = byName[EPGStore.normalize(tvg)] }
            if cid == nil { cid = byName[EPGStore.normalize(t.name)] }
            if let cid, let list = p.programs[cid] { out[t.id] = list.sorted { $0.start < $1.start } }
        }
        return out
    }

    private func date(_ s: String?) -> Date? {
        guard let s else { return nil }
        let t = s.trimmingCharacters(in: .whitespaces)
        if let d = formatter.date(from: t) { return d }
        // senza fuso orario
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyyMMddHHmmss"
        return f.date(from: String(t.prefix(14)))
    }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?,
                attributes: [String: String] = [:]) {
        element = name
        text = ""
        switch name {
        case "channel":
            currentChannel = attributes["id"]
            if let id = currentChannel, channelNames[id] == nil { channelNames[id] = [] }
        case "programme":
            let s = date(attributes["start"]), e = date(attributes["stop"])
            if let s, let e, e > from, s < to {
                currentProgramChannel = attributes["channel"]
                start = s; stop = e; title = ""; desc = ""
            } else {
                currentProgramChannel = nil
            }
        default: break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch name {
        case "display-name":
            if let id = currentChannel, !value.isEmpty { channelNames[id, default: []].append(value) }
        case "channel":
            currentChannel = nil
        case "title":
            if currentProgramChannel != nil, title.isEmpty { title = value }
        case "desc":
            if currentProgramChannel != nil, desc.isEmpty { desc = value }
        case "programme":
            if let ch = currentProgramChannel, let s = start, let e = stop, !title.isEmpty {
                programs[ch, default: []].append(EPGProgram(start: s, stop: e, title: title, desc: desc.isEmpty ? nil : desc))
            }
            currentProgramChannel = nil
        default: break
        }
        text = ""
    }
}

/// Decompressione gzip (le guide XMLTV sono spesso .xml.gz).
enum Gzip {
    static func decompress(_ data: Data) -> Data? {
        let bytes = [UInt8](data)
        guard bytes.count > 18, bytes[0] == 0x1f, bytes[1] == 0x8b, bytes[2] == 8 else { return nil }
        let flags = bytes[3]
        var i = 10
        if flags & 0x04 != 0 { guard i + 2 <= bytes.count else { return nil }; i += 2 + Int(bytes[i]) | (Int(bytes[i + 1]) << 8) }
        if flags & 0x08 != 0 { while i < bytes.count, bytes[i] != 0 { i += 1 }; i += 1 }
        if flags & 0x10 != 0 { while i < bytes.count, bytes[i] != 0 { i += 1 }; i += 1 }
        if flags & 0x02 != 0 { i += 2 }
        guard i < bytes.count - 8 else { return nil }
        let deflated = Data(bytes[i..<(bytes.count - 8)])
        // NSData .zlib = DEFLATE "raw", quello contenuto nei file gzip
        return try? (deflated as NSData).decompressed(using: .zlib) as Data
    }
}
