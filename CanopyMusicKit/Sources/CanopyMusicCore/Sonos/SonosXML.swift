import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

/// A small XML tree, enough for what Sonos players answer (UPnP device descriptions, SOAP
/// replies, DIDL-Lite). Element names keep their prefix (`dc:title`); `name` matching is by
/// local name, so prefixes don't matter to callers.
public struct SonosXMLElement: Sendable, Equatable {
    public var name: String
    public var attributes: [String: String]
    public var children: [SonosXMLElement]
    /// The element's own text (entities decoded), trimmed of surrounding whitespace.
    public var text: String

    public var localName: String {
        name.split(separator: ":").last.map(String.init) ?? name
    }

    /// The first child with this local name.
    public func child(_ localName: String) -> SonosXMLElement? {
        children.first { $0.localName == localName }
    }

    public func children(_ localName: String) -> [SonosXMLElement] {
        children.filter { $0.localName == localName }
    }

    /// The text of the first child with this local name.
    public func value(_ localName: String) -> String? {
        child(localName)?.text
    }

    /// Every descendant (depth first) with this local name, this element included.
    public func descendants(_ localName: String) -> [SonosXMLElement] {
        var found: [SonosXMLElement] = []
        if self.localName == localName { found.append(self) }
        for child in children { found += child.descendants(localName) }
        return found
    }

    /// The first descendant with this local name.
    public func first(_ localName: String) -> SonosXMLElement? {
        if self.localName == localName { return self }
        for child in children {
            if let found = child.first(localName) { return found }
        }
        return nil
    }

    /// Parses a document. nil when it isn't well-formed XML.
    public static func parse(_ data: Data) -> SonosXMLElement? {
        let builder = TreeBuilder()
        let parser = XMLParser(data: data)
        parser.delegate = builder
        parser.shouldProcessNamespaces = false
        guard parser.parse() else { return nil }
        return builder.root
    }

    public static func parse(_ string: String) -> SonosXMLElement? {
        parse(Data(string.utf8))
    }
}

private final class TreeBuilder: NSObject, XMLParserDelegate {
    var root: SonosXMLElement?
    private var stack: [SonosXMLElement] = []

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        stack.append(SonosXMLElement(name: elementName, attributes: attributeDict, children: [], text: ""))
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard !stack.isEmpty else { return }
        stack[stack.count - 1].text += string
    }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        guard !stack.isEmpty else { return }
        stack[stack.count - 1].text += String(decoding: CDATABlock, as: UTF8.self)
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        guard var element = stack.popLast() else { return }
        element.text = element.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if stack.isEmpty {
            root = element
        } else {
            stack[stack.count - 1].children.append(element)
        }
    }
}

public enum SonosXMLEscape {
    /// Escapes text for an XML element or attribute value.
    public static func escape(_ text: String) -> String {
        var out = ""
        out.reserveCapacity(text.count)
        for character in text {
            switch character {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            case "'": out += "&apos;"
            default: out.append(character)
            }
        }
        return out
    }
}
