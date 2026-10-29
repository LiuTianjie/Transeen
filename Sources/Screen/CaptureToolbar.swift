import SwiftUI
import AppKit

struct CaptureToolbar: View {
    @Bindable var state: CaptureState
    var action: (String) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showsStyle = false
    @State private var showsText = false
    @FocusState private var numberFocused: Bool
    private let colors: [NSColor] = [.systemRed, .systemOrange, .systemYellow, .systemGreen, .systemBlue, .white]
    private let toolbarWidth: CGFloat = 536
    private var showsInspector: Bool { state.annotations.selectedID != nil || (state.annotating && state.annotations.tool != .move) }
    private var effectiveTool: AnnotationTool { state.annotations.selected?.tool ?? state.annotations.tool }

    var body: some View {
        VStack(spacing: 0) {
                HStack(spacing: 8) {
                    comparison.frame(width: 84)
                    separator
                    HStack(spacing: 2) {
                        ForEach(AnnotationTool.allCases) { tool in
                            Button {
                                animate { action("tool." + (state.annotations.tool == tool ? AnnotationTool.move.rawValue : tool.rawValue)) }
                            } label: { icon(tool.symbol) }
                                .buttonStyle(CaptureToolbarButtonStyle(selected: state.annotations.tool == tool && (tool != .move || state.annotations.selectedID != nil)))
                                .help(tool == .number ? "编号 · 下一个：\(state.annotations.nextNumber)" : tool.title)
                                .accessibilityLabel(tool.title)
                                .accessibilityAddTraits(state.annotations.tool == tool ? .isSelected : [])
                        }
                    }
                    separator
                    HStack(spacing: 2) {
                        Button { showsText.toggle() } label: {
                            Label("文字", systemImage: "text.alignleft").font(.system(size: 11, weight: .medium)).frame(width: 52, height: 30)
                        }.buttonStyle(CaptureToolbarButtonStyle(selected: showsText))
                            .disabled(state.textBlocks.isEmpty)
                            .help("查看完整译文和原文，复制文字")
                            .popover(isPresented: $showsText, arrowEdge: .bottom) {
                                CaptureTranscript(state: state) { action("copyText") }
                            }
                        iconButton(state.pinned ? "pin.fill" : "pin", state.pinned ? "取消钉住" : "钉住图片", "pin", selected: state.pinned)
                        moreMenu
                        Button { action("copy") } label: {
                            Label(state.copyCompleted ? "已复制" : "复制", systemImage: state.copyCompleted ? "checkmark" : "doc.on.doc")
                                .font(.system(size: 11, weight: .semibold)).frame(minWidth: 44)
                        }.buttonStyle(.borderedProminent).controlSize(.regular)
                            .help(state.shortcuts.help("复制图片", .copy))
                        iconButton("xmark", state.shortcuts.help("关闭", .close), "close")
                    }
                }.padding(.horizontal, 10).padding(.vertical, 7).frame(width: toolbarWidth)

                Rectangle().fill(CaptureAppearance.foreground.opacity(0.08)).frame(height: 0.5).padding(.horizontal, 10)
                HStack(alignment: .top, spacing: 12) {
                    languageMenu
                    Spacer(minLength: 0)
                    HStack(alignment: .top, spacing: 4) {
                        if state.failed || state.noText || state.warning != nil {
                            Image(systemName: state.failed ? "exclamationmark.circle" : "info.circle")
                        }
                        Text(state.warning ?? (state.status.isEmpty ? "拖动图片移动 · 拖动边缘调整范围 · 选择工具标注" : state.status))
                            .lineLimit(3).fixedSize(horizontal: false, vertical: true)
                    }.font(.system(size: 11))
                        .foregroundStyle(state.failed ? Color.red : state.warning != nil ? Color.orange : CaptureAppearance.secondary)
                        .multilineTextAlignment(.leading)
                        .textSelection(.enabled)
                }.padding(.horizontal, 12).padding(.vertical, 8).frame(width: toolbarWidth)

                if showsInspector {
                    Rectangle().fill(CaptureAppearance.foreground.opacity(0.08)).frame(height: 0.5).padding(.horizontal, 10)
                    inspector
                        .transition(.opacity)
                }
        }
        .modifier(CaptureSurface(radius: 10))
        .padding(8)
        .fixedSize()
        .allowsHitTesting(!state.finishing)
        .animation(reduceMotion ? nil : CaptureAppearance.quick, value: showsInspector)
        .animation(reduceMotion ? nil : CaptureAppearance.quick, value: state.copyCompleted)
        .onChange(of: state.annotating) { _, _ in action("layout") }
        .onChange(of: state.annotations.selectedID) { _, _ in showsStyle = false; action("layout") }
        .onChange(of: state.requestsNumberEdit) { _, requested in
            if requested { showsStyle = true; state.requestsNumberEdit = false }
        }
        .onChange(of: state.annotations.tool) { _, _ in action("layout") }
        .onChange(of: state.translated) { _, _ in action("layout") }
        .onChange(of: state.working) { _, _ in action("layout") }
        .onChange(of: state.status) { _, _ in action("layout") }
        .onChange(of: state.warning) { _, _ in action("layout") }
    }

    private var languageMenu: some View {
        Menu {
            Section("原文语言") {
                Button { action("source.auto") } label: {
                    Label("自动识别", systemImage: state.detectsSource ? "checkmark" : "globe")
                }
                ForEach(AppLanguage.allCases) { language in
                    Button { action("source." + language.rawValue) } label: {
                        if !state.detectsSource && state.source == language { Label(language.displayName, systemImage: "checkmark") }
                        else { Text(language.displayName) }
                    }
                }
            }
            Section("译文语言") {
                ForEach(AppLanguage.allCases) { language in
                    Button { action("target." + language.rawValue) } label: {
                        if state.target == language { Label(language.displayName, systemImage: "checkmark") }
                        else { Text(language.displayName) }
                    }
                }
            }
            Divider()
            Button("交换语言") { action("direction") }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "globe")
                Text(state.detectsSource && state.textBlocks.isEmpty ? "自动 → \(state.target.shortName)" : state.direction)
            }.font(.system(size: 11, weight: .medium))
        }.menuStyle(.borderlessButton).fixedSize().help("更改原文或译文语言")
    }

    private var separator: some View {
        Rectangle().fill(CaptureAppearance.foreground.opacity(0.13)).frame(width: 1, height: 16)
    }

    @ViewBuilder private var comparison: some View {
        if state.failed || state.noText {
            Button { action("translate") } label: {
                Label("重试", systemImage: "arrow.clockwise").font(.system(size: 12, weight: .medium))
                    .frame(width: 84, height: 30)
            }.buttonStyle(CaptureToolbarButtonStyle()).help(state.status)
        } else if state.working {
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text("翻译中").font(.system(size: 11))
            }.frame(width: 84, height: 30).help(state.status)
        } else if state.translated {
            HStack(spacing: 4) {
                compareButton("原文", selected: !state.showingTranslation, id: "original")
                compareButton("译文", selected: state.showingTranslation, id: "translation")
            }.help(state.shortcuts.help("切换原文 / 译文", .compare) + "；" + state.shortcuts.help("按住看原文", .peek))
        } else {
            Button { action("translate") } label: {
                Label("翻译", systemImage: "translate").font(.system(size: 12, weight: .medium))
                    .frame(width: 84, height: 30)
            }.buttonStyle(CaptureToolbarButtonStyle()).help(state.shortcuts.help("翻译选中区域", .translate))
        }
    }

    private func compareButton(_ label: String, selected: Bool, id: String) -> some View {
        Button { animate { action(id) } } label: {
            Text(label).font(.system(size: 11, weight: selected ? .semibold : .regular))
                .frame(width: 40, height: 30)
        }.buttonStyle(CaptureToolbarButtonStyle(selected: selected, neutralSelection: true))
            .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var inspector: some View {
        HStack(spacing: 10) {
            HStack(spacing: 4) {
                ForEach(Array(colors.enumerated()), id: \.offset) { index, color in
                    Button { state.annotations.color = color } label: {
                        Circle().fill(Color(nsColor: color)).frame(width: 12, height: 12)
                            .overlay(Circle().strokeBorder(CaptureAppearance.foreground.opacity(0.2), lineWidth: 0.5))
                            .padding(3)
                            .overlay(Circle().strokeBorder(state.annotations.color == color ? Color(nsColor: color) : .clear, lineWidth: 1))
                            .frame(width: 24, height: 28)
                    }.buttonStyle(.plain).accessibilityLabel(["红色", "橙色", "黄色", "绿色", "蓝色", "白色"][index])
                }
            }
            separator
            if let number = state.annotations.selected?.number {
                Button { showsStyle = true } label: {
                    Label("编号 \(number)", systemImage: "pencil").font(.system(size: 11)).frame(width: 92, height: 28)
                }.buttonStyle(CaptureToolbarButtonStyle()).help("修改编号数字").accessibilityLabel("修改编号数字")
            } else {
            HStack(spacing: 4) {
                ForEach([CGFloat(2), 4, 8], id: \.self) { width in
                    Button { state.annotations.width = width } label: {
                        Capsule().fill(CaptureAppearance.foreground).frame(width: 15, height: width / 2)
                            .frame(width: 28, height: 28)
                    }.buttonStyle(CaptureToolbarButtonStyle(selected: state.annotations.width == width, neutralSelection: true))
                        .help(effectiveTool == .number ? "编号大小：\(Int(width))" : "线宽：\(Int(width))")
                        .accessibilityLabel(effectiveTool == .number ? "编号大小 \(Int(width))" : "线宽 \(Int(width))")
                }
            }
            }
            Button { showsStyle.toggle() } label: { icon("slider.horizontal.3") }
                .buttonStyle(CaptureToolbarButtonStyle())
                .help("自定义颜色与粗细").accessibilityLabel("自定义颜色与粗细")
                .popover(isPresented: $showsStyle, arrowEdge: .bottom) { stylePicker }
            Spacer(minLength: 0)
            HStack(spacing: 4) {
                iconButton("arrow.uturn.backward", state.shortcuts.help("撤销", .undo), "undo").disabled(!state.annotations.canUndo)
                iconButton("arrow.uturn.forward", state.shortcuts.help("重做", .redo), "redo").disabled(!state.annotations.canRedo)
                iconButton("trash", "删除选中标注（Delete）", "delete").disabled(state.annotations.selectedID == nil)
            }
        }.padding(.horizontal, 10).padding(.vertical, 4).frame(width: toolbarWidth)
    }

    private var stylePicker: some View {
        VStack(alignment: .leading, spacing: 14) {
            if state.annotations.selected?.tool == .number {
                HStack {
                    Text("编号").font(.system(size: 12))
                    TextField("编号", value: Binding(get: { state.annotations.selected?.number ?? 1 }, set: { state.annotations.setSelectedNumber($0) }), format: .number.grouping(.never))
                        .textFieldStyle(.roundedBorder).focused($numberFocused).frame(width: 65).help("编号范围：1–9999")
                        .onAppear { numberFocused = true }
                    Stepper("编号", value: Binding(get: { state.annotations.selected?.number ?? 1 }, set: { state.annotations.setSelectedNumber($0) }), in: 1...9999)
                        .labelsHidden()
                }
            }
            ColorPicker("颜色", selection: Binding(get: { Color(nsColor: state.annotations.color) }, set: { state.annotations.color = NSColor($0) }))
            HStack(spacing: 10) {
                Text(effectiveTool == .number ? "大小" : "粗细").font(.system(size: 12))
                Slider(value: Binding(get: { Double(state.annotations.width) }, set: { state.annotations.width = CGFloat($0) }), in: 1...10, step: 1, onEditingChanged: { editing in
                        if editing { state.annotations.beginEdit() } else { state.annotations.commitEdit() }
                    })
                    .controlSize(.small).accessibilityLabel(effectiveTool == .number ? "编号大小" : "线宽")
            }
        }.padding(16).frame(width: 240).onDisappear { state.annotations.commitEdit() }
    }

    private var moreMenu: some View {
        Menu {
            Button("保存图片…", systemImage: "square.and.arrow.down") { action("save") }
            Button("重新框选", systemImage: "viewfinder") { action("reselect") }
            Divider()
            Button("撤销", systemImage: "arrow.uturn.backward") { action("undo") }.disabled(!state.annotations.canUndo)
            Button("重做", systemImage: "arrow.uturn.forward") { action("redo") }.disabled(!state.annotations.canRedo)
            Button("删除选中标注", systemImage: "trash") { action("delete") }.disabled(state.annotations.selectedID == nil)
            if state.annotations.selected?.tool == .number {
                Button("修改编号…", systemImage: "number") { showsStyle = true }
            }
            Divider()
            Button("交换语言 · \(state.direction)", systemImage: "arrow.left.arrow.right") { action("direction") }
            Button("重新翻译", systemImage: "arrow.clockwise") { action("translate") }.disabled(state.working)
        } label: { icon("ellipsis") }
            .menuIndicator(.hidden).menuStyle(.borderlessButton).fixedSize().frame(width: 28, height: 30)
            .tint(CaptureAppearance.foreground)
            .help("保存与更多操作").accessibilityLabel("更多操作")
    }

    private func icon(_ name: String) -> some View {
        Image(systemName: name).font(.system(size: 14, weight: .regular)).frame(width: 28, height: 30)
            .contentShape(RoundedRectangle(cornerRadius: 6))
    }
    private func iconButton(_ symbol: String, _ help: String, _ id: String, selected: Bool = false) -> some View {
        Button { action(id) } label: { icon(symbol) }
            .buttonStyle(CaptureToolbarButtonStyle(selected: selected))
            .help(help).accessibilityLabel(help)
    }
    private func animate(_ body: () -> Void) {
        withAnimation(reduceMotion ? nil : CaptureAppearance.quick, body)
    }
}
