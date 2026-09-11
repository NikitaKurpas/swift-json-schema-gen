import Foundation
import Testing

@testable import JSONSchemaGeneration

struct ApplicatorSemanticsRegressionTests {
    @Test func rejectsRequiredPropertiesThatWouldBeDropped() throws {
        let schemas = [
            (
                #"{"type":"object","required":["token"],"additionalProperties":true}"#,
                "/required"
            ),
            (
                #"{"type":"object","properties":{"nested":{"type":"object","required":["token"]}}}"#,
                "/properties/nested/required"
            ),
            (
                #"{"allOf":[{"type":"object","required":["token"]},{"type":"object","properties":{"token":{"type":"string"}}}]}"#,
                "/allOf/0/required"
            ),
        ]

        for (index, fixture) in schemas.enumerated() {
            let message = try generationError(
                for: fixture.0,
                url: "file:///schemas/required-\(index).json"
            )
            #expect(message.contains(fixture.1))
            #expect(message.contains("token"))
        }
    }

    @Test func modernRefRejectsRepresentableSiblingsButDraft7IgnoresThem() throws {
        for draft in [
            "https://json-schema.org/draft/2019-09/schema",
            "https://json-schema.org/draft/2020-12/schema",
        ] {
            let schema =
                ##"{"$schema":"\##(draft)","$defs":{"Value":{"type":"integer"}},"$ref":"#/$defs/Value","type":"string"}"##
            let message = try generationError(for: schema)
            #expect(message.contains("'type' alongside '$ref'"))
            #expect(message.contains("#/type"))
        }

        let draft7 =
            ##"{"$schema":"http://json-schema.org/draft-07/schema#","definitions":{"Value":{"type":"integer"}},"$ref":"#/definitions/Value","type":"string"}"##
        _ = try generate(draft7)
    }

    @Test func diagnosedConstraintBesideModernRefIsNotSilent() throws {
        let schema =
            ##"{"$schema":"https://json-schema.org/draft/2020-12/schema","$defs":{"Value":{"type":"string"}},"$ref":"#/$defs/Value","minLength":2}"##

        let result = try generate(schema)
        #expect(
            result.diagnostics.contains {
                $0.code == "unsupported_keyword" && $0.pointer == "/minLength"
            })
        #expect(throws: GenerationError.self) {
            _ = try generate(schema, options: .init(warningsAsErrors: true))
        }
    }

    @Test func rejectsCompositionSiblingsThatWouldBeDiscarded() throws {
        let schemas = [
            (#"{"oneOf":[{"type":"string"}],"type":"integer"}"#, "'type' alongside 'oneOf'"),
            (
                #"{"anyOf":[{"type":"string"}],"items":{"type":"string"}}"#,
                "'items' alongside 'anyOf'"
            ),
            (
                #"{"allOf":[{"type":"object"}],"oneOf":[{"type":"object"}]}"#,
                "alongside"
            ),
            (
                #"{"allOf":[{"type":"object"}],"additionalProperties":false}"#,
                "'additionalProperties' alongside 'allOf'"
            ),
            (
                #"{"allOf":[{"type":"object"}],"type":["string"]}"#,
                "'type' alongside 'allOf'"
            ),
        ]

        for fixture in schemas {
            let message = try generationError(for: fixture.0)
            #expect(message.contains(fixture.1))
        }
    }

    @Test func unsupportedCompositionSiblingProducesAStableDiagnostic() throws {
        let schema = #"{"oneOf":[{"type":"string"}],"not":{"type":"integer"}}"#

        let result = try generate(schema)
        #expect(
            result.diagnostics.contains {
                $0.code == "unsupported_keyword" && $0.pointer == "/not"
            })
        #expect(throws: GenerationError.self) {
            _ = try generate(schema, options: .init(warningsAsErrors: true))
        }
    }

    private func generate(
        _ schema: String,
        options: GenerationOptions = .init()
    ) throws -> GenerationResult {
        try JSONSchemaGenerator().generate(
            resources: [
                SchemaResource(
                    data: Data(schema.utf8),
                    url: URL(fileURLWithPath: "/schemas/applicator.json")
                )
            ],
            options: options
        )
    }

    private func generationError(
        for schema: String, url: String = "file:///schemas/applicator.json"
    )
        throws -> String
    {
        do {
            _ = try JSONSchemaGenerator().generate(resources: [
                SchemaResource(data: Data(schema.utf8), url: URL(string: url)!)
            ])
            Issue.record("Expected generation to fail")
            return ""
        } catch {
            return String(describing: error)
        }
    }
}
