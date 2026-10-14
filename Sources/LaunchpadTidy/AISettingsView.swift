import SwiftUI
import Security
import LaunchpadCore

enum AICredentials {
    private static let service = "com.luxi.launchpadtidy.ai"
    private static func query(_ configuration: AIConfiguration) throws -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: try configuration.endpoint().absoluteString]
    }
    static func load(_ configuration: AIConfiguration) throws -> String {
        var query = try query(configuration)
        query[kSecReturnData as String] = true; query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return "" }
        guard status == errSecSuccess, let data = result as? Data, let text = String(data: data, encoding: .utf8) else { throw TidyError.message("无法读取钥匙串中的 AI 密钥（\(status)）。") }
        return text
    }
    static func save(_ key: String, for configuration: AIConfiguration) throws {
        let query = try query(configuration)
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if key.isEmpty {
            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw TidyError.message("无法清除钥匙串中的 AI 密钥（\(status)）。") }
            return
        }
        let values = [kSecValueData as String: Data(key.utf8)]
        var status = SecItemUpdate(query as CFDictionary, values as CFDictionary)
        if status == errSecItemNotFound {
            var item = query; item[kSecValueData as String] = Data(key.utf8)
            item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            status = SecItemAdd(item as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw TidyError.message("无法保存到 macOS 钥匙串（\(status)），配置未保存。") }
    }
}

struct AISettingsView: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss
    let startAfterSave: Bool
    @State private var configuration = AIConfiguration()
    @State private var apiKey = ""
    @State private var preset = "custom"
    @State private var error: String?
    @State private var models: [String] = []
    @State private var advanced = false
    @State private var checking = false
    @State private var connectionStatus: String?
    @State private var credentialReadFailed = false
    @State private var checkTask: Task<Void, Never>?
    init(configuration: AIConfiguration, startAfterSave: Bool) {
        _configuration = State(initialValue: configuration)
        self.startAfterSave = startAfterSave
        _preset = State(initialValue: configuration.baseURL == "https://api.deepseek.com" ? "deepseek" : configuration.baseURL == "http://127.0.0.1:11434/v1" ? "ollama" : "custom")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label("AI 设置", systemImage: "sparkles").font(.title2.bold())
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text("设置一次，以后直接点击 AI 整理。").font(.callout).foregroundStyle(.secondary)
                    Form {
                        Picker("服务", selection: $preset) {
                            Text("DeepSeek").tag("deepseek")
                            Text("本机 Ollama").tag("ollama")
                            Text("自定义兼容接口").tag("custom")
                        }.onChange(of: preset) { _, value in
                            if value == "deepseek" { configuration.baseURL = "https://api.deepseek.com"; configuration.model = "deepseek-flash" }
                            if value == "ollama" { configuration.baseURL = "http://127.0.0.1:11434/v1"; configuration.model = "qwen3:8b" }
                        }
                        TextField("Base URL", text: $configuration.baseURL).textFieldStyle(.roundedBorder)
                            .onChange(of: configuration.baseURL) { old, new in
                                var previous = configuration; previous.baseURL = old
                                guard (try? previous.endpoint()) != (try? configuration.endpoint()) else { return }
                                apiKey = ""; models = []; connectionStatus = nil; credentialReadFailed = false
                                if (try? configuration.endpoint()) != nil { readCredential() }
                            }
                        HStack {
                            TextField("模型名称", text: $configuration.model).textFieldStyle(.roundedBorder)
                            if !models.isEmpty {
                                Menu("选择模型") { ForEach(models, id: \.self) { name in Button(name) { configuration.model = name } } }
                            }
                        }
                        SecureField("API Key", text: $apiKey).textFieldStyle(.roundedBorder)
                        Toggle("仅整理未归类应用，保留已有分类", isOn: $configuration.onlyUngrouped)
                    }.disabled(checking)
                    HStack {
                        Button { checkConnection() } label: { Label("检测连接", systemImage: "network") }.disabled(checking)
                        if checking { ProgressView().controlSize(.small); Button("取消检测") { checkTask?.cancel() } }
                        if let connectionStatus { Text(connectionStatus).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
                    }
                    DisclosureGroup("更多选项", isExpanded: $advanced) {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("整理偏好").font(.caption)
                            TextEditor(text: $configuration.instructions).font(.callout).frame(height: 70).padding(6)
                                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.primary.opacity(0.12)))
                            Toggle("JSON 模式", isOn: $configuration.jsonMode)
                            Text("接口不支持时可关闭，分类结果仍会校验。").font(.caption).foregroundStyle(.secondary)
                        }.padding(.top, 10)
                    }
                    Text("密钥保存在钥匙串。整理仅发送应用名称、标识、文件夹名和偏好到所选服务；远程调用可能收费。本机 Ollama 需提前运行。").font(.caption).foregroundStyle(.secondary)
                    if let error { Text(error).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(startAfterSave ? "保存并开始整理" : "保存设置") {
                    do {
                        _ = try configuration.endpoint()
                        guard !configuration.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw TidyError.message("请填写或选择模型名称。") }
                        try configuration.validateCredential(apiKey)
                        guard !credentialReadFailed || !apiKey.isEmpty else { throw TidyError.message("钥匙串读取失败，请重试读取或填写密钥后保存。") }
                        try AICredentials.save(apiKey, for: configuration)
                        let data = try JSONEncoder().encode(configuration)
                        UserDefaults.standard.set(data, forKey: "aiConfiguration")
                        store.aiConfiguration = configuration
                        dismiss()
                        if startAfterSave { store.organizeWithAI() }
                    } catch { self.error = error.localizedDescription }
                }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(checking)
            }
        }.padding(22).frame(width: 480, height: 420)
        .onAppear { readCredential() }
        .onDisappear { checkTask?.cancel() }
    }
    private func readCredential() {
        do { apiKey = try AICredentials.load(configuration); credentialReadFailed = false }
        catch { credentialReadFailed = true; self.error = error.localizedDescription }
    }
    private func checkConnection() {
        let config = configuration, key = apiKey
        do { _ = try config.endpoint(); try config.validateCredential(key) }
        catch { self.error = error.localizedDescription; return }
        checking = true; error = nil; connectionStatus = nil
        checkTask = Task {
            defer { checking = false; checkTask = nil }
            do {
                let available = try await AIClient().availableModels(configuration: config, apiKey: key)
                try Task.checkCancellation(); models = available
                connectionStatus = available.isEmpty ? "连接成功，接口未列出模型" : "连接成功 · \(available.count) 个模型"
            } catch is CancellationError { connectionStatus = "已取消检测" }
            catch { self.error = error.localizedDescription }
        }
    }
}
