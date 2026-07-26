//
//  PluginsSettingsView.swift
//  Paladala
//
//  Lists every plugin known to `PluginManager`, lets the user
//  toggle each, delete user-pasted ones, and add a new plugin
//  by pasting raw JSON. Built-in plugins live in the app
//  bundle and can't be deleted; their state is a
//  `UserDefaults` override keyed by `id` (handled by
//  `PluginManager.toggle(id:on:)`).
//

import SwiftUI

struct PluginsSettingsView: View {

    @ObservedObject private var manager = PluginManager.shared
    @State private var showingPasteSheet = false
    @State private var pasteText: String = ""
    @State private var pasteError: String?

    var body: some View {
        List {
            Section {
                if manager.plugins.isEmpty {
                    Text("尚未安装任何插件。粘贴 JSON 即可加入。")
                        .font(PaladalaTheme.FontRole.bodySmall)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(manager.plugins) { plugin in
                        PluginRowView(
                            plugin: plugin,
                            onToggle: { isOn in
                                do {
                                    try manager.toggle(id: plugin.id, on: isOn)
                                } catch {
                                    pasteError = error.localizedDescription
                                }
                            }
                        )
                    }
                    .onDelete { offsets in
                        for offset in offsets {
                            let id = manager.plugins[offset].id
                            manager.delete(id: id)
                        }
                    }
                }
            } header: {
                Text("已安装")
            } footer: {
                if let pasteError {
                    Text(pasteError)
                        .foregroundStyle(.red)
                }
            }

            Section {
                Button {
                    pasteText = ""
                    pasteError = nil
                    showingPasteSheet = true
                } label: {
                    Label("粘贴 JSON 导入", systemImage: "square.and.pencil")
                }
            }

            if !manager.loadErrors.isEmpty {
                Section("解析失败") {
                    ForEach(manager.loadErrors, id: \.self) { line in
                        Text(line)
                            .font(PaladalaTheme.FontRole.bodySmall)
                            .foregroundStyle(.red)
                    }
                }
            }
        }
        .navigationTitle("插件中心")
        .onAppear { manager.reload() }
        .sheet(isPresented: $showingPasteSheet) {
            pasteSheet
        }
    }

    @ViewBuilder
    private var pasteSheet: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                Text("将 JSON 粘贴进下方文本框，然后点 添加。")
                    .font(PaladalaTheme.FontRole.bodySmall)
                    .foregroundStyle(.secondary)
                TextEditor(text: $pasteText)
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 220)
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(.secondary.opacity(0.3)))
                if let pasteError {
                    Text(pasteError)
                        .foregroundStyle(.red)
                        .font(.footnote)
                }
                Spacer(minLength: 0)
            }
            .padding()
            .navigationTitle("导入 JSON")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.common.cancel) { showingPasteSheet = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("添加") {
                        do {
                            try manager.add(plainText: pasteText)
                            showingPasteSheet = false
                        } catch {
                            pasteError = error.localizedDescription
                        }
                    }
                    .disabled(pasteText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}

private struct PluginRowView: View {
    let plugin: Plugin
    let onToggle: (Bool) -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(plugin.name)
                    .font(.body.weight(.semibold))
                Text(scopeLabel(plugin.scope))
                    .font(PaladalaTheme.FontRole.labelMono)
                    .foregroundStyle(.secondary)
                Text(sourceLabel)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Toggle("", isOn: Binding(
                get: { plugin.enabled },
                set: { onToggle($0) }
            ))
            .labelsHidden()
        }
        .padding(.vertical, 4)
    }

    private var sourceLabel: String {
        switch plugin.origin {
        case .bundled: return "内置"
        case .disk: return "用户导入"
        case .none: return "—"
        }
    }

    private func scopeLabel(_ scopes: [PluginScope]) -> String {
        if scopes.isEmpty { return "无作用范围" }
        let names = scopes.map { scopeLabel($0) }
        return names.joined(separator: " · ")
    }

    private func scopeLabel(_ scope: PluginScope) -> String {
        switch scope {
        case .sponsorblock: return "SponsorBlock"
        case .cdn: return "CDN 节点"
        case .danmaku: return "弹幕"
        case .brightness: return "屏幕调光"
        }
    }
}
