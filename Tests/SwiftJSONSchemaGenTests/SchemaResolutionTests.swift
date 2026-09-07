import Foundation
import Testing

@testable import JSONSchemaGeneration

struct SchemaResolutionTests {
    @Test func detectsSupportedDialectsAndRejectsUnknownExplicitDialect() throws {
        #expect(try DraftVersion.detect(from: "http://json-schema.org/draft-07/schema#") == .draft7)
        #expect(
            try DraftVersion.detect(from: "https://json-schema.org/draft/2019-09/schema")
                == .draft2019_09)
        #expect(
            try DraftVersion.detect(from: "https://json-schema.org/draft/2020-12/schema")
                == .draft2020_12)
        #expect(try DraftVersion.detect(from: nil) == .draft2020_12)
        #expect(throws: GenerationError.self) {
            _ = try DraftVersion.detect(from: "https://example.com/custom-dialect")
        }
    }

    @Test func resolvesEscapedAndPercentEncodedJSONPointerTokens() throws {
        let json = try JSONValue(
            data: Data(
                #"{"$defs":{"a/b":{"type":"string"},"m~n":{"type":"integer"},"some key":{"type":"boolean"},"":{"type":"null"}}}"#
                    .utf8))

        #expect(try json.resolvingJSONPointer("/$defs/a~1b")["type"].string == "string")
        #expect(try json.resolvingJSONPointer("/$defs/m~0n")["type"].string == "integer")
        #expect(try json.resolvingJSONPointer("/$defs/some key")["type"].string == "boolean")
        #expect(try json.resolvingJSONPointer("/$defs/")["type"].string == "null")
        #expect(throws: GenerationError.self) {
            _ = try json.resolvingJSONPointer("/$defs/a~2b")
        }
    }

    @Test func indexesCanonicalIDsNestedResourcesAndAnchors() throws {
        let root = resource(
            url: "file:///schemas/root.json",
            json:
                #"{"$schema":"https://json-schema.org/draft/2020-12/schema","$id":"https://example.com/root.json","$defs":{"Inner":{"$id":"folder/inner.json","$anchor":"entry","type":"object","properties":{"leaf":{"$ref":"leaf.json"}}},"a/b":{"type":"string"},"some key":{"type":"boolean"}}}"#
        )
        let leaf = resource(
            url: "file:///schemas/leaf.json",
            json:
                #"{"$schema":"https://json-schema.org/draft/2020-12/schema","$id":"https://example.com/folder/leaf.json","title":"Leaf","type":"string"}"#
        )
        let documents = try SchemaLoader().loadDocuments(resources: [root, leaf])
        let resolver = try RefResolver(documents: documents)
        let rootBase = try #require(URL(string: "https://example.com/root.json"))

        let inner = try resolver.resolve(ref: "folder/inner.json#entry", from: rootBase)
        #expect(inner.json["type"].string == "object")
        #expect(inner.effectiveBaseURL.absoluteString == "https://example.com/folder/inner.json")
        #expect(
            try resolver.resolve(ref: "folder/inner.json#%65ntry", from: rootBase).json["type"]
                .string == "object")

        let innerByPointer = try resolver.resolve(ref: "#/$defs/Inner", from: rootBase)
        #expect(
            innerByPointer.effectiveBaseURL.absoluteString
                == "https://example.com/folder/inner.json")
        let resolvedLeaf = try resolver.resolve(
            ref: "leaf.json", from: innerByPointer.effectiveBaseURL)
        #expect(resolvedLeaf.json["title"].string == "Leaf")

        #expect(
            try resolver.resolve(ref: "#/$defs/a%7E1b", from: rootBase).json["type"].string
                == "string")
        #expect(
            try resolver.resolve(ref: "#/$defs/some%20key", from: rootBase).json["type"].string
                == "boolean")
    }

    @Test func supportsDraft7PlainNameIDAnchors() throws {
        let input = resource(
            url: "file:///schemas/legacy.json",
            json:
                ##"{"$schema":"http://json-schema.org/draft-07/schema#","$id":"https://example.com/legacy.json","definitions":{"Thing":{"$id":"#thing","type":"integer"}}}"##
        )
        let documents = try SchemaLoader().loadDocuments(resources: [input])
        let resolver = try RefResolver(documents: documents)
        let base = try #require(URL(string: "https://example.com/legacy.json"))

        #expect(try resolver.resolve(ref: "#thing", from: base).json["type"].string == "integer")
    }

    @Test func appliesRelativeRootAndNestedIDsExactlyOnce() throws {
        let input = resource(
            url: "https://example.com/base/catalog.json",
            json:
                #"{"$schema":"https://json-schema.org/draft/2020-12/schema","$id":"schemas/root.json","$defs":{"Inner":{"$id":"nested/inner.json","type":"string"}}}"#
        )
        let documents = try SchemaLoader().loadDocuments(resources: [input])
        let resolver = try RefResolver(documents: documents)
        let rootBase = try resolver.effectiveBaseURL(
            for: documents[input.url]!.json, from: input.url)
        let inner = try resolver.resolve(ref: "#/$defs/Inner", from: rootBase)

        #expect(rootBase.absoluteString == "https://example.com/base/schemas/root.json")
        #expect(
            inner.effectiveBaseURL.absoluteString
                == "https://example.com/base/schemas/nested/inner.json")
    }

    @Test func preservesNestedDefinitionNamespaceReferences() throws {
        let input = resource(
            url: "file:///schemas/namespaced.json",
            json:
                #"{"$schema":"http://json-schema.org/draft-07/schema#","definitions":{"v2":{"Foo":{"type":"string"}}}}"#
        )
        let resolver = try RefResolver(documents: SchemaLoader().loadDocuments(resources: [input]))

        #expect(
            try resolver.resolve(ref: "#/definitions/v2/Foo", from: input.url).json["type"].string
                == "string")
    }

    @Test func distinguishesSchemasFromLegacyDefinitionNamespaces() throws {
        let input = resource(
            url: "file:///schemas/schema-map.json",
            json:
                #"{"$schema":"https://json-schema.org/draft/2020-12/schema","$defs":{"Empty":{},"Annotated":{"description":"anything"},"Constrained":{"minLength":2},"v2":{"Foo":{"type":"string"}}},"type":"object","properties":{"anything":{}}}"#
        )
        let resolver = try RefResolver(documents: SchemaLoader().loadDocuments(resources: [input]))

        #expect(
            try resolver.resolve(ref: "#/$defs/Empty", from: input.url).json.type == .dictionary)
        #expect(
            try resolver.resolve(ref: "#/$defs/Annotated", from: input.url).json["description"]
                .string == "anything")
        #expect(
            try resolver.resolve(ref: "#/$defs/Constrained", from: input.url).json["minLength"].int
                == 2)
        #expect(
            try resolver.resolve(ref: "#/$defs/v2/Foo", from: input.url).json["type"].string
                == "string")
        #expect(
            try resolver.resolve(ref: "#/properties/anything", from: input.url).json.type
                == .dictionary)
    }

    @Test func carriesDialectThroughEmbeddedResourceAndPointerResolution() throws {
        let input = resource(
            url: "https://example.com/root.json",
            json:
                #"{"$schema":"https://json-schema.org/draft/2020-12/schema","$defs":{"Legacy":{"$id":"legacy.json","$schema":"http://json-schema.org/draft-07/schema#","definitions":{"Tuple":{"type":"array","items":[{"type":"string"}],"additionalItems":false}}}}}"#
        )
        let resolver = try RefResolver(documents: SchemaLoader().loadDocuments(resources: [input]))

        let resource = try resolver.resolve(ref: "legacy.json", from: input.url)
        let tuple = try resolver.resolve(ref: "legacy.json#/definitions/Tuple", from: input.url)
        #expect(resource.draft == .draft7)
        #expect(tuple.draft == .draft7)
    }

    @Test func strictGenerationAcceptsSupportedObjectAndTupleShapes() throws {
        let schemas = [
            #"{"$schema":"https://json-schema.org/draft/2020-12/schema","title":"Closed","type":"object","properties":{"id":{"type":"string"}},"additionalProperties":false}"#,
            #"{"$schema":"https://json-schema.org/draft/2020-12/schema","title":"Open","type":"object","properties":{"id":{"type":"string"}},"additionalProperties":{"type":"integer"}}"#,
            #"{"$schema":"https://json-schema.org/draft/2020-12/schema","title":"Pair","type":"array","prefixItems":[{"type":"string"},{"type":"integer"}],"items":false,"minItems":2,"maxItems":2}"#,
        ]

        for (index, schema) in schemas.enumerated() {
            let input = resource(url: "file:///schemas/strict-\(index).json", json: schema)
            let result = try JSONSchemaGenerator().generate(
                resources: [input],
                options: GenerationOptions(warningsAsErrors: true)
            )
            #expect(result.diagnostics.isEmpty)
        }
    }

    @Test func missingRemoteResourceExplainsOfflineInputRequirement() throws {
        let input = resource(
            url: "file:///schemas/root.json",
            json: #"{"$schema":"https://json-schema.org/draft/2020-12/schema","type":"object"}"#
        )
        let resolver = try RefResolver(documents: SchemaLoader().loadDocuments(resources: [input]))

        do {
            _ = try resolver.resolve(ref: "https://example.com/missing.json", from: input.url)
            Issue.record("Expected an offline resource error")
        } catch {
            let message = String(describing: error)
            #expect(message.contains("offline generation"))
            #expect(message.contains("pass it as an input resource"))
        }
    }

    @Test func reportsUnsupportedSemanticsWithStableLocationsAndCodes() throws {
        let input = resource(
            url: "file:///schemas/diagnostics.json",
            json:
                #"{"$schema":"https://json-schema.org/draft/2020-12/schema","$vocabulary":{"https://example.com/optional":false},"type":"object","properties":{"name":{"type":"string","minLength":2}}}"#
        )
        let document = try #require(SchemaLoader().loadDocuments(resources: [input])[input.url])

        #expect(
            document.diagnostics.contains(where: {
                $0.code == "unsupported_keyword" && $0.pointer == "/properties/name/minLength"
            }))
        #expect(
            document.diagnostics.contains(where: {
                $0.code == "optional_vocabulary" && $0.pointer?.hasPrefix("/$vocabulary/") == true
            }))
    }

    @Test func classifiesFormatDefinitionsAndRecursiveRefForDraft2020() throws {
        let input = resource(
            url: "file:///schemas/keyword-dialects.json",
            json:
                ##"{"$schema":"https://json-schema.org/draft/2020-12/schema","type":"object","definitions":{"Legacy":{"type":"string","format":"uuid"}},"$recursiveRef":"#"}"##
        )
        let document = try #require(SchemaLoader().loadDocuments(resources: [input])[input.url])
        let formatDiagnostic = document.diagnostics.first(where: { $0.keyword == "format" })
        let recursiveDiagnostic = document.diagnostics.first(where: {
            $0.keyword == "$recursiveRef"
        })
        let definitionsDiagnostic = document.diagnostics.first(where: {
            $0.keyword == "definitions"
        })

        #expect(formatDiagnostic?.code == "unsupported_keyword")
        #expect(recursiveDiagnostic?.code == "wrong_dialect_keyword")
        #expect(definitionsDiagnostic == nil)
    }

    @Test func rejectsRequiredUnknownVocabulary() {
        let input = resource(
            url: "file:///schemas/custom-vocabulary.json",
            json:
                #"{"$schema":"https://json-schema.org/draft/2020-12/schema","$vocabulary":{"https://example.com/required":true},"type":"string"}"#
        )

        #expect(throws: GenerationError.self) {
            _ = try SchemaLoader().loadDocuments(resources: [input])
        }
    }

    @Test func diagnosesUnknownAndWrongDialectKeywordsButAllowsExtensionAnnotations() throws {
        let input = resource(
            url: "file:///schemas/draft7-keywords.json",
            json:
                #"{"$schema":"http://json-schema.org/draft-07/schema#","type":"array","prefixItems":[{"type":"string"}],"mysteryConstraint":1,"x-owner":"models"}"#
        )
        let document = try #require(SchemaLoader().loadDocuments(resources: [input])[input.url])

        let hasWrongDialect = document.diagnostics.contains(where: {
            $0.code == "wrong_dialect_keyword" && $0.keyword == "prefixItems"
                && $0.dialect == "draft-07"
        })
        let hasUnknownKeyword = document.diagnostics.contains(where: {
            $0.code == "unknown_keyword" && $0.keyword == "mysteryConstraint"
        })
        #expect(hasWrongDialect)
        #expect(hasUnknownKeyword)
        #expect(!document.diagnostics.contains(where: { $0.keyword == "x-owner" }))
    }

    @Test func rejectsMalformedKnownKeywordShapesAtTheSourcePointer() {
        let input = resource(
            url: "file:///schemas/malformed.json",
            json:
                #"{"$schema":"https://json-schema.org/draft/2020-12/schema","type":"object","properties":{"name":"not-a-schema"}}"#
        )

        do {
            _ = try SchemaLoader().loadDocuments(resources: [input])
            Issue.record("Expected malformed properties error")
        } catch {
            #expect(String(describing: error).contains("#/properties/name"))
        }
    }

    @Test func warnsWhenStructuralKeywordsNarrowAnUntypedSchema() throws {
        let input = resource(
            url: "file:///schemas/inferred.json",
            json:
                #"{"$schema":"https://json-schema.org/draft/2020-12/schema","properties":{"name":{"type":"string"}}}"#
        )
        let document = try #require(SchemaLoader().loadDocuments(resources: [input])[input.url])
        let inferredType = document.diagnostics.first(where: { $0.code == "inferred_type" })

        #expect(inferredType?.keyword == "type")
        #expect(inferredType?.suggestion?.contains(#""type": "object""#) == true)
    }

    private func resource(url: String, json: String) -> SchemaResource {
        SchemaResource(data: Data(json.utf8), url: URL(string: url)!)
    }
}
