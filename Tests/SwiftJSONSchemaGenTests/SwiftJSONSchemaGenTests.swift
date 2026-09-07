import Foundation
import JSONSchema
import Testing

@testable import JSONSchemaGeneration
@testable import SwiftJSONSchemaGenCLI

struct SwiftJSONSchemaGenTests {
    @Test func failsWithoutSchemaPaths() async throws {
        let temp = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: temp) }
        let output = temp.appendingPathComponent("output.swift")
        let command = try JSONSchemaGeneratorCommand.parse([
            "--output",
            output.path(percentEncoded: false),
        ])
        await #expect(throws: GenerationError.self) {
            var mutable = command
            try await mutable.run()
        }
    }

    @Test func sendableFlagUpdatesGeneratedAnyValueConformance() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let schemaURL = dir.appendingPathComponent("a.json")
        let outputURL = dir.appendingPathComponent("generated.swift")
        try """
        {
          "$schema": "http://json-schema.org/draft-07/schema#",
          "title": "A",
          "type": "object",
          "properties": { "payload": {} }
        }
        """.write(to: schemaURL, atomically: true, encoding: .utf8)

        var command = try JSONSchemaGeneratorCommand.parse([
            "--sendable",
            "--output",
            outputURL.path(percentEncoded: false),
            schemaURL.path(percentEncoded: false),
        ])
        try await command.run()

        let generated = try String(contentsOf: outputURL, encoding: .utf8)
        #expect(generated.contains("public let payload: AnyValue"))
        #expect(generated.contains("public enum AnyValue: Codable, Sendable"))
        #expect(generated.contains("public struct A: Codable, Sendable"))
    }

    @Test func resolvesCrossFileRefs() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let mainURL = dir.appendingPathComponent("main.json")
        let childURL = dir.appendingPathComponent("child.json")
        let outputURL = dir.appendingPathComponent("types.swift")

        try """
        {
          "$schema": "http://json-schema.org/draft-07/schema#",
          "title": "Child",
          "type": "object",
          "properties": { "id": { "type": "string" } },
          "required": ["id"]
        }
        """.write(to: childURL, atomically: true, encoding: .utf8)

        try """
        {
          "$schema": "http://json-schema.org/draft-07/schema#",
          "title": "Main",
          "type": "object",
          "properties": { "child": { "$ref": "child.json#" } },
          "required": ["child"]
        }
        """.write(to: mainURL, atomically: true, encoding: .utf8)

        var command = try JSONSchemaGeneratorCommand.parse([
            "--output",
            outputURL.path(percentEncoded: false),
            mainURL.path(percentEncoded: false),
            childURL.path(percentEncoded: false),
        ])
        try await command.run()
        let generated = try String(contentsOf: outputURL, encoding: .utf8)
        #expect(generated.contains("public struct Main: Codable"))
        #expect(generated.contains("public struct Child: Codable"))
        #expect(generated.contains("public let child: Child"))
    }

    @Test func rejectsRemoteRefs() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let schemaURL = dir.appendingPathComponent("remote.json")
        let outputURL = dir.appendingPathComponent("types.swift")

        try """
        {
          "$schema": "https://json-schema.org/draft/2020-12/schema",
          "title": "RemoteRef",
          "type": "object",
          "properties": {
            "x": { "$ref": "https://example.com/s.json#/x" }
          }
        }
        """.write(to: schemaURL, atomically: true, encoding: .utf8)

        var command = try JSONSchemaGeneratorCommand.parse([
            "--output",
            outputURL.path(percentEncoded: false),
            schemaURL.path(percentEncoded: false),
        ])
        await #expect(throws: GenerationError.self) {
            try await command.run()
        }
    }

    @Test func generatesCodingKeysWhenNamesDiffer() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let schemaURL = dir.appendingPathComponent("keys.json")
        let outputURL = dir.appendingPathComponent("keys.swift")

        try """
        {
          "$schema": "http://json-schema.org/draft-07/schema#",
          "title": "KeyTest",
          "type": "object",
          "properties": {
            "thread-id": { "type": "string" }
          }
        }
        """.write(to: schemaURL, atomically: true, encoding: .utf8)

        var command = try JSONSchemaGeneratorCommand.parse([
            "--output",
            outputURL.path(percentEncoded: false),
            schemaURL.path(percentEncoded: false),
        ])
        try await command.run()
        let generated = try String(contentsOf: outputURL, encoding: .utf8)
        #expect(generated.contains("enum CodingKeys: String, CodingKey"))
        #expect(generated.contains("= \"thread-id\""))
    }

    @Test func codingKeysIncludeAllPropertiesWhenAnyMappingExists() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let schemaURL = dir.appendingPathComponent("mixed-keys.json")
        let outputURL = dir.appendingPathComponent("mixed-keys.swift")

        try """
        {
          "$schema": "http://json-schema.org/draft-07/schema#",
          "title": "MixedKeys",
          "type": "object",
          "properties": {
            "delta": { "type": "string" },
            "item_id": { "type": "string" },
            "type": { "type": "string" }
          },
          "required": ["delta", "item_id", "type"]
        }
        """.write(to: schemaURL, atomically: true, encoding: .utf8)

        var command = try JSONSchemaGeneratorCommand.parse([
            "--output",
            outputURL.path(percentEncoded: false),
            schemaURL.path(percentEncoded: false),
        ])
        try await command.run()
        let generated = try String(contentsOf: outputURL, encoding: .utf8)
        #expect(generated.contains("enum CodingKeys: String, CodingKey"))
        #expect(generated.contains("case itemId = \"item_id\""))
        #expect(generated.contains("case delta"))
        #expect(generated.contains("case type"))
    }

    @Test func omitsCodingKeysWhenNamesMatch() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let schemaURL = dir.appendingPathComponent("plain-keys.json")
        let outputURL = dir.appendingPathComponent("plain-keys.swift")

        try """
        {
          "$schema": "http://json-schema.org/draft-07/schema#",
          "title": "PlainKeys",
          "type": "object",
          "properties": {
            "threadId": { "type": "string" },
            "count": { "type": "integer" }
          }
        }
        """.write(to: schemaURL, atomically: true, encoding: .utf8)

        var command = try JSONSchemaGeneratorCommand.parse([
            "--output",
            outputURL.path(percentEncoded: false),
            schemaURL.path(percentEncoded: false),
        ])
        try await command.run()
        let generated = try String(contentsOf: outputURL, encoding: .utf8)
        #expect(generated.contains("public let threadId: String?"))
        #expect(!generated.contains("enum CodingKeys: String, CodingKey"))
    }

    @Test func mergesDuplicateTitlesIntoSingleType() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let firstURL = dir.appendingPathComponent("dup-a.json")
        let secondURL = dir.appendingPathComponent("dup-b.json")
        let outputURL = dir.appendingPathComponent("merged.swift")

        try """
        {
          "$schema": "http://json-schema.org/draft-07/schema#",
          "title": "DuplicateType",
          "type": "object",
          "properties": { "a": { "type": "string" } },
          "required": ["a"]
        }
        """.write(to: firstURL, atomically: true, encoding: .utf8)

        try """
        {
          "$schema": "https://json-schema.org/draft/2020-12/schema",
          "title": "DuplicateType",
          "type": "object",
          "properties": { "b": { "type": "integer" } },
          "required": ["b"]
        }
        """.write(to: secondURL, atomically: true, encoding: .utf8)

        var command = try JSONSchemaGeneratorCommand.parse([
            "--output",
            outputURL.path(percentEncoded: false),
            firstURL.path(percentEncoded: false),
            secondURL.path(percentEncoded: false),
        ])
        try await command.run()

        let generated = try String(contentsOf: outputURL, encoding: .utf8)
        #expect(generated.components(separatedBy: "public struct DuplicateType").count == 2)
        #expect(generated.contains("public let a: String"))
        #expect(generated.contains("public let b: Int"))
    }

    @Test func mergesAllOfAsStructProperties() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let schemaURL = dir.appendingPathComponent("allof.json")
        let outputURL = dir.appendingPathComponent("allof.swift")

        try """
        {
          "$schema": "https://json-schema.org/draft/2020-12/schema",
          "title": "AllOfType",
          "allOf": [
            {
              "type": "object",
              "properties": { "left": { "type": "string" } },
              "required": ["left"]
            },
            {
              "type": "object",
              "properties": { "right": { "type": "integer" } },
              "required": ["right"]
            }
          ]
        }
        """.write(to: schemaURL, atomically: true, encoding: .utf8)

        var command = try JSONSchemaGeneratorCommand.parse([
            "--output",
            outputURL.path(percentEncoded: false),
            schemaURL.path(percentEncoded: false),
        ])
        try await command.run()

        let generated = try String(contentsOf: outputURL, encoding: .utf8)
        #expect(generated.contains("public struct AllOfType: Codable"))
        #expect(generated.contains("public let left: String"))
        #expect(generated.contains("public let right: Int"))
    }

    @Test func generatesTypesForDefinitionsEvenWhenUnreferenced() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let schemaURL = dir.appendingPathComponent("definitions-only.json")
        let outputURL = dir.appendingPathComponent("definitions-only.swift")

        try """
        {
          "$schema": "https://json-schema.org/draft/2020-12/schema",
          "title": "CodexAppServerProtocol",
          "type": "object",
          "definitions": {
            "Request": {
              "title": "Request",
              "type": "object",
              "properties": {
                "id": { "type": "string" }
              },
              "required": ["id"]
            },
            "Response": {
              "title": "Response",
              "oneOf": [
                { "type": "string" },
                { "type": "integer" }
              ]
            }
          }
        }
        """.write(to: schemaURL, atomically: true, encoding: .utf8)

        var command = try JSONSchemaGeneratorCommand.parse([
            "--output",
            outputURL.path(percentEncoded: false),
            schemaURL.path(percentEncoded: false),
        ])
        try await command.run()

        let generated = try String(contentsOf: outputURL, encoding: .utf8)
        #expect(generated.contains("public struct Request: Codable"))
        #expect(generated.contains("public enum Response: Codable"))
        #expect(generated.contains("case string(String)"))
        #expect(generated.contains("case integer(Int)"))
        #expect(generated.contains("public typealias Request = CodexAppServerProtocol.Request"))
        #expect(generated.contains("public typealias Response = CodexAppServerProtocol.Response"))
    }

    @Test func generatesStringEnumDefinitionAndAllOfRefUsesIt() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let schemaURL = dir.appendingPathComponent("exec-source.json")
        let outputURL = dir.appendingPathComponent("exec-source.swift")

        try """
        {
          "$schema": "https://json-schema.org/draft/2020-12/schema",
          "title": "CodexAppServerProtocol",
          "type": "object",
          "definitions": {
            "ExecCommandSource": {
              "type": "string",
              "enum": [
                "agent",
                "user_shell",
                "unified_exec_startup",
                "unified_exec_interaction"
              ]
            },
            "ExecCommandBeginEventMsg": {
              "description": "Notification that the server is about to execute a command.",
              "type": "object",
              "properties": {
                "source": {
                  "description": "Where the command originated. Defaults to Agent for backward compatibility.",
                  "default": "agent",
                  "allOf": [
                    {
                      "$ref": "#/definitions/ExecCommandSource"
                    }
                  ]
                }
              },
              "title": "ExecCommandBeginEventMsg"
            }
          }
        }
        """.write(to: schemaURL, atomically: true, encoding: .utf8)

        var command = try JSONSchemaGeneratorCommand.parse([
            "--output",
            outputURL.path(percentEncoded: false),
            schemaURL.path(percentEncoded: false),
        ])
        try await command.run()

        let generated = try String(contentsOf: outputURL, encoding: .utf8)
        #expect(generated.contains("public enum ExecCommandSource: String, Codable"))
        #expect(generated.contains("case agent = \"agent\""))
        #expect(generated.contains("case userShell = \"user_shell\""))
        #expect(generated.contains("case unifiedExecStartup = \"unified_exec_startup\""))
        #expect(generated.contains("case unifiedExecInteraction = \"unified_exec_interaction\""))
        #expect(generated.contains("public let source: CodexAppServerProtocol.ExecCommandSource?"))
        #expect(!generated.contains("ExecCommandBeginEventMsgsource"))
    }

    @Test func flattensSingleValueScalarEnumVariantsIntoParentUnion() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let schemaURL = dir.appendingPathComponent("agent-status.json")
        let outputURL = dir.appendingPathComponent("agent-status.swift")

        try """
        {
          "$schema": "https://json-schema.org/draft/2020-12/schema",
          "title": "Root",
          "type": "object",
          "definitions": {
            "AgentStatus": {
              "description": "Agent lifecycle status, derived from emitted events.",
              "oneOf": [
                {
                  "description": "Agent is waiting for initialization.",
                  "type": "string",
                  "enum": ["pending_init"]
                },
                {
                  "description": "Agent is currently running.",
                  "type": "string",
                  "enum": ["running"]
                },
                {
                  "description": "Agent is done. Contains the final assistant message.",
                  "type": "object",
                  "required": ["completed"],
                  "properties": {
                    "completed": { "type": ["string", "null"] }
                  },
                  "title": "CompletedAgentStatus"
                },
                {
                  "description": "Agent encountered an error.",
                  "type": "object",
                  "required": ["errored"],
                  "properties": {
                    "errored": { "type": "string" }
                  },
                  "title": "ErroredAgentStatus"
                },
                {
                  "description": "Agent has been shutdown.",
                  "type": "string",
                  "enum": ["shutdown"]
                },
                {
                  "description": "Agent is not found.",
                  "type": "string",
                  "enum": ["not_found"]
                }
              ]
            }
          }
        }
        """.write(to: schemaURL, atomically: true, encoding: .utf8)

        var command = try JSONSchemaGeneratorCommand.parse([
            "--output",
            outputURL.path(percentEncoded: false),
            schemaURL.path(percentEncoded: false),
        ])
        try await command.run()

        let generated = try String(contentsOf: outputURL, encoding: .utf8)
        #expect(generated.contains("public enum AgentStatus: Codable"))
        #expect(generated.contains("case pendingInit"))
        #expect(generated.contains("case running"))
        #expect(generated.contains("case shutdown"))
        #expect(generated.contains("case notFound"))
        #expect(
            generated.contains("case completedAgentStatus(Root.AgentStatus.CompletedAgentStatus)"))
        #expect(generated.contains("case erroredAgentStatus(Root.AgentStatus.ErroredAgentStatus)"))
        #expect(!generated.contains("public enum PendingInit"))
        #expect(!generated.contains("public enum Running"))
        #expect(!generated.contains("public enum Shutdown"))
        #expect(!generated.contains("public enum NotFound"))
    }

    @Test func flattensMultiValueScalarEnumVariantsIntoParentUnion() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let schemaURL = dir.appendingPathComponent("status-union.json")
        let outputURL = dir.appendingPathComponent("status-union.swift")

        try """
        {
          "$schema": "https://json-schema.org/draft/2020-12/schema",
          "title": "Root",
          "type": "object",
          "definitions": {
            "Status": {
              "title": "Status",
              "oneOf": [
                {
                  "type": "string",
                  "enum": ["pending", "running", "done"]
                },
                {
                  "type": "object",
                  "required": ["errored"],
                  "properties": {
                    "errored": { "type": "string" }
                  },
                  "title": "ErroredStatus"
                }
              ]
            }
          }
        }
        """.write(to: schemaURL, atomically: true, encoding: .utf8)

        var command = try JSONSchemaGeneratorCommand.parse([
            "--output",
            outputURL.path(percentEncoded: false),
            schemaURL.path(percentEncoded: false),
        ])
        try await command.run()

        let generated = try String(contentsOf: outputURL, encoding: .utf8)
        #expect(generated.contains("public enum Status: Codable"))
        #expect(generated.contains("case pending"))
        #expect(generated.contains("case running"))
        #expect(generated.contains("case done"))
        #expect(generated.contains("case erroredStatus(Root.Status.ErroredStatus)"))
        #expect(generated.contains("try container.encode(\"pending\")"))
        #expect(generated.contains("try container.encode(\"running\")"))
        #expect(generated.contains("try container.encode(\"done\")"))
        #expect(!generated.contains("public enum Pending"))
        #expect(!generated.contains("public enum Running"))
        #expect(!generated.contains("public enum Done"))
    }

    @Test func usesDiscriminatorFastPathForTaggedObjectUnion() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let schemaURL = dir.appendingPathComponent("client-request.json")
        let outputURL = dir.appendingPathComponent("client-request.swift")

        try """
        {
          "$schema": "https://json-schema.org/draft/2020-12/schema",
          "title": "Root",
          "type": "object",
          "definitions": {
            "RequestId": { "type": "string" },
            "AParams": {
              "type": "object",
              "properties": { "x": { "type": "string" } },
              "required": ["x"]
            },
            "BParams": {
              "type": "object",
              "properties": { "y": { "type": "string" } },
              "required": ["y"]
            },
            "ClientRequest": {
              "title": "ClientRequest",
              "oneOf": [
                {
                  "type": "object",
                  "required": ["id", "method", "params"],
                  "properties": {
                    "id": { "$ref": "#/definitions/RequestId" },
                    "method": { "type": "string", "enum": ["initialize"] },
                    "params": { "$ref": "#/definitions/AParams" }
                  },
                  "title": "InitializeRequest"
                },
                {
                  "type": "object",
                  "required": ["id", "method", "params"],
                  "properties": {
                    "id": { "$ref": "#/definitions/RequestId" },
                    "method": { "type": "string", "enum": ["thread/start"] },
                    "params": { "$ref": "#/definitions/BParams" }
                  },
                  "title": "ThreadStartRequest"
                }
              ]
            }
          }
        }
        """.write(to: schemaURL, atomically: true, encoding: .utf8)

        var command = try JSONSchemaGeneratorCommand.parse([
            "--output",
            outputURL.path(percentEncoded: false),
            schemaURL.path(percentEncoded: false),
        ])
        try await command.run()

        let generated = try String(contentsOf: outputURL, encoding: .utf8)
        #expect(generated.contains("public enum ClientRequest: Codable"))
        #expect(generated.contains("case initialize(Root.ClientRequest.InitializeRequest)"))
        #expect(generated.contains("case threadStart(Root.ClientRequest.ThreadStartRequest)"))
        #expect(!generated.contains("case initializeRequest("))
        #expect(!generated.contains("case threadStartRequest("))
        #expect(generated.contains("public enum Method: String, Codable"))
        #expect(generated.contains("private enum DiscriminatorCodingKeys: String, CodingKey"))
        #expect(generated.contains("case discriminator = \"method\""))
        #expect(
            generated.contains(
                "let discriminator = try? keyed.decode(Method.self, forKey: .discriminator)"))
        #expect(generated.contains("switch discriminator"))
        #expect(generated.contains("case .initialize:"))
        #expect(generated.contains("case .threadStart:"))
    }

    @Test func doesNotEmitDiscriminatorFastPathForSingleCaseUnion() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let schemaURL = dir.appendingPathComponent("single-notification.json")
        let outputURL = dir.appendingPathComponent("single-notification.swift")

        try """
        {
          "$schema": "https://json-schema.org/draft/2020-12/schema",
          "title": "Root",
          "type": "object",
          "definitions": {
            "InitializedNotification": {
              "type": "object",
              "required": ["method"],
              "properties": {
                "method": { "type": "string", "enum": ["initialized"] }
              },
              "title": "InitializedNotification"
            },
            "ClientNotification": {
              "title": "ClientNotification",
              "oneOf": [
                { "$ref": "#/definitions/InitializedNotification" }
              ]
            }
          }
        }
        """.write(to: schemaURL, atomically: true, encoding: .utf8)

        var command = try JSONSchemaGeneratorCommand.parse([
            "--output",
            outputURL.path(percentEncoded: false),
            schemaURL.path(percentEncoded: false),
        ])
        try await command.run()

        let generated = try String(contentsOf: outputURL, encoding: .utf8)
        #expect(generated.contains("public enum ClientNotification: Codable"))
        #expect(generated.contains("case initialized("))
        #expect(!generated.contains("enum ClientNotificationMethod: String, Codable"))
        #expect(!generated.contains("enum DiscriminatorCodingKeys: String, CodingKey"))
        #expect(!generated.contains("switch discriminator"))
    }

    @Test func discriminatorEnumNameAvoidsTypeConflict() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let schemaURL = dir.appendingPathComponent("type-discriminator-union.json")
        let outputURL = dir.appendingPathComponent("type-discriminator-union.swift")

        try """
        {
          "$schema": "https://json-schema.org/draft/2020-12/schema",
          "title": "Root",
          "type": "object",
          "definitions": {
            "Event": {
              "title": "Event",
              "oneOf": [
                {
                  "type": "object",
                  "required": ["type"],
                  "properties": {
                    "type": { "type": "string", "enum": ["started"] }
                  },
                  "title": "StartedEvent"
                },
                {
                  "type": "object",
                  "required": ["type"],
                  "properties": {
                    "type": { "type": "string", "enum": ["stopped"] }
                  },
                  "title": "StoppedEvent"
                }
              ]
            }
          }
        }
        """.write(to: schemaURL, atomically: true, encoding: .utf8)

        var command = try JSONSchemaGeneratorCommand.parse([
            "--output",
            outputURL.path(percentEncoded: false),
            schemaURL.path(percentEncoded: false),
        ])
        try await command.run()

        let generated = try String(contentsOf: outputURL, encoding: .utf8)
        #expect(generated.contains("public enum `Type`: String, Codable"))
        #expect(!generated.contains("public enum Type: String, Codable"))
        #expect(
            generated.contains(
                "let discriminator = try? keyed.decode(`Type`.self, forKey: .discriminator)"))
    }

    @Test func generatesSimpleDefinitionTypeAliasesForPrimitiveSchemas() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let schemaURL = dir.appendingPathComponent("simple-aliases.json")
        let outputURL = dir.appendingPathComponent("simple-aliases.swift")

        try """
        {
          "$schema": "https://json-schema.org/draft/2020-12/schema",
          "title": "CodexAppServerProtocol",
          "type": "object",
          "definitions": {
            "GitSha": {
              "type": "string"
            },
            "ProcessId": {
              "type": "integer",
              "format": "int64"
            },
            "BuildRef": {
              "type": "object",
              "properties": {
                "sha": { "$ref": "#/definitions/GitSha" },
                "pid": { "$ref": "#/definitions/ProcessId" }
              },
              "required": ["sha", "pid"]
            }
          }
        }
        """.write(to: schemaURL, atomically: true, encoding: .utf8)

        var command = try JSONSchemaGeneratorCommand.parse([
            "--output",
            outputURL.path(percentEncoded: false),
            schemaURL.path(percentEncoded: false),
        ])
        try await command.run()

        let generated = try String(contentsOf: outputURL, encoding: .utf8)
        #expect(generated.contains("public typealias GitSha = String"))
        #expect(generated.contains("public typealias ProcessId = Int"))
        #expect(generated.contains("public typealias GitSha = CodexAppServerProtocol.GitSha"))
        #expect(generated.contains("public typealias ProcessId = CodexAppServerProtocol.ProcessId"))
        #expect(generated.contains("public let sha: CodexAppServerProtocol.GitSha"))
        #expect(generated.contains("public let pid: CodexAppServerProtocol.ProcessId"))
    }

    @Test func namespacesTypesForNestedDefinitionRefs() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let schemaURL = dir.appendingPathComponent("nested-namespace.json")
        let outputURL = dir.appendingPathComponent("nested-namespace.swift")

        try """
        {
          "$schema": "https://json-schema.org/draft/2020-12/schema",
          "title": "RootEvent",
          "type": "object",
          "properties": {
            "legacy": { "$ref": "#/definitions/RateLimitSnapshot" },
            "modern": { "$ref": "#/definitions/v2/RateLimitSnapshot" }
          },
          "required": ["legacy", "modern"],
          "definitions": {
            "RateLimitSnapshot": {
              "title": "RateLimitSnapshot",
              "type": "object",
              "properties": {
                "limit_id": { "type": "string" }
              },
              "required": ["limit_id"]
            },
            "v2": {
              "RateLimitSnapshot": {
                "title": "RateLimitSnapshot",
                "type": "object",
                "properties": {
                  "limitId": { "type": "string" }
                },
                "required": ["limitId"]
              }
            }
          }
        }
        """.write(to: schemaURL, atomically: true, encoding: .utf8)

        var command = try JSONSchemaGeneratorCommand.parse([
            "--output",
            outputURL.path(percentEncoded: false),
            schemaURL.path(percentEncoded: false),
        ])
        try await command.run()

        let generated = try String(contentsOf: outputURL, encoding: .utf8)
        #expect(generated.contains("public struct RootEvent: Codable"))
        #expect(generated.contains("public let legacy: RootEvent.RateLimitSnapshot"))
        #expect(generated.contains("public let modern: RootEvent.v2.RateLimitSnapshot"))
        #expect(generated.contains("public struct RateLimitSnapshot: Codable"))
        #expect(generated.contains("public enum v2"))
        #expect(!generated.contains("public struct V2RateLimitSnapshot: Codable"))
    }

    @Test func materializesNestedDefinitionNamespacesWhenUnreferenced() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let schemaURL = dir.appendingPathComponent("nested-unreferenced-definitions.json")
        let outputURL = dir.appendingPathComponent("nested-unreferenced-definitions.swift")

        try """
        {
          "$schema": "https://json-schema.org/draft/2020-12/schema",
          "title": "ContainerRoot",
          "type": "object",
          "definitions": {
            "v2": {
              "AuditEntry": {
                "type": "object",
                "properties": {
                  "id": { "type": "string" }
                },
                "required": ["id"]
              }
            }
          }
        }
        """.write(to: schemaURL, atomically: true, encoding: .utf8)

        var command = try JSONSchemaGeneratorCommand.parse([
            "--output",
            outputURL.path(percentEncoded: false),
            schemaURL.path(percentEncoded: false),
        ])
        try await command.run()

        let generated = try String(contentsOf: outputURL, encoding: .utf8)
        #expect(generated.contains("public enum ContainerRoot"))
        #expect(generated.contains("public enum v2"))
        #expect(generated.contains("public struct AuditEntry: Codable"))
        #expect(!generated.contains("public typealias v2 ="))
    }

    @Test func localOneOfTypesAreNamespacedUnderContainingType() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let schemaURL = dir.appendingPathComponent("local-union-namespace.json")
        let outputURL = dir.appendingPathComponent("local-union-namespace.swift")

        try """
        {
          "$schema": "https://json-schema.org/draft/2020-12/schema",
          "title": "RootEnvelope",
          "type": "object",
          "properties": {
            "notification": { "$ref": "#/definitions/ServerNotifications" },
            "globalNotification": { "$ref": "#/definitions/AuthStatusChangeNotification" }
          },
          "required": ["notification", "globalNotification"],
          "definitions": {
            "AuthStatusChangeNotification": {
              "title": "AuthStatusChangeNotification",
              "type": "object",
              "properties": {
                "globalValue": { "type": "string" }
              },
              "required": ["globalValue"]
            },
            "ServerNotifications": {
              "title": "ServerNotifications",
              "oneOf": [
                {
                  "title": "AuthStatusChangeNotification",
                  "type": "object",
                  "properties": {
                    "localValue": { "type": "integer" }
                  },
                  "required": ["localValue"]
                }
              ]
            }
          }
        }
        """.write(to: schemaURL, atomically: true, encoding: .utf8)

        var command = try JSONSchemaGeneratorCommand.parse([
            "--output",
            outputURL.path(percentEncoded: false),
            schemaURL.path(percentEncoded: false),
        ])
        try await command.run()

        let generated = try String(contentsOf: outputURL, encoding: .utf8)
        #expect(generated.contains("public enum ServerNotifications: Codable"))
        #expect(
            generated.contains(
                "case authStatusChangeNotification(RootEnvelope.ServerNotifications.AuthStatusChangeNotification)"
            ))
        #expect(generated.contains("public struct RootEnvelope: Codable"))
        #expect(
            generated.contains(
                "public let globalNotification: RootEnvelope.AuthStatusChangeNotification"))
        #expect(generated.contains("public let notification: RootEnvelope.ServerNotifications"))
        #expect(generated.contains("public let globalValue: String"))
        #expect(generated.contains("public let localValue: Int"))
        #expect(
            generated.components(separatedBy: "public struct AuthStatusChangeNotification: Codable")
                .count == 3)
    }

    @Test func localNestedEnumTypesAreNamespacedPerContainingLocalType() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let schemaURL = dir.appendingPathComponent("readonly-access-namespaced-enums.json")
        let outputURL = dir.appendingPathComponent("readonly-access-namespaced-enums.swift")

        try """
        {
          "$schema": "https://json-schema.org/draft/2020-12/schema",
          "title": "CodexAppServerProtocol",
          "type": "object",
          "properties": {
            "legacy": { "$ref": "#/definitions/ReadOnlyAccess" },
            "modern": { "$ref": "#/definitions/v2/ReadOnlyAccess" }
          },
          "required": ["legacy", "modern"],
          "definitions": {
            "ReadOnlyAccess": {
              "oneOf": [
                {
                  "type": "object",
                  "required": ["type"],
                  "properties": {
                    "type": {
                      "type": "string",
                      "enum": ["full-access"],
                      "title": "FullAccessReadOnlyAccessType"
                    }
                  },
                  "title": "FullAccessReadOnlyAccess"
                }
              ]
            },
            "v2": {
              "ReadOnlyAccess": {
                "oneOf": [
                  {
                    "type": "object",
                    "required": ["type"],
                    "properties": {
                      "type": {
                        "type": "string",
                        "enum": ["fullAccess"],
                        "title": "FullAccessReadOnlyAccessType"
                      }
                    },
                    "title": "FullAccessReadOnlyAccess"
                  }
                ]
              }
            }
          }
        }
        """.write(to: schemaURL, atomically: true, encoding: .utf8)

        var command = try JSONSchemaGeneratorCommand.parse([
            "--output",
            outputURL.path(percentEncoded: false),
            schemaURL.path(percentEncoded: false),
        ])
        try await command.run()

        let generated = try String(contentsOf: outputURL, encoding: .utf8)
        #expect(
            generated.contains(
                "public let type: CodexAppServerProtocol.ReadOnlyAccess.FullAccessReadOnlyAccess.FullAccessReadOnlyAccessType"
            )
        )
        #expect(
            generated.contains(
                "public let type: CodexAppServerProtocol.v2.ReadOnlyAccess.FullAccessReadOnlyAccess.FullAccessReadOnlyAccessType"
            )
        )
        #expect(
            generated.components(
                separatedBy: "public enum FullAccessReadOnlyAccessType: String, Codable"
            ).count == 3)
    }

    @Test func generatedTypeEncodedJSONValidatesAgainstSchema() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let schemaURL = dir.appendingPathComponent("person.json")
        let outputURL = dir.appendingPathComponent("person.swift")
        let runnerURL = dir.appendingPathComponent("runner.swift")
        let binaryURL = dir.appendingPathComponent("runner-bin")

        let schema = """
            {
              "$schema": "https://json-schema.org/draft/2020-12/schema",
              "title": "Person",
              "type": "object",
              "properties": {
                "name": {
                  "type": "string",
                  "minLength": 1
                },
                "age": {
                  "type": "integer",
                  "minimum": 0
                }
              },
              "required": ["name", "age"]
            }
            """
        try schema.write(to: schemaURL, atomically: true, encoding: .utf8)

        var command = try JSONSchemaGeneratorCommand.parse([
            "--output",
            outputURL.path(percentEncoded: false),
            schemaURL.path(percentEncoded: false),
        ])
        try await command.run()

        let runner = """
            import Foundation

            @main
            struct Runner {
                static func main() throws {
                    let input = #"{"name":"Alice","age":30}"#.data(using: .utf8)!
                    let value = try JSONDecoder().decode(Person.self, from: input)
                    let data = try JSONEncoder().encode(value)
                    FileHandle.standardOutput.write(data)
                }
            }
            """
        try runner.write(to: runnerURL, atomically: true, encoding: .utf8)

        _ = try runProcess(
            executable: "/usr/bin/env",
            arguments: [
                "swiftc",
                "-swift-version", "6",
                "-strict-memory-safety",
                outputURL.path(percentEncoded: false),
                runnerURL.path(percentEncoded: false),
                "-o", binaryURL.path(percentEncoded: false),
            ]
        )
        let jsonInstance = try runProcess(
            executable: binaryURL.path(percentEncoded: false), arguments: []
        ).stdout

        let parsed = try Schema(instance: schema)
        let result = try parsed.validate(instance: jsonInstance)
        #expect(result.isValid)
    }

    @Test func generatedCodingKeysProduceSchemaValidJSON() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let schemaURL = dir.appendingPathComponent("key-payload.json")
        let outputURL = dir.appendingPathComponent("key-payload.swift")
        let runnerURL = dir.appendingPathComponent("runner.swift")
        let binaryURL = dir.appendingPathComponent("runner-bin")

        let schema = """
            {
              "$schema": "https://json-schema.org/draft/2020-12/schema",
              "title": "KeyPayload",
              "type": "object",
              "properties": {
                "thread-id": {
                  "type": "string",
                  "minLength": 1
                }
              },
              "required": ["thread-id"]
            }
            """
        try schema.write(to: schemaURL, atomically: true, encoding: .utf8)

        var command = try JSONSchemaGeneratorCommand.parse([
            "--output",
            outputURL.path(percentEncoded: false),
            schemaURL.path(percentEncoded: false),
        ])
        try await command.run()

        let runner = """
            import Foundation

            @main
            struct Runner {
                static func main() throws {
                    let input = #"{"thread-id":"thr_123"}"#.data(using: .utf8)!
                    let value = try JSONDecoder().decode(KeyPayload.self, from: input)
                    let data = try JSONEncoder().encode(value)
                    FileHandle.standardOutput.write(data)
                }
            }
            """
        try runner.write(to: runnerURL, atomically: true, encoding: .utf8)

        _ = try runProcess(
            executable: "/usr/bin/env",
            arguments: [
                "swiftc",
                "-swift-version", "6",
                "-strict-memory-safety",
                outputURL.path(percentEncoded: false),
                runnerURL.path(percentEncoded: false),
                "-o", binaryURL.path(percentEncoded: false),
            ]
        )
        let jsonInstance = try runProcess(
            executable: binaryURL.path(percentEncoded: false), arguments: []
        ).stdout

        let parsed = try Schema(instance: schema)
        let result = try parsed.validate(instance: jsonInstance)
        #expect(result.isValid)
    }

    @Test func usesRefNamesAndDescriptionsForUnionCases() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let outputURL = dir.appendingPathComponent("jsonrpc-message.swift")
        var command = try JSONSchemaGeneratorCommand.parse([
            "--output",
            outputURL.path(percentEncoded: false),
            try TestSupport.fixture(named: "JSONRPCMessage.json").path,
        ])
        try await command.run()

        let generated = try String(contentsOf: outputURL, encoding: .utf8)
        #expect(generated.contains("/// Refers to any valid JSON-RPC object"))
        #expect(generated.contains("case jsonrpcRequest(JSONRPCMessage.JSONRPCRequest)"))
        #expect(generated.contains("case jsonrpcNotification(JSONRPCMessage.JSONRPCNotification)"))
        #expect(generated.contains("case jsonrpcResponse(JSONRPCMessage.JSONRPCResponse)"))
        #expect(generated.contains("case jsonrpcError(JSONRPCMessage.JSONRPCError)"))
        #expect(generated.contains("/// A request that expects a response."))
        #expect(generated.contains("/// A notification which does not expect a response."))
    }

    @Test func emitsSingleSharedAnyValueAtFileEnd() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let outputURL = dir.appendingPathComponent("jsonrpc-message.swift")
        var command = try JSONSchemaGeneratorCommand.parse([
            "--output",
            outputURL.path(percentEncoded: false),
            try TestSupport.fixture(named: "JSONRPCMessage.json").path,
        ])
        try await command.run()

        let generated = try String(contentsOf: outputURL, encoding: .utf8)
        #expect(generated.components(separatedBy: "public enum AnyValue: Codable").count == 2)
        #expect(generated.contains("case integer(Int64)"))
        #expect(generated.contains("public let params: AnyValue?"))
        #expect(generated.contains("public let result: AnyValue"))
        #expect(generated.contains("public subscript(key: String) -> AnyValue"))
        #expect(!generated.contains("public enum UntypedValue: Codable"))
        #expect(!generated.contains("any Codable"))

        let lastMarker = generated.range(of: "public enum AnyValue: Codable", options: .backwards)
        let lastJSONRPC = generated.range(
            of: "public enum JSONRPCMessage: Codable", options: .backwards)
        #expect(lastMarker != nil)
        #expect(lastJSONRPC != nil)
        if let lastMarker, let lastJSONRPC {
            #expect(lastMarker.lowerBound > lastJSONRPC.lowerBound)
        }
    }

    @Test func explicitNullTypeUsesNullValue() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let schemaURL = dir.appendingPathComponent("null-only.json")
        let outputURL = dir.appendingPathComponent("generated.swift")
        let runnerURL = dir.appendingPathComponent("runner.swift")
        let binaryURL = dir.appendingPathComponent("runner")

        let schema = """
            {
              "$schema": "https://json-schema.org/draft/2020-12/schema",
              "title": "NullHolder",
              "type": "object",
              "properties": {
                "params": { "type": "null" }
              },
              "required": ["params"]
            }
            """
        try schema.write(to: schemaURL, atomically: true, encoding: .utf8)

        var command = try JSONSchemaGeneratorCommand.parse([
            "--output",
            outputURL.path(percentEncoded: false),
            schemaURL.path(percentEncoded: false),
        ])
        try await command.run()

        let generated = try String(contentsOf: outputURL, encoding: .utf8)
        #expect(generated.contains("public let params: NullValue"))
        #expect(generated.contains("public enum NullValue: Codable"))
        #expect(!generated.contains("public let params: AnyValue"))

        let runner = """
            import Foundation

            @main
            struct Runner {
                static func main() throws {
                    let input = #"{"params":null}"#.data(using: .utf8)!
                    let decoded = try JSONDecoder().decode(NullHolder.self, from: input)
                    let data = try JSONEncoder().encode(decoded)
                    FileHandle.standardOutput.write(data)
                }
            }
            """
        try runner.write(to: runnerURL, atomically: true, encoding: .utf8)

        _ = try runProcess(
            executable: "/usr/bin/env",
            arguments: [
                "swiftc",
                "-swift-version", "6",
                "-strict-memory-safety",
                outputURL.path(percentEncoded: false),
                runnerURL.path(percentEncoded: false),
                "-o", binaryURL.path(percentEncoded: false),
            ]
        )
        let jsonInstance = try runProcess(
            executable: binaryURL.path(percentEncoded: false), arguments: []
        ).stdout

        let parsed = try Schema(instance: schema)
        let result = try parsed.validate(instance: jsonInstance)
        #expect(result.isValid)
    }

    @Test func helperNamesFallbackWhenAnyValueOrNullValueTypeExists() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let schemaURL = dir.appendingPathComponent("collision.json")
        let outputURL = dir.appendingPathComponent("generated.swift")
        let runnerURL = dir.appendingPathComponent("runner.swift")
        let binaryURL = dir.appendingPathComponent("runner")

        try """
        {
          "$schema": "https://json-schema.org/draft/2020-12/schema",
          "title": "AnyValue",
          "type": "object",
          "properties": {
            "dynamic": {}
          },
          "required": ["dynamic"]
        }
        """.write(to: schemaURL, atomically: true, encoding: .utf8)

        var command = try JSONSchemaGeneratorCommand.parse([
            "--output",
            outputURL.path(percentEncoded: false),
            schemaURL.path(percentEncoded: false),
        ])
        try await command.run()

        let generated = try String(contentsOf: outputURL, encoding: .utf8)
        #expect(generated.contains("public struct AnyValue: Codable"))
        #expect(generated.contains("public let dynamic: JSONValue"))
        #expect(generated.contains("public enum JSONValue: Codable"))
        #expect(!generated.contains("public enum AnyValue: Codable"))

        try """
        import Foundation

        @main
        struct Runner {
            static func main() throws {
                let data = #"{"dynamic":{"ready":true}}"#.data(using: .utf8)!
                let value = try JSONDecoder().decode(AnyValue.self, from: data)
                let ready = value.dynamic["ready"].boolValue ?? false
                FileHandle.standardOutput.write(Data(String(ready).utf8))
            }
        }
        """.write(to: runnerURL, atomically: true, encoding: .utf8)
        try TestSupport.compileSwift(sources: [outputURL, runnerURL], output: binaryURL)
        let execution = try TestSupport.run(executable: binaryURL, arguments: [])
        #expect(execution.stdout == "true")
    }

    @Test func primitiveUnionCaseNamesAreCleanAndDeduped() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let outputURL = dir.appendingPathComponent("requestid.swift")
        var command = try JSONSchemaGeneratorCommand.parse([
            "--output",
            outputURL.path(percentEncoded: false),
            try TestSupport.fixture(named: "RequestId.json").path,
        ])
        try await command.run()

        let generated = try String(contentsOf: outputURL, encoding: .utf8)
        #expect(generated.contains("public enum RequestId: Codable"))
        #expect(generated.contains("case string(String)"))
        #expect(generated.contains("case integer(Int)"))
        #expect(!generated.contains("case stringcase1("))
        #expect(!generated.contains("case integercase2("))
    }

    @Test func jsonValueAccessorsWorkForUntypedField() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let schemaURL = dir.appendingPathComponent("box.json")
        let outputURL = dir.appendingPathComponent("box.swift")
        let runnerURL = dir.appendingPathComponent("runner.swift")
        let binaryURL = dir.appendingPathComponent("runner-bin")

        try """
        {
          "$schema": "https://json-schema.org/draft/2020-12/schema",
          "title": "Box",
          "type": "object",
          "properties": {
            "payload": {}
          },
          "required": ["payload"]
        }
        """.write(to: schemaURL, atomically: true, encoding: .utf8)

        var command = try JSONSchemaGeneratorCommand.parse([
            "--output",
            outputURL.path(percentEncoded: false),
            schemaURL.path(percentEncoded: false),
        ])
        try await command.run()

        let runner = """
            import Foundation

            @main
            struct Runner {
                static func main() throws {
                    let input = #"{"payload":{"value":7}}"#.data(using: .utf8)!
                    let box = try JSONDecoder().decode(Box.self, from: input)
                    let value = box.payload["value"].intValue ?? -1
                    FileHandle.standardOutput.write(Data(String(value).utf8))
                }
            }
            """
        try runner.write(to: runnerURL, atomically: true, encoding: .utf8)

        _ = try runProcess(
            executable: "/usr/bin/env",
            arguments: [
                "swiftc",
                "-swift-version", "6",
                "-strict-memory-safety",
                outputURL.path(percentEncoded: false),
                runnerURL.path(percentEncoded: false),
                "-o", binaryURL.path(percentEncoded: false),
            ]
        )
        let stdout = try runProcess(
            executable: binaryURL.path(percentEncoded: false), arguments: []
        ).stdout
        #expect(stdout == "7")
    }

    private func makeTempDir() throws -> URL {
        try TestSupport.makeTemporaryDirectory()
    }

    private func runProcess(executable: String, arguments: [String]) throws -> (
        stdout: String, stderr: String
    ) {
        try TestSupport.run(executable: URL(fileURLWithPath: executable), arguments: arguments)
    }
}
