import Foundation

/// Reads Sonos' escaped DIDL-Lite ContentDirectory results for Sonos Favorites.
enum FavoritesParser {
    struct Item {
        var id: String
        var title: String
        var uri: String
        var protocolInfo: String
    }

    static func parse(_ xml: String) -> [Item] {
        let delegate = Delegate()
        let parser = XMLParser(data: Data(xml.utf8))
        parser.delegate = delegate
        parser.parse()
        return delegate.items.filter { !$0.id.isEmpty && !$0.title.isEmpty && !$0.uri.isEmpty }
    }

    private final class Delegate: NSObject, XMLParserDelegate {
        var items: [Item] = []
        private var current: Item?
        private var currentField: String?
        private var text = ""

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                    qualifiedName qName: String?, attributes: [String: String]) {
            switch name {
            case "item":
                current = Item(id: attributes["id"] ?? "", title: "", uri: "", protocolInfo: "")
            case "dc:title", "res":
                currentField = name
                text = ""
                if name == "res" { current?.protocolInfo = attributes["protocolInfo"] ?? "" }
            default: break
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            if currentField != nil { text += string }
        }

        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName qName: String?) {
            if name == currentField {
                if name == "dc:title" { current?.title = text }
                if name == "res" { current?.uri = text }
                currentField = nil
            }
            if name == "item", let current {
                items.append(current)
                self.current = nil
            }
        }
    }
}
