import Foundation

/// Parses a `GetZoneGroupState` SOAP response into the current groups.
///
/// The response nests an *escaped* `<ZoneGroupState>…</ZoneGroupState>` XML
/// document inside the SOAP body, so we parse in two passes: first unescape and
/// capture that inner document, then parse it for `ZoneGroup` / `ZoneGroupMember`
/// elements.
enum ZoneGroupTopology {

    struct Member { let uuid: String; let name: String; let ip: String }
    struct Group { let coordinator: String; let members: [Member] }

    static func parse(_ soapResponse: String) -> [Group] {
        guard let inner = extractZoneGroupState(from: soapResponse) else { return [] }
        let delegate = GroupsDelegate()
        let parser = XMLParser(data: Data(inner.utf8))
        parser.delegate = delegate
        parser.parse()
        return delegate.groups
    }

    /// Pull the (now-unescaped) inner ZoneGroupState XML string out of the SOAP
    /// envelope. XMLParser hands escaped entities back as plain characters, so
    /// the captured text is real XML we can re-parse.
    private static func extractZoneGroupState(from response: String) -> String? {
        let extractor = StateDelegate()
        let parser = XMLParser(data: Data(response.utf8))
        parser.delegate = extractor
        parser.parse()
        return extractor.buffer.isEmpty ? nil : extractor.buffer
    }

    private final class StateDelegate: NSObject, XMLParserDelegate {
        var buffer = ""
        private var capturing = false

        func parser(_ parser: XMLParser, didStartElement elementName: String,
                    namespaceURI: String?, qualifiedName qName: String?,
                    attributes attributeDict: [String: String]) {
            if elementName == "ZoneGroupState" { capturing = true }
        }
        func parser(_ parser: XMLParser, foundCharacters string: String) {
            if capturing { buffer += string }
        }
        func parser(_ parser: XMLParser, didEndElement elementName: String,
                    namespaceURI: String?, qualifiedName qName: String?) {
            if elementName == "ZoneGroupState" { capturing = false }
        }
    }

    private final class GroupsDelegate: NSObject, XMLParserDelegate {
        var groups: [Group] = []
        private var coordinator: String?
        private var members: [Member] = []

        func parser(_ parser: XMLParser, didStartElement elementName: String,
                    namespaceURI: String?, qualifiedName qName: String?,
                    attributes attr: [String: String]) {
            switch elementName {
            case "ZoneGroup":
                coordinator = attr["Coordinator"]
                members = []
            case "ZoneGroupMember":
                // Skip invisible members: satellite/surround speakers and bridges
                // that aren't independently controllable rooms.
                guard attr["Invisible"] != "1",
                      let uuid = attr["UUID"],
                      let name = attr["ZoneName"],
                      let location = attr["Location"],
                      let ip = host(from: location) else { return }
                members.append(Member(uuid: uuid, name: name, ip: ip))
            default:
                break
            }
        }

        func parser(_ parser: XMLParser, didEndElement elementName: String,
                    namespaceURI: String?, qualifiedName qName: String?) {
            if elementName == "ZoneGroup", let coordinator, !members.isEmpty {
                groups.append(Group(coordinator: coordinator, members: members))
            }
            if elementName == "ZoneGroup" { coordinator = nil; members = [] }
        }

        private func host(from location: String) -> String? {
            guard let scheme = location.range(of: "http://") else { return nil }
            let rest = location[scheme.upperBound...]
            let host = rest.prefix { $0 != ":" && $0 != "/" }
            return host.isEmpty ? nil : String(host)
        }
    }
}
