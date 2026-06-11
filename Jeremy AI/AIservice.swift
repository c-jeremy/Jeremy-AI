//
//  AIservice.swift
//  Jeremy AI
//
//  Created by jeremy on 2026/6/11.
//
import Foundation

// MARK: - OpenAI 兼容格式的 Codable 结构体

struct ChatMessage: Codable {
    let role: String
    let content: String?
    let toolCalls: [ToolCall]?
    let toolCallId: String?
    let name: String?

    enum CodingKeys: String, CodingKey {
        case role, content, name
        case toolCalls   = "tool_calls"
        case toolCallId  = "tool_call_id"
    }

    static func user(_ text: String) -> ChatMessage {
        ChatMessage(role: "user", content: text, toolCalls: nil, toolCallId: nil, name: nil)
    }

    static func toolResult(id: String, name: String, content: String) -> ChatMessage {
        ChatMessage(role: "tool", content: content, toolCalls: nil, toolCallId: id, name: name)
    }
}

struct ToolCall: Codable {
    let id: String
    let type: String
    let function: ToolCallFunction
}

struct ToolCallFunction: Codable {
    let name: String
    let arguments: String
}

struct CFResponse: Codable {
    let result: CFResult?
}

struct CFResult: Codable {
    let choices: [Choice]
}

struct Choice: Codable {
    let message: ChatMessage
}

// MARK: - Tool 定义

struct ToolDefinition: Encodable {
    let type = "function"
    let function: ToolFunction
}

struct ToolFunction: Encodable {
    let name: String
    let description: String
    let parameters: ToolParameters
}

struct ToolParameters: Encodable {
    let type = "object"
    let properties: [String: ToolProperty]
    let required: [String]
}

struct ToolProperty: Encodable {
    let type: String
    let description: String
}

// MARK: - 带卡片的返回值

struct ChatResult {
    let text: String
    let cards: [ResultCard]
}

// MARK: - AI Service

@MainActor
class AIService: ObservableObject {
    private let toolEngine = ToolEngine()
    private var sessionHistory: [ChatMessage] = []

    func resetSession() {
        sessionHistory = []
    }

    func send(userMessage: String) async throws -> ChatResult {
        sessionHistory.append(.user(userMessage))
        var collectedCards: [ResultCard] = []

        for _ in 0..<5 {
            let response = try await callCF(messages: sessionHistory)

            guard let choice = response.result?.choices.first else {
                throw AIError.emptyResponse
            }

            let assistantMsg = choice.message

            guard let toolCalls = assistantMsg.toolCalls, !toolCalls.isEmpty else {
                let text = assistantMsg.content ?? ""
                sessionHistory.append(assistantMsg)
                return ChatResult(text: text, cards: collectedCards)
            }

            sessionHistory.append(assistantMsg)

            // 并行执行所有 tool calls
            let executions = await withTaskGroup(of: (ChatMessage, ResultCard?).self) { group in
                for call in toolCalls {
                    group.addTask {
                        let exec = await self.toolEngine.execute(call)
                        let msg = ChatMessage.toolResult(
                            id: call.id,
                            name: call.function.name,
                            content: exec.llmResult
                        )
                        return (msg, exec.card)
                    }
                }
                var results: [(ChatMessage, ResultCard?)] = []
                for await result in group { results.append(result) }
                return results
            }

            for (msg, card) in executions {
                sessionHistory.append(msg)
                if let card = card { collectedCards.append(card) }
            }
        }

        throw AIError.tooManyToolRounds
    }

    private func callCF(messages: [ChatMessage]) async throws -> CFResponse {
        var request = URLRequest(url: URL(string: Config.cfEndpoint)!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(Config.cfApiToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "messages": try encodeMessages(messages),
            "tools":    try encodeTools(toolEngine.definitions)
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, _) = try await URLSession.shared.data(for: request)
        return try JSONDecoder().decode(CFResponse.self, from: data)
    }

    private func encodeMessages(_ messages: [ChatMessage]) throws -> [[String: Any]] {
        let data = try JSONEncoder().encode(messages)
        return try JSONSerialization.jsonObject(with: data) as! [[String: Any]]
    }

    private func encodeTools(_ tools: [ToolDefinition]) throws -> [[String: Any]] {
        let data = try JSONEncoder().encode(tools)
        return try JSONSerialization.jsonObject(with: data) as! [[String: Any]]
    }
}

enum AIError: Error, LocalizedError {
    case emptyResponse
    case tooManyToolRounds

    var errorDescription: String? {
        switch self {
        case .emptyResponse:     return "没有收到有效响应"
        case .tooManyToolRounds: return "工具调用轮次过多"
        }
    }
}
