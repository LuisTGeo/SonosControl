import Foundation

enum SoapError: Error { case http(Int), badResponse }

/// Minimal UPnP/SOAP caller for Sonos players. Builds the envelope, sets the
/// `SOAPACTION` header, POSTs to `http://<ip>:1400<path>`, and hands back the
/// raw XML response body.
enum SoapClient {

    static func send(
        ip: String,
        service: (path: String, type: String),
        action: String,
        arguments: [(name: String, value: String)] = []
    ) async throws -> String {
        guard let url = URL(string: "http://\(ip):1400\(service.path)") else { throw SoapError.badResponse }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("text/xml; charset=\"utf-8\"", forHTTPHeaderField: "Content-Type")
        request.setValue("\"\(service.type)#\(action)\"", forHTTPHeaderField: "SOAPACTION")

        let args = arguments
            .map { "<\($0.name)>\(escape($0.value))</\($0.name)>" }
            .joined()
        let body = """
        <?xml version="1.0" encoding="utf-8"?>\
        <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" \
        s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">\
        <s:Body><u:\(action) xmlns:u="\(service.type)">\(args)</u:\(action)></s:Body>\
        </s:Envelope>
        """
        request.httpBody = Data(body.utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw SoapError.badResponse }
        guard (200..<300).contains(http.statusCode) else { throw SoapError.http(http.statusCode) }
        return String(decoding: data, as: UTF8.self)
    }

    /// Extracts the text between the first `<tag>` and its `</tag>`.
    static func value(of tag: String, in xml: String) -> String? {
        guard let open = xml.range(of: "<\(tag)>"),
              let close = xml.range(of: "</\(tag)>", range: open.upperBound..<xml.endIndex) else { return nil }
        return String(xml[open.upperBound..<close.lowerBound])
    }

    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    /// Reverses the XML entity escaping Sonos applies to embedded documents
    /// (e.g. the DIDL-Lite inside `<TrackMetaData>`). `&amp;` last so we don't
    /// double-decode.
    static func unescape(_ s: String) -> String {
        s.replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&amp;", with: "&")
    }
}
