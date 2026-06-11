//
//  Toolsandview.swift
//  Jeremy AI
//
//  Created by jeremy on 2026/6/11.
//

import SwiftUI

// MARK: - 卡片模型

enum CardType {
    case calendarEvent, weather, note
}

enum CardAction: String {
    case openCalendar = "打开日历"
    case openNotes    = "打开备忘录"
}

struct ResultCard: Identifiable {
    let id     = UUID()
    let type:   CardType
    let title:  String
    let fields: [(label: String, value: String)]
    let action: CardAction?
}

struct ToolExecution {
    let llmResult: String
    let card: ResultCard?
}

// MARK: - Tool Engine

class ToolEngine {

    var definitions: [ToolDefinition] {[
        ToolDefinition(function: ToolFunction(
            name: "add_note",
            description: "新建一条备忘录",
            parameters: ToolParameters(
                properties: [
                    "title":   ToolProperty(type: "string", description: "标题"),
                    "content": ToolProperty(type: "string", description: "正文内容")
                ],
                required: ["title", "content"]
            )
        )),
        ToolDefinition(function: ToolFunction(
            name: "add_calendar_event",
            description: "新建一个日程",
            parameters: ToolParameters(
                properties: [
                    "title":      ToolProperty(type: "string", description: "日程标题"),
                    "start_time": ToolProperty(type: "string", description: "开始时间，格式必须 yyyy-MM-dd HH:mm"),
                    "location":   ToolProperty(type: "string", description: "地点（可选）")
                ],
                required: ["title", "start_time"]
            )
        )),
        ToolDefinition(function: ToolFunction(
            name: "open_app",
            description: "打开某个应用程序",
            parameters: ToolParameters(
                properties: [
                    "name": ToolProperty(type: "string", description: "应用名称，例如 Safari、Xcode、Music")
                ],
                required: ["name"]
            )
        )),
        ToolDefinition(function: ToolFunction(
            name: "get_weather",
            description: "获取某城市的天气，支持今天/明天/后天",
            parameters: ToolParameters(
                properties: [
                    "city": ToolProperty(type: "string", description: "城市名，例如Beijing"),
                    "date": ToolProperty(type: "string", description: "today、tomorrow或day_after_tomorrow，默认 today")
                ],
                required: ["city"]
            )
        )),
    ]}

    // MARK: - 分发

    func execute(_ call: ToolCall) async -> ToolExecution {
        let args = parseArgs(call.function.arguments)
        switch call.function.name {
        case "add_note":
            return addNote(
                title:   args["title"]   ?? "无标题",
                content: args["content"] ?? ""
            )
        case "add_calendar_event":
            return addCalendarEvent(
                title:     args["title"]      ?? "新日程",
                startTime: args["start_time"] ?? "",
                location:  args["location"]
            )
        case "open_app":
            return openApp(name: args["name"] ?? "")
        case "get_weather":
            return await getWeather(
                city: args["city"] ?? "Beijing",
                date: args["date"] ?? "today"
            )
        default:
            return ToolExecution(llmResult: "未知工具：\(call.function.name)", card: nil)
        }
    }

    // MARK: - add_note（osascript 子进程）

    private func addNote(title: String, content: String) -> ToolExecution {
        let t = title.replacingOccurrences(of: "\"", with: "'")
        let c = content.replacingOccurrences(of: "\"", with: "'")
        let script = """
        tell application "Notes"
            make new note at folder "Notes" with properties {name:"\(t)", body:"\(c)"}
        end tell
        """
        let result = runOsascript(script)
        guard result.success else {
            return ToolExecution(llmResult: "创建失败：\(result.error)", card: nil)
        }
        let card = ResultCard(
            type: .note,
            title: title,
            fields: [("内容", content)],
            action: .openNotes
        )
        return ToolExecution(llmResult: "已保存到 Notes", card: card)
    }

    // MARK: - add_calendar_event（osascript 子进程）

    private func addCalendarEvent(title: String, startTime: String, location: String?) -> ToolExecution {
        // 把 "yyyy-MM-dd HH:mm" 转成 AppleScript 能识别的 date 字符串
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd HH:mm"
        guard let date = fmt.date(from: startTime) else {
            return ToolExecution(llmResult: "时间格式错误，请用 yyyy-MM-dd HH:mm", card: nil)
        }

        let asFmt = DateFormatter()
        asFmt.dateFormat = "MM/dd/yyyy HH:mm:ss"
        let asDateStr = asFmt.string(from: date)

        let t        = title.replacingOccurrences(of: "\"", with: "'")
        let locLine  = location.map { "set location of theEvent to \"\($0.replacingOccurrences(of: "\"", with: "'"))\"" } ?? ""

        let script = """
        tell application "Calendar"
            tell calendar 1
                set theEvent to make new event with properties {summary:"\(t)", start date:(date "\(asDateStr)"), end date:(date "\(asDateStr)") + 3600}
                \(locLine)
            end tell
        end tell
        """
        let result = runOsascript(script)
        guard result.success else {
            return ToolExecution(llmResult: "创建失败：\(result.error)", card: nil)
        }

        var fields: [(label: String, value: String)] = [("时间", startTime)]
        if let loc = location { fields.append(("地点", loc)) }

        let card = ResultCard(type: .calendarEvent, title: title, fields: fields, action: .openCalendar)
        return ToolExecution(llmResult: "已添加到日历", card: card)
    }

    // MARK: - open_app

    private func openApp(name: String) -> ToolExecution {
        let result = runShell("/usr/bin/open", args: ["-a", name])
        let msg = result.success ? "已打开 \(name)" : "找不到应用「\(name)」，请检查名称"
        return ToolExecution(llmResult: msg, card: nil)
    }

    // MARK: - get_weather（wttr.in）

    private func getWeather(city: String, date: String) async -> ToolExecution {
        let encoded = city.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? city
        guard let url = URL(string: "https://wttr.in/\(encoded)?format=j1") else {
            return ToolExecution(llmResult: "城市名无效", card: nil)
        }
        guard let (data, _) = try? await URLSession.shared.data(from: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return ToolExecution(llmResult: "获取失败，请检查网络", card: nil)
        }

        let dayIndex: Int
        switch date {
        case "tomorrow":           dayIndex = 1
        case "day_after_tomorrow": dayIndex = 2
        default:                   dayIndex = 0
        }

        let weatherArr = json["weather"] as? [[String: Any]] ?? []
        let current    = (json["current_condition"] as? [[String: Any]])?.first

        if dayIndex == 0, let cur = current {
            let desc  = ((cur["weatherDesc"] as? [[String: Any]])?.first?["value"] as? String) ?? "—"
            let temp  = cur["temp_C"]        as? String ?? "—"
            let humid = cur["humidity"]      as? String ?? "—"
            let wind  = cur["windspeedKmph"] as? String ?? "—"
            let card  = ResultCard(
                type: .weather, title: "\(city) · 今天",
                fields: [("天气", desc), ("温度", "\(temp)°C"), ("湿度", "\(humid)%"), ("风速", "\(wind) km/h")],
                action: nil
            )
            return ToolExecution(llmResult: "当前 \(city)：\(desc)，\(temp)°C", card: card)

        } else if dayIndex < weatherArr.count {
            let day    = weatherArr[dayIndex]
            let maxT   = day["maxtempC"] as? String ?? "—"
            let minT   = day["mintempC"] as? String ?? "—"
            let desc   = ((day["hourly"] as? [[String: Any]])?.first?["weatherDesc"] as? [[String: Any]])?.first?["value"] as? String ?? "—"
            let dateStr = day["date"] as? String ?? ""
            let label  = dayIndex == 1 ? "明天" : "后天"
            let card   = ResultCard(
                type: .weather, title: "\(city) · \(label)",
                fields: [("日期", dateStr), ("天气", desc), ("最高", "\(maxT)°C"), ("最低", "\(minT)°C")],
                action: nil
            )
            return ToolExecution(llmResult: "\(label) \(city)：\(desc)，\(minT)~\(maxT)°C", card: card)
        }

        return ToolExecution(llmResult: "暂无该日期的预报数据", card: nil)
    }

    // MARK: - 底层工具函数

    /// 运行 osascript，权限归属于系统 osascript 二进制，绕开 MenuBarExtra TCC 限制
    @discardableResult
    private func runOsascript(_ script: String) -> (success: Bool, error: String) {
        runShell("/usr/bin/osascript", args: ["-e", script])
    }

    private func runShell(_ path: String, args: [String]) -> (success: Bool, error: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args

        let errPipe = Pipe()
        process.standardError = errPipe

        do {
            try process.run()
            process.waitUntilExit()
            let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            let errStr  = String(data: errData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return (process.terminationStatus == 0, errStr)
        } catch {
            return (false, error.localizedDescription)
        }
    }

    private func parseArgs(_ json: String) -> [String: String] {
        guard let data = json.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }
        return dict.compactMapValues { "\($0)" }
    }
}

// MARK: - Card View

struct CardView: View {
    let card: ResultCard

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .foregroundStyle(accent)
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: 28, height: 28)
                    .background(accent.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 7))
                Text(card.title)
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
            }

            VStack(alignment: .leading, spacing: 4) {
                ForEach(card.fields, id: \.label) { field in
                    HStack(spacing: 6) {
                        Text(field.label)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .frame(width: 36, alignment: .leading)
                        Text(field.value)
                            .font(.system(size: 12))
                    }
                }
            }

            if let action = card.action {
                Button(action.rawValue) { handleAction(action) }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .tint(accent)
            }
        }
        .padding(12)
        .background(accent.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(accent.opacity(0.15), lineWidth: 1))
    }

    private var icon: String {
        switch card.type {
        case .calendarEvent: return "calendar"
        case .weather:       return "cloud.sun"
        case .note:          return "note.text"
        }
    }

    private var accent: Color {
        switch card.type {
        case .calendarEvent: return .blue
        case .weather:       return .cyan
        case .note:          return .yellow
        }
    }

    private func handleAction(_ action: CardAction) {
        switch action {
        case .openCalendar: NSWorkspace.shared.open(URL(string: "calshow://")!)
        case .openNotes:    NSWorkspace.shared.open(URL(fileURLWithPath: "/Applications/Notes.app"))
        }
    }
}

// MARK: - Spotlight View

struct SpotlightView: View {
    @StateObject private var ai = AIService()

    @State private var query     = ""
    @State private var result: ChatResult?
    @State private var isLoading = false
    @State private var errorMsg  = ""

    @FocusState private var inputFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: isLoading ? "sparkles" : "magnifyingglass")
                    .foregroundStyle(isLoading ? .blue : .secondary)
                    .symbolEffect(.pulse, isActive: isLoading)
                    .frame(width: 20)

                TextField("Ask me anything...", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 18))
                    .focused($inputFocused)
                    .disabled(isLoading)
                    .onSubmit(handleSubmit)

                if !query.isEmpty && !isLoading {
                    Button {
                        query    = ""
                        result   = nil
                        errorMsg = ""
                        ai.resetSession()
                    } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)

            if result != nil || !errorMsg.isEmpty {
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        if let cards = result?.cards, !cards.isEmpty {
                            ForEach(cards) { card in
                                CardView(card: card)
                                    .transition(.move(edge: .top).combined(with: .opacity))
                            }
                        }
                        if let text = result?.text, !text.isEmpty {
                            Text(text)
                                .font(.system(size: 14))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        if !errorMsg.isEmpty {
                            Label(errorMsg, systemImage: "exclamationmark.triangle")
                                .font(.system(size: 13))
                                .foregroundStyle(.orange)
                        }
                    }
                    .padding(12)
                    .animation(.spring(duration: 0.35), value: result?.cards.count)
                }
                .frame(maxHeight: 360)
            }

            HStack {
                Text("GLM-4.7 Flash · Cloudflare")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                Spacer()
                if isLoading { ProgressView().scaleEffect(0.6).frame(height: 12) }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
        }
        .onAppear { inputFocused = true }
    }

    func handleSubmit() {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isLoading else { return }

        isLoading = true
        result    = nil
        errorMsg  = ""

        Task {
            do {
                let r = try await ai.send(userMessage: text)
                withAnimation { result = r }
            } catch {
                errorMsg = error.localizedDescription
            }
            isLoading = false
        }
    }
}

#Preview {
    SpotlightView().frame(width: 620)
}
