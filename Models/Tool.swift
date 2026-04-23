import Foundation

/// A tool the model can call. Pass one or more to `BigBroClient.send()`;
/// the client runs the agentic loop transparently and yields only text deltas.
public struct BigBroTool: Sendable {

    public struct Definition: Encodable, Sendable {
        public let type: String = "function"
        public let function: Function

        public struct Function: Encodable, Sendable {
            public let name: String
            public let description: String
            public let parameters: Parameters

            public init(name: String, description: String, parameters: Parameters) {
                self.name = name
                self.description = description
                self.parameters = parameters
            }
        }

        public struct Parameters: Encodable, Sendable {
            public let type: String = "object"
            public let properties: [String: Property]
            public let required: [String]

            public struct Property: Encodable, Sendable {
                public let type: String
                public let description: String

                public init(type: String, description: String) {
                    self.type = type
                    self.description = description
                }
            }

            public init(properties: [String: Property] = [:], required: [String] = []) {
                self.properties = properties
                self.required = required
            }
        }

        public init(name: String, description: String, parameters: Parameters = Parameters()) {
            self.function = Function(name: name, description: description, parameters: parameters)
        }
    }

    public let definition: Definition
    public let handler: @Sendable ([String: Any]) async -> String

    public init(definition: Definition, handler: @escaping @Sendable ([String: Any]) async -> String) {
        self.definition = definition
        self.handler = handler
    }
}
