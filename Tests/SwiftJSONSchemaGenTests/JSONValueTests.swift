import Foundation
import Testing

@testable import JSONSchemaGeneration

struct JSONValueTests {
    @Test func preservesMissingNullBooleanAndNumberKinds() throws {
        let value = try JSONValue(
            data: Data(
                #"{"missingCandidate":null,"truth":true,"number":1,"false":false,"zero":0}"#.utf8))

        #expect(value["absent"].type == .missing)
        #expect(value["missingCandidate"].type == .null)
        #expect(value["truth"].bool == true)
        #expect(value["truth"].number == nil)
        #expect(value["number"].int64 == 1)
        #expect(value["truth"] != value["number"])
        #expect(value["false"] != value["zero"])
    }

    @Test func retainsLargeIntegersBeyondDoubleExactRange() throws {
        let value = try JSONValue(data: Data(#"9223372036854775809"#.utf8))

        #expect(value.type == .number)
        #expect(value.int64 == nil)
        #expect(value.canonicalJSONString == "9223372036854775809")
        let integer = try JSONValue(data: Data(#"1"#.utf8))
        let decimal = try JSONValue(data: Data(#"1.0"#.utf8))
        #expect(integer == decimal)
    }

    @Test func acceptsFiniteNumbersOutsideDecimalStorageRange() throws {
        let large = try JSONValue(data: Data(#"1e200"#.utf8))
        let small = try JSONValue(data: Data(#"1e-200"#.utf8))

        #expect(large.double == 1e200)
        #expect(small.double == 1e-200)
    }

    @Test func comparesObjectsStructurallyAndArraysInOrder() throws {
        let first = try JSONValue(data: Data(#"{"a":[1,2],"b":{"x":true}}"#.utf8))
        let second = try JSONValue(data: Data(#"{"b":{"x":true},"a":[1,2]}"#.utf8))
        let reordered = try JSONValue(data: Data(#"{"b":{"x":true},"a":[2,1]}"#.utf8))

        #expect(first == second)
        #expect(first.canonicalJSONString == second.canonicalJSONString)
        #expect(first != reordered)
    }

    @Test func resolvesEscapedPointerTokensAndArrayIndexes() throws {
        let value = try JSONValue(
            data: Data(#"{"a/b":[{"m~n":"ok"}]}"#.utf8))

        #expect(try value.resolvingJSONPointer("/a~1b/0/m~0n").string == "ok")
        #expect(throws: GenerationError.self) {
            _ = try value.resolvingJSONPointer("/a~1b/00")
        }
        #expect(throws: GenerationError.self) {
            _ = try value.resolvingJSONPointer("/a~1b/2")
        }
    }
}
