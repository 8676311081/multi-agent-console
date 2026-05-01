import Foundation
import Testing
@testable import OpenIslandCore

struct LLMRequestAnalyzerTests {
    // MARK: - Empty / malformed

    @Test
    func emptyBodyReturnsEmptyDeclaration() {
        let result = LLMRequestAnalyzer.analyzeDeclaredTools(in: Data())
        #expect(result == .empty)
    }

    @Test
    func malformedJSONReturnsEmpty() {
        let result = LLMRequestAnalyzer.analyzeDeclaredTools(in: Data("{not json".utf8))
        #expect(result == .empty)
    }

    @Test
    func bodyWithoutToolsArrayReturnsEmpty() {
        let body = #"{"model":"claude-opus-4-7","messages":[]}"#
        let result = LLMRequestAnalyzer.analyzeDeclaredTools(in: Data(body.utf8))
        #expect(result == .empty)
    }

    // MARK: - Anthropic shape

    @Test
    func anthropicShapeExtractsAllToolNamesAndEstimates() {
        let body = """
        {
          "model": "claude-opus-4-7",
          "tools": [
            {
              "name": "Bash",
              "description": "Execute a shell command and return stdout/stderr.",
              "input_schema": {
                "type": "object",
                "properties": {"command": {"type": "string"}},
                "required": ["command"]
              }
            },
            {
              "name": "Read",
              "description": "Read a file and return its contents.",
              "input_schema": {
                "type": "object",
                "properties": {"file_path": {"type": "string"}},
                "required": ["file_path"]
              }
            }
          ],
          "messages": []
        }
        """
        let result = LLMRequestAnalyzer.analyzeDeclaredTools(in: Data(body.utf8))
        #expect(result.toolNames == ["Bash", "Read"])
        // Each tool should have a non-zero estimate (the schema is
        // non-trivial in size).
        #expect((result.estimatedTokensPerTool["Bash"] ?? 0) > 5)
        #expect((result.estimatedTokensPerTool["Read"] ?? 0) > 5)
    }

    // MARK: - OpenAI shape

    @Test
    func openAIShapeExtractsToolNamesViaNestedFunction() {
        let body = """
        {
          "model": "gpt-4o",
          "tools": [
            {
              "type": "function",
              "function": {
                "name": "get_weather",
                "description": "Look up current weather for a city.",
                "parameters": {
                  "type": "object",
                  "properties": {"city": {"type": "string"}}
                }
              }
            }
          ]
        }
        """
        let result = LLMRequestAnalyzer.analyzeDeclaredTools(in: Data(body.utf8))
        #expect(result.toolNames == ["get_weather"])
        #expect((result.estimatedTokensPerTool["get_weather"] ?? 0) > 5)
    }

    // MARK: - Edge cases

    @Test
    func toolWithoutNameIsSkippedNotCrashed() {
        let body = """
        {
          "tools": [
            {"description": "anonymous"},
            {"name": "Real", "description": "x"},
            {"function": {"name": "Nested", "description": "y"}}
          ]
        }
        """
        let result = LLMRequestAnalyzer.analyzeDeclaredTools(in: Data(body.utf8))
        #expect(result.toolNames == ["Real", "Nested"])
    }

    @Test
    func emptyToolsArrayProducesEmptyDeclaration() {
        let body = #"{"tools": [], "messages": []}"#
        let result = LLMRequestAnalyzer.analyzeDeclaredTools(in: Data(body.utf8))
        #expect(result.toolNames.isEmpty)
        #expect(result.estimatedTokensPerTool.isEmpty)
    }

    // MARK: - Wasted-token math invariants (the consumer-visible
    // contract: declared - used = wasted token sum)

    @Test
    func wastedTokenMathIsSumOfUnusedToolEstimates() {
        let body = """
        {
          "tools": [
            {"name": "A", "description": "alpha"},
            {"name": "B", "description": "beta"},
            {"name": "C", "description": "gamma"}
          ]
        }
        """
        let result = LLMRequestAnalyzer.analyzeDeclaredTools(in: Data(body.utf8))
        #expect(result.toolNames == ["A", "B", "C"])
        let used: Set<String> = ["A"]
        let unused = result.toolNames.subtracting(used)
        #expect(unused == ["B", "C"])
        let wasted = unused.reduce(0) { acc, n in
            acc + (result.estimatedTokensPerTool[n] ?? 0)
        }
        #expect(wasted > 0)
        // Sanity: wasted equals B + C.
        #expect(wasted == (result.estimatedTokensPerTool["B"] ?? 0)
                          + (result.estimatedTokensPerTool["C"] ?? 0))
    }
}
