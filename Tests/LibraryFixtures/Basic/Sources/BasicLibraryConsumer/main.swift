import Foundation
import JSONSchemaGeneration

let schema = Data(
    """
    {
      "$schema": "https://json-schema.org/draft/2020-12/schema",
      "title": "Greeting",
      "type": "object",
      "properties": { "message": { "type": "string" } },
      "required": ["message"]
    }
    """.utf8
)
let generator = JSONSchemaGenerator()
let result = try generator.generate(resources: [
    SchemaResource(data: schema, url: URL(fileURLWithPath: "/schemas/greeting.json"))
])

guard result.source.contains("public struct Greeting: Codable") else {
    throw ConsumerError.missingGeneratedType
}

private enum ConsumerError: Error {
    case missingGeneratedType
}
