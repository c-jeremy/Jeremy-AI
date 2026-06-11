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
            description: "在系统 Notes App 里新建一条备忘录",
            parameters: ToolParameters(
                properties: [
                    "title":   ToolProperty(type: "string", description: "备忘录标题"),
                    "content": ToolProperty(type: "string", description: "备忘录正文内容")
                ],
                required: ["title", "content"]
            )
        )),
        ToolDefinition(function: ToolFunction(
            name: "add_calendar_event",
            description: "在系统日历里新建一个日程。时间格式必须为 yyyy-MM-dd HH:mm",
            parameters: ToolParameters(
                properties: [
                    "title":      ToolProperty(type: "string", description: "日程标题"),
                    "start_time": ToolProperty(type: "string", description: "开始时间，格式 yyyy-MM-dd HH:mm"),
                    "location":   ToolProperty(type: "string", description: "地点（可选）")
                ],
                required: ["title", "start_time"]
            )
        )),
        ToolDefinition(function: ToolFunction(
            name: "open_app",
            description: "打开 Mac 上的某个应用程序",
            parameters: ToolParameters(
                properties: [
                    "name": ToolProperty(type: "string", description: "应用名称，例如 Safari、Xcode、Music")
                ],
                required: ["name"]
            )
        )),
        ToolDefinition(function: ToolFunction(
            name: "get_weather",
            description: "获取某个城市的天气，支持今天/明天/后天",
            parameters: ToolParameters(
                properties: [
                    "city": ToolProperty(type: "string", description: "城市名，英文或中文均可"),
                    "date": ToolProperty(type: "string", description: "today、tomorrow 或 day_after_tomorrow，默认 today")
                ],
                required: ["city"]
            )
        )),
    ]}

    func execute(_ call: ToolCall) async -> ToolExecution {
        let args = parseArgs(call.function.arguments)
        switch call.function.name {
        case "add_note":
            return addNote(title: args["title"] ?? "无标题", content: args["content"] ?? "")
        case "add_calendar_event":
            return addCalendarEvent(title: args["title"] ?? "新日程", startTime: args["start_time"] ?? "", location: args["location"])
        case "open_app":
            return openApp(name: args["name"] ?? "")
        case "get_weather":
            return await getWeather(city: args["city"] ?? "Beijing", date: args["date"] ?? "today")
        default:
            return ToolExecution(llmResult: "未知工具：\(call.function.name)", card: nil)
        }
    }

    private func addNote(title: String, content: String) -> ToolExecution {
        let t = title.replacingOccurrences(of: "\"", with: "'")
        let c = content.replacingOccurrences(of: "\"", with: "'")
        let script = "tell application \"Notes\" to make new note at folder \"Notes\" with properties {name:\"\(t)\", body:\"\(c)\"}"
        let result = runOsascript(script)
        guard result.success else { return ToolExecution(llmResult: "备忘录创建失败：\(result.error)", card: nil) }
        return ToolExecution(llmResult: "备忘录「\(title)」已保存", card: ResultCard(type: .note, title: title, fields: [("内容", content)], action: .openNotes))
    }

    private func addCalendarEvent(title: String, startTime: String, location: String?) -> ToolExecution {
        let fmt = DateFormatter(); fmt.dateFormat = "yyyy-MM-dd HH:mm"
        guard let date = fmt.date(from: startTime) else { return ToolExecution(llmResult: "时间格式错误，请用 yyyy-MM-dd HH:mm", card: nil) }
        let asFmt = DateFormatter(); asFmt.dateFormat = "MM/dd/yyyy HH:mm:ss"
        let asDateStr = asFmt.string(from: date)
        let t = title.replacingOccurrences(of: "\"", with: "'")
        let locLine = location.map { "set location of theEvent to \"\($0.replacingOccurrences(of: "\"", with: "'"))\"" } ?? ""
        let script = """
        tell application "Calendar"
            tell calendar 1
                set theEvent to make new event with properties {summary:"\(t)", start date:(date "\(asDateStr)"), end date:(date "\(asDateStr)") + 3600}
                \(locLine)
            end tell
        end tell
        """
        let result = runOsascript(script)
        guard result.success else { return ToolExecution(llmResult: "日程创建失败：\(result.error)", card: nil) }
        var fields: [(label: String, value: String)] = [("时间", startTime)]
        if let loc = location { fields.append(("地点", loc)) }
        return ToolExecution(llmResult: "日程「\(title)」已添加", card: ResultCard(type: .calendarEvent, title: title, fields: fields, action: .openCalendar))
    }

    private func openApp(name: String) -> ToolExecution {
        let result = runShell("/usr/bin/open", args: ["-a", name])
        return ToolExecution(llmResult: result.success ? "已打开 \(name)" : "找不到应用「\(name)」", card: nil)
    }

    private func getWeather(city: String, date: String) async -> ToolExecution {
        let encoded = city.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? city
        guard let url = URL(string: "https://wttr.in/\(encoded)?format=j1"),
              let (data, _) = try? await URLSession.shared.data(from: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return ToolExecution(llmResult: "天气获取失败", card: nil) }

        let dayIndex = date == "tomorrow" ? 1 : date == "day_after_tomorrow" ? 2 : 0
        let weatherArr = json["weather"] as? [[String: Any]] ?? []
        let current    = (json["current_condition"] as? [[String: Any]])?.first

        if dayIndex == 0, let cur = current {
            let desc  = ((cur["weatherDesc"] as? [[String: Any]])?.first?["value"] as? String) ?? "—"
            let temp  = cur["temp_C"] as? String ?? "—"
            let humid = cur["humidity"] as? String ?? "—"
            let wind  = cur["windspeedKmph"] as? String ?? "—"
            return ToolExecution(llmResult: "当前 \(city)：\(desc)，\(temp)°C",
                card: ResultCard(type: .weather, title: "\(city)  今天", fields: [("天气", desc), ("温度", "\(temp)°C"), ("湿度", "\(humid)%"), ("风速", "\(wind) km/h")], action: nil))
        } else if dayIndex < weatherArr.count {
            let day    = weatherArr[dayIndex]
            let maxT   = day["maxtempC"] as? String ?? "—"
            let minT   = day["mintempC"] as? String ?? "—"
            let desc   = ((day["hourly"] as? [[String: Any]])?.first?["weatherDesc"] as? [[String: Any]])?.first?["value"] as? String ?? "—"
            let dateStr = day["date"] as? String ?? ""
            let label  = dayIndex == 1 ? "明天" : "后天"
            return ToolExecution(llmResult: "\(label) \(city)：\(desc)，\(minT)~\(maxT)°C",
                card: ResultCard(type: .weather, title: "\(city)  \(label)", fields: [("日期", dateStr), ("天气", desc), ("最高", "\(maxT)°C"), ("最低", "\(minT)°C")], action: nil))
        }
        return ToolExecution(llmResult: "暂无该日期的预报数据", card: nil)
    }

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
            try process.run(); process.waitUntilExit()
            let errStr = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return (process.terminationStatus == 0, errStr)
        } catch { return (false, error.localizedDescription) }
    }

    private func parseArgs(_ json: String) -> [String: String] {
        guard let data = json.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }
        return dict.compactMapValues { "\($0)" }
    }
}

// MARK: - Card View（Liquid Glass 版）

struct CardView: View {
    let card: ResultCard
    @State private var appeared = false

    var body: some View {
        HStack(alignment: .top, spacing: 14) {

            // 图标柱
            VStack {
                ZStack {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(accent.gradient.opacity(0.85))
                        .frame(width: 36, height: 36)
                    Image(systemName: icon)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white)
                }
                Spacer()
            }

            // 内容柱
            VStack(alignment: .leading, spacing: 8) {
                Text(card.title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.primary)

                // 字段
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(card.fields, id: \.label) { field in
                        HStack(alignment: .firstTextBaseline, spacing: 0) {
                            Text(field.label)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(.secondary)
                                .frame(width: 34, alignment: .leading)
                            Text(field.value)
                                .font(.system(size: 12))
                                .foregroundStyle(.primary.opacity(0.85))
                        }
                    }
                }

                if let action = card.action {
                    Button {
                        handleAction(action)
                    } label: {
                        Text(action.rawValue)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(accent)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(accent.opacity(0.12), in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 2)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        // Liquid Glass 卡片
        .glassEffect(
            .regular.tint(accent.opacity(0.04)).interactive(),
            in: RoundedRectangle(cornerRadius: 14)
        )
        .opacity(appeared ? 1 : 0)
        .offset(y: appeared ? 0 : 6)
        .onAppear {
            withAnimation(.spring(duration: 0.38, bounce: 0.18)) { appeared = true }
        }
    }

    private var icon: String {
        switch card.type {
        case .calendarEvent: "calendar"
        case .weather:       "cloud.sun.fill"
        case .note:          "note.text"
        }
    }

    private var accent: Color {
        switch card.type {
        case .calendarEvent: .blue
        case .weather:       .cyan
        case .note:          .orange
        }
    }

    private func handleAction(_ action: CardAction) {
        switch action {
        case .openCalendar: NSWorkspace.shared.open(URL(string: "calshow://")!)
        case .openNotes:    NSWorkspace.shared.open(URL(fileURLWithPath: "/Applications/Notes.app"))
        }
    }
}

// MARK: - Spotlight View（Liquid Glass 版）

struct SpotlightView: View {
    var onDismiss: (() -> Void)? = nil

    @StateObject private var ai = AIService()

    @State private var query     = ""
    @State private var result: ChatResult?
    @State private var isLoading = false
    @State private var errorMsg  = ""

    @FocusState private var inputFocused: Bool

    private var hasContent: Bool { result != nil || !errorMsg.isEmpty }

    var body: some View {
        VStack(spacing: 0) {

            // ── 搜索框 ────────────────────────────────────────
            HStack(spacing: 12) {
                // 图标：idle / thinking
                ZStack {
                    Image(systemName: "magnifyingglass")
                        .opacity(isLoading ? 0 : 1)
                    Image(systemName: "sparkles")
                        .symbolEffect(.variableColor.iterative.dimInactiveLayers, isActive: isLoading)
                        .foregroundStyle(.blue)
                        .opacity(isLoading ? 1 : 0)
                }
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 22)
                .animation(.easeInOut(duration: 0.2), value: isLoading)

                TextField("问点什么，或者让我帮你做点什么", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 19, weight: .regular))
                    .focused($inputFocused)
                    .disabled(isLoading)
                    .onSubmit(handleSubmit)

                if !query.isEmpty {
                    Button {
                        withAnimation(.easeOut(duration: 0.15)) {
                            query    = ""
                            result   = nil
                            errorMsg = ""
                        }
                        ai.resetSession()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.tertiary)
                            .font(.system(size: 16))
                    }
                    .buttonStyle(.plain)
                    .transition(.opacity.combined(with: .scale(0.8)))
                }
            }
            .padding(.horizontal, 18)
            .padding(.top, 18)
            .padding(.bottom, hasContent ? 14 : 18)

            // ── 结果区 ────────────────────────────────────────
            if hasContent {
                Divider()
                    .opacity(0.25)
                    .padding(.horizontal, 4)

                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {

                        // 卡片
                        if let cards = result?.cards, !cards.isEmpty {
                            ForEach(cards) { CardView(card: $0) }
                        }

                        // 文字回复
                        if let text = result?.text, !text.isEmpty {
                            Text(text)
                                .font(.system(size: 13.5))
                                .foregroundStyle(.primary.opacity(0.85))
                                .lineSpacing(3)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 4)
                                .padding(.top, result?.cards.isEmpty == false ? 4 : 0)
                        }

                        // 错误
                        if !errorMsg.isEmpty {
                            Label(errorMsg, systemImage: "exclamationmark.triangle.fill")
                                .font(.system(size: 12.5))
                                .foregroundStyle(.orange)
                                .padding(.horizontal, 4)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 12)
                }
                .frame(maxHeight: 380)
            }

            // ── 底部栏 ────────────────────────────────────────
            HStack(spacing: 6) {
                Circle()
                    .fill(isLoading ? Color.blue : Color.green)
                    .frame(width: 5, height: 5)
                    .opacity(0.7)
                Text(isLoading ? "思考中…" : "GLM-4.7 Flash  ·  Cloudflare")
                    .font(.system(size: 10.5, weight: .regular))
                    .foregroundStyle(.tertiary)
                Spacer()
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 8)
            .animation(.easeInOut(duration: 0.3), value: isLoading)
        }
        // 纯 Liquid Glass，不加任何 background，才能真正折射桌面
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 18))
        .frame(width: 640)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear { inputFocused = true }
        .onExitCommand { onDismiss?() }
    }

    func handleSubmit() {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isLoading else { return }

        withAnimation(.easeOut(duration: 0.1)) { result = nil; errorMsg = "" }
        isLoading = true

        Task {
            do {
                let r = try await ai.send(userMessage: text)
                withAnimation(.spring(duration: 0.4)) { result = r }
            } catch {
                withAnimation { errorMsg = error.localizedDescription }
            }
            isLoading = false
        }
    }
}

#Preview {
    ZStack {
        Color.gray.opacity(0.3).ignoresSafeArea()
        SpotlightView().padding(40)
    }
}
