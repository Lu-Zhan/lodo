import SwiftUI
import LodoCore

/// 设置 → AI 设置:AI 相关设置统一收在这一个入口下——服务商/API Key、思考强度、
/// 联网搜索、AI 个性、语音交互、完成洞察、AI 记忆、Skill 编辑。
struct AISettingsView: View {
    @AppStorage(AppSettings.aiProviderKey) private var aiProvider = "DeepSeek"
    @AppStorage(AppSettings.aiModelKey) private var aiModel = ""
    @AppStorage(AppSettings.aiCustomEndpointKey) private var aiCustomEndpoint = ""
    @AppStorage(AppSettings.thinkingLevelKey) private var thinkingLevel = "medium"
    @AppStorage(AppSettings.useBuiltInKeyKey) private var useBuiltInKey = true
    @AppStorage(AppSettings.agentPersonaStyleKey) private var personaStyle = "默认"
    @AppStorage(AppSettings.agentPersonaCustomKey) private var personaCustom = ""
    @AppStorage(AppSettings.agentSilenceTimeoutSecondsKey) private var agentSilenceTimeoutSeconds = 3
    @AppStorage(AppSettings.insightEnabledKey) private var insightEnabled = true
    @AppStorage(AppSettings.languageKey) private var languageRaw = AppLanguage.zhHans.rawValue
    private var language: AppLanguage { AppLanguage(rawValue: languageRaw) ?? .zhHans }

    @State private var apiKey = KeychainHelper.apiKey ?? ""
    @State private var keySaved = KeychainHelper.apiKey != nil
    @State private var confirmMemoryReset = false
    @State private var confirmPreferencesReset = false

    // ---- 联网搜索(Tavily) ----
    @State private var tavilyKey = KeychainHelper.apiKey(for: "Tavily") ?? ""
    @State private var tavilyKeySaved = KeychainHelper.apiKey(for: "Tavily") != nil

    var body: some View {
        Form {
            Section {
                Picker("服务商", selection: $aiProvider) {
                    ForEach(AppSettings.aiProviders, id: \.name) { provider in
                        Text(AppSettings.displayName(forProvider: provider.name, language: language))
                            .tag(provider.name)
                    }
                    Text(AppSettings.displayName(forProvider: AppSettings.appleIntelligenceProvider, language: language))
                        .tag(AppSettings.appleIntelligenceProvider)
                    Text("自定义").tag("自定义")
                }
                if aiProvider == AppSettings.appleIntelligenceProvider {
                    Group {
                        if #available(iOS 26.0, macOS 26.0, *) {
                            Text(LocalizedStrings.translate(FoundationModelsClient.availabilityHint, language: language))
                        } else {
                            Text("苹果智能需要 iOS 26 及以上系统。")
                        }
                    }
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                } else if aiProvider == "自定义" {
                    TextField("接口地址(…/chat/completions)", text: $aiCustomEndpoint)
                        .plainKeyboard()
                    TextField("模型名称", text: $aiModel)
                        .plainKeyboard()
                } else {
                    TextField(
                        LocalizedStrings.translate("模型(默认 ", language: language) +
                            "\(AppSettings.aiProviders.first { $0.name == aiProvider }?.model ?? ""))",
                        text: $aiModel
                    )
                    .plainKeyboard()
                }
                if aiProvider == "DeepSeek", BuiltInAPIKey.deepSeek != nil {
                    Toggle("使用内置 API Key", isOn: $useBuiltInKey)
                }
                if aiProvider != AppSettings.appleIntelligenceProvider {
                    if aiProvider == "DeepSeek", useBuiltInKey, BuiltInAPIKey.deepSeek != nil {
                        Text("已使用内置 DeepSeek API Key,无需再填。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    } else {
                        SecureField("API Key", text: $apiKey)
                        Button(keySaved ? "已保存" : "保存 API Key") {
                            KeychainHelper.save(apiKey, for: aiProvider)
                            keySaved = true
                        }
                        .disabled(keySaved)
                    }
                }
            } header: {
                Text("AI 服务")
            } footer: {
                Text("默认 DeepSeek;云服务商均为 OpenAI 兼容接口,key 按服务商分别保存在钥匙串中;苹果智能在设备端运行,免 key。")
            }

            aiThinkingSection
            webSearchSection

            Section {
                Picker("AI 个性", selection: $personaStyle) {
                    Text("默认").tag("默认")
                    ForEach(AppSettings.personaPresets, id: \.name) { preset in
                        Text(AppSettings.displayName(forPersona: preset.name, language: language))
                            .tag(preset.name)
                    }
                    Text("自定义").tag("自定义")
                }
                if personaStyle == "自定义" {
                    TextField("描述 AI 的说话风格,例如:像武侠小说里的师父",
                              text: $personaCustom, axis: .vertical)
                        .lineLimit(1...4)
                } else if let preset = AppSettings.personaPresets
                    .first(where: { $0.name == personaStyle }) {
                    Text(LocalizedStrings.translate(preset.text, language: language))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("AI 个性")
            } footer: {
                Text("影响反问、汇总和洞察的说话风格,不影响解析结果;默认为无个性。")
            }

            Section {
                Stepper("静音自动停止:\(agentSilenceTimeoutSeconds) 秒",
                        value: $agentSilenceTimeoutSeconds, in: 0...30, step: 1)
            } header: {
                Text("语音交互")
            } footer: {
                Text("语音输入静音超过设定时长自动停止并提交;0 秒 = 关闭,不自动停止。")
            }

            Section {
                Toggle("完成洞察", isOn: $insightEnabled)
            } footer: {
                Text("每周在已完成区生成一句正向回顾,不会推送通知。")
            }

            Section {
                NavigationLink("编辑记忆") { MemoryEditView() }
                Button("重置记忆", role: .destructive) {
                    confirmMemoryReset = true
                }
                .confirmationDialog("确定清空 AI 记忆吗?", isPresented: $confirmMemoryReset,
                                    titleVisibility: .visible) {
                    Button("重置记忆", role: .destructive) { DurationMemory.reset() }
                }
            } header: {
                Text("AI 记忆")
            } footer: {
                Text("AI 会在事项完成后归纳\"类型 → 典型时长\",新建没说时长的事项时据此建议。")
            }

            Section {
                NavigationLink("编辑偏好") { AgentPreferencesEditView() }
                Button("重置偏好", role: .destructive) {
                    confirmPreferencesReset = true
                }
                .confirmationDialog("确定清空 AI 偏好吗?", isPresented: $confirmPreferencesReset,
                                    titleVisibility: .visible) {
                    Button("重置偏好", role: .destructive) { AgentPreferences.reset() }
                }
            } header: {
                Text("AI 偏好")
            } footer: {
                Text("你在对话里说过的长期要求(如「以后开会都留一小时」)会被 AI 自动记在这里,之后每轮对话都会带上。")
            }

            Section {
                ForEach(AgentSkillID.allCases) { id in
                    NavigationLink {
                        AgentSkillEditView(id: id)
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(id.title)
                                if AgentSkillStore.isCustomized(id) {
                                    Text("已自定义")
                                        .font(.caption2)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(.tint.opacity(0.15), in: Capsule())
                                        .foregroundStyle(.tint)
                                }
                            }
                            Text(id.subtitle)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            } header: {
                Text("AI Agent Skill")
            } footer: {
                Text("agent.md 是总则,待办/记忆是可分别编辑的技能;编辑会直接改变发给 AI 的指令,重置可恢复默认。")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("AI 设置")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .onChange(of: apiKey) { keySaved = false }
        .onChange(of: tavilyKey) { tavilyKeySaved = false }
        .onChange(of: aiProvider) { _, provider in
            // 切换服务商:载入该服务商已存的 key,清掉模型覆盖值
            apiKey = KeychainHelper.apiKey(for: provider) ?? ""
            keySaved = !apiKey.isEmpty
            aiModel = ""
        }
    }

    @ViewBuilder
    private var aiThinkingSection: some View {
        Section {
            Picker("思考强度", selection: $thinkingLevel) {
                Text("关闭").tag("off")
                Text("低").tag("low")
                Text("中").tag("medium")
                Text("高").tag("high")
            }
        } header: {
            Text("AI 思考")
        } footer: {
            Text("思考强度越高,回答通常越准确但等待更久;只有支持推理的服务商/模型才会真正生效,其余会忽略这个设置,不影响正常使用。")
        }
    }

    @ViewBuilder
    private var webSearchSection: some View {
        Section {
            SecureField("Tavily API Key", text: $tavilyKey)
                .plainKeyboard()
            Button(tavilyKeySaved ? "已保存" : "保存") {
                KeychainHelper.save(tavilyKey, for: "Tavily")
                tavilyKeySaved = true
            }
            .disabled(tavilyKeySaved)
        } header: {
            Text("联网搜索")
        } footer: {
            Text("配置后 AI 助手能在需要最新信息或回答一般问题时联网搜索;免费在 tavily.com 注册获取 API Key,不填则不启用联网搜索。")
        }
    }
}

private extension View {
    /// 关闭自动大写与纠错(macOS 无 textInputAutocapitalization)。
    @ViewBuilder
    func plainKeyboard() -> some View {
        #if os(iOS)
        self.textInputAutocapitalization(.never).autocorrectionDisabled()
        #else
        self.autocorrectionDisabled()
        #endif
    }
}
