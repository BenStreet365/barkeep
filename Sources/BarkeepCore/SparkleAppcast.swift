import Foundation

/// A Sparkle appcast: an RSS feed whose items each describe one version, with its download in an
/// `<enclosure>`. See https://sparkle-project.org/documentation/publishing/.
public enum SparkleAppcast {
    public struct Item: Equatable, Sendable {
        public var title: String?
        public var build: String
        public var shortVersion: String?
        public var url: String
        public var length: Int64?
        public var edSignature: String?
        public var date: Date?
        public var minimumSystemVersion: String?
        public var maximumSystemVersion: String?
        public var channel: String?
        public var informational = false
        public var hardwareRequirements: [String] = []
        /// The enclosure's `sparkle:os`, if any. Absent means macOS.
        public var os: String?
        public var installationType: String?
        public var releaseNotesURL: String?

        public var isForMac: Bool { os == nil || os == "macos" }
    }

    public static func parse(_ data: Data) throws -> [Item] {
        let document: XMLDocument
        do {
            // No external entities or DTDs: the feed comes from the network.
            document = try XMLDocument(data: data, options: [.nodePreserveCDATA])
        } catch {
            throw BarkeepError(.feedError, "The appcast is not valid XML: \(error.localizedDescription)")
        }
        let items = (try? document.nodes(forXPath: "//item")) ?? []
        return items.compactMap { node in
            guard let item = node as? XMLElement else { return nil }
            return parse(item)
        }
    }

    static func child(_ element: XMLElement, _ name: String) -> XMLElement? {
        element.children?.compactMap { $0 as? XMLElement }.first { $0.localName == name }
    }

    static func text(_ element: XMLElement, _ name: String) -> String? {
        child(element, name)?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }

    static func attribute(_ element: XMLElement, _ name: String) -> String? {
        element.attributes?.first { $0.localName == name }?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }

    static func parse(_ item: XMLElement) -> Item? {
        // The top-level enclosure is the full update; <sparkle:deltas> holds deltas, which are skipped.
        guard let enclosure = child(item, "enclosure"), let url = attribute(enclosure, "url") else { return nil }
        guard let build = text(item, "version") ?? attribute(enclosure, "version") else { return nil }
        var result = Item(build: build, url: url)
        result.title = text(item, "title")
        result.shortVersion = text(item, "shortVersionString") ?? attribute(enclosure, "shortVersionString")
        result.length = attribute(enclosure, "length").flatMap { Int64($0) }.flatMap { $0 > 0 ? $0 : nil }
        result.edSignature = attribute(enclosure, "edSignature")
        result.os = attribute(enclosure, "os")
        result.installationType = attribute(enclosure, "installationType")
        result.date = text(item, "pubDate").flatMap(DateParsing.parse)
        result.minimumSystemVersion = text(item, "minimumSystemVersion")
        result.maximumSystemVersion = text(item, "maximumSystemVersion")
        result.channel = text(item, "channel")
        result.informational = child(item, "informationalUpdate") != nil
        result.hardwareRequirements = text(item, "hardwareRequirements")?
            .split(whereSeparator: { $0 == "," || $0.isWhitespace }).map(String.init) ?? []
        result.releaseNotesURL = text(item, "releaseNotesLink") ?? text(item, "fullReleaseNotesLink")
        return result
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
