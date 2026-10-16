import Testing
@testable import HackathonAI

@Suite struct AddressTests {
    @Test func addsSchemeAndVersionPath() {
        #expect(HackathonAI(baseURL: "192.168.1.10:10000", apiKey: "").baseURL.absoluteString == "http://192.168.1.10:10000/v1")
    }

    @Test func keepsExistingVersionPath() {
        #expect(HackathonAI(baseURL: "http://192.168.1.10:10000/v1/", apiKey: "").baseURL.absoluteString == "http://192.168.1.10:10000/v1")
    }
}

@Suite struct ThinkSplitterTests {
    @Test func removesThinkBlockSplitAcrossChunks() {
        var splitter = ThinkSplitter()
        var text = ""
        var reasoning = ""
        for chunk in ["<thi", "nk>plan", "ning</th", "ink>Hello", " there"] {
            let part = splitter.feed(chunk)
            text += part.text
            reasoning += part.reasoning
        }
        text += splitter.flush().text
        #expect(text == "Hello there")
        #expect(reasoning == "planning")
    }

    @Test func passesPlainTextThrough() {
        var splitter = ThinkSplitter()
        #expect(splitter.feed("No tags <b>here</b>").text + splitter.flush().text == "No tags <b>here</b>")
    }
}

@Suite struct JSONTests {
    @Test func extractsObjectFromCodeFence() {
        #expect(HackathonAI.extractJSON(from: "Sure!\n```json\n{\"a\": 1}\n```") == "{\"a\": 1}")
    }

    @Test func filterStopsAfterFirstObject() {
        var filter = JSONObjectFilter()
        let output = ["```json\n{\"a\": \"}", "\", \"b\": [1, {\"c\": 2}]}", "\n``` done"].map { filter.feed($0) }.joined()
        #expect(output == "{\"a\": \"}\", \"b\": [1, {\"c\": 2}]}")
    }
}
