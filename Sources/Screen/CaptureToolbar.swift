import SwiftUI
import AppKit

struct CaptureToolbar: View {
    @Bindable var state: CaptureState
    var action: (String) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showsStyle = false
    @State private var showsText = false
    @FocusState private var numberFocused: Bool
    private let colors: [NSColor] = [.systemRed, .systemOrange, .systemYellow, .systemGreen, .systemBlue, .white, .black]
    private let toolbarWidth: CGFloat = 452
    private var showsInspector: Bool { state.annotations.selectedID != nil || (state.annotating && state.annotations.tool != .move) }
    private var effectiveTool: AnnotationTool { state.annotations.selected?.tool ?? state.annotations.tool }
    /// Something the reader must see in full: a failure, or a translation that did not fit.
    private var problem: String? { state.failed ? state.status : state.warning }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                comparison
                languageMenu
                Spacer(minLength: 0)
                HStack(spacing: 2) {
                    if !state.textBlocks.isEmpty {
                        iconButton("text.alignleft", L("查看完整译文和原文，复制文字"), selected: showsText) { showsText.toggle() }
                            .popover(isPresented: $showsText, arrowEdge: .bottom) {
                                CaptureTranscript(state: state) { action("copyText") }
                            }
                            .transition(.opacity)
                    }
                    iconButton("pin", state.pendingOutput == "pin" ? L("翻译完成后钉到屏幕") : state.shortcuts.help(L("钉到屏幕上，可继续截图"), .pin),
                               selected: state.pendingOutput == "pin") { action("pin") }
                    moreMenu
                    copyButton.padding(.horizontal, 2)
                    iconButton("xmark", state.shortcuts.help(L("关闭"), .close)) { action("close") }
                }
            }.padding(.horizontal, 8).padding(.top, 8).padding(.bottom, 2)

            HStack(spacing: 8) {
                tools
                Spacer(minLength: 8)
                statusLine
            }.padding(.horizontal, 8).padding(.bottom, 6)

            if let problem {
                divider
                problemRow(problem).transition(.opacity)
            }
            if showsInspector {
                divider
                inspector.transition(.opacity)
            }
        }
        .frame(width: toolbarWidth)
        .modifier(CaptureSurface(radius: 12))
        .padding(8)
        .fixedSize()
        .allowsHitTesting(!state.finishing)
        .animation(reduceMotion ? nil : CaptureAppearance.quick, value: showsInspector)
        .animation(reduceMotion ? nil : CaptureAppearance.quick, value: state.copyCompleted)
        .animation(reduceMotion ? nil : CaptureAppearance.quick, value: state.pendingOutput)
        .animation(reduceMotion ? nil : CaptureAppearance.quick, value: state.textBlocks.isEmpty)
        .animation(reduceMotion ? nil : CaptureAppearance.quick, value: problem)
        .onChange(of: state.annotating) { _, _ in action("layout") }
        .onChange(of: state.annotations.selectedID) { _, _ in showsStyle = false; action("layout") }
        .onChange(of: state.requestsNumberEdit) { _, requested in
            if requested { showsStyle = true; state.requestsNumberEdit = false }
        }
        .onChange(of: state.annotations.tool) { _, _ in action("layout") }
        .onChange(of: state.translated) { _, _ in action("layout") }
        .onChange(of: state.working) { _, _ in action("layout") }
        .onChange(of: problem) { _, _ in action("layout") }
    }

    private var divider: some View {
        Rectangle().fill(CaptureAppearance.foreground.opacity(0.08)).frame(height: 0.5).padding(.horizontal, 10)
    }

    // MARK: Translation

    @ViewBuilder private var comparison: some View {
        Group {
            if state.failed || state.noText {
                slotButton(L("重试"), "arrow.clockwise", state.shortcuts.help(L("翻译选中区域"), .translate)) { action("translate") }
            } else if state.working {
                slotButton(L("暂停"), "pause.fill", state.shortcuts.help(L("暂停翻译"), state.pauseKey)) { action("pause") }
            } else if state.paused {
                slotButton(L("继续"), "play.fill", state.shortcuts.help(L("继续翻译"), state.pauseKey)) { action("pause") }
            } else if state.translated {
                HStack(spacing: 2) {
                    compareButton(L("原文"), selected: !state.showingTranslation, id: "original")
                    compareButton(L("译文"), selected: state.showingTranslation, id: "translation")
                }
                .padding(2)
                .background(CaptureAppearance.foreground.opacity(0.06), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .help(state.shortcuts.help(L("切换原文 / 译文"), .peek))
            } else {
                slotButton(L("翻译"), "translate", state.shortcuts.help(L("翻译选中区域"), .translate)) { action("translate") }
            }
        }
        // One width for every state, so nothing beside it moves when the state changes.
        .frame(width: 92, alignment: .leading)
    }

    private func slotButton(_ title: String, _ symbol: String, _ help: String, _ run: @escaping () -> Void) -> some View {
        Button(action: run) {
            Label(title, systemImage: symbol).font(.system(size: 12, weight: .medium))
                .frame(width: 92, height: 30)
                .background(CaptureAppearance.foreground.opacity(0.06), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }.buttonStyle(CaptureToolbarButtonStyle()).help(help)
    }

    private func compareButton(_ label: String, selected: Bool, id: String) -> some View {
        Button { animate { action(id) } } label: {
            Text(label).font(.system(size: 12, weight: selected ? .semibold : .regular))
                .frame(width: 43, height: 26)
        }.buttonStyle(CaptureSegmentStyle(selected: selected))
            .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var languageMenu: some View {
        Menu {
            Section(L("原文语言")) {
                Button { action("source.auto") } label: {
                    Label(L("自动识别"), systemImage: state.detectsSource ? "checkmark" : "globe")
                }
                ForEach(AppLanguage.allCases) { language in
                    Button { action("source." + language.rawValue) } label: {
                        if !state.detectsSource && state.source == language { Label(language.displayName, systemImage: "checkmark") }
                        else { Text(language.displayName) }
                    }
                }
            }
            Section(L("译文语言")) {
                ForEach(AppLanguage.allCases) { language in
                    Button { action("target." + language.rawValue) } label: {
                        if state.target == language { Label(language.displayName, systemImage: "checkmark") }
                        else { Text(language.displayName) }
                    }
                }
            }
            Divider()
            Button(L("交换语言")) { action("direction") }
        } label: {
            Text(state.detectsSource && state.textBlocks.isEmpty ? L("自动") + " → \(state.target.shortName)" : state.direction)
                .font(.system(size: 12, weight: .medium)).monospacedDigit()
        }
        .menuStyle(.borderlessButton).fixedSize()
        .tint(CaptureAppearance.foreground)
        .help(state.shortcuts.help(L("更改原文或译文语言"), .direction))
    }

    private var statusText: String {
        if let readout = state.cropReadout { return readout }
        switch state.pendingOutput {
        case "copy": return L("翻译完成后复制")
        case "pin": return L("翻译完成后钉到屏幕")
        case "save": return L("翻译完成后保存")
        default: return state.failed ? "" : state.status
        }
    }

    private var statusLine: some View {
        HStack(spacing: 6) {
            if state.working && state.cropReadout == nil { ProgressView().controlSize(.mini) }
            Text(statusText).lineLimit(1).truncationMode(.middle)
        }
        .font(.system(size: 11)).monospacedDigit()
        .foregroundStyle(CaptureAppearance.secondary)
        .help(statusText)
    }

    private func problemRow(_ message: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: state.failed ? "exclamationmark.circle.fill" : "info.circle.fill")
                .foregroundStyle(state.failed ? Color.red : Color.orange)
            Text(message).foregroundStyle(state.failed ? Color.red : CaptureAppearance.foreground)
                .lineLimit(3).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            Spacer(minLength: 0)
            if !state.failed && !state.textBlocks.isEmpty {
                Button(L("查看全文")) { showsText = true }.buttonStyle(.link)
            }
        }
        .font(.system(size: 11))
        .padding(.horizontal, 12).padding(.vertical, 8)
    }

    // MARK: Output

    private var copyButton: some View {
        let pending = state.pendingOutput == "copy"
        return Button { action("copy") } label: {
            HStack(spacing: 5) {
                Image(systemName: state.copyCompleted ? "checkmark" : "doc.on.doc")
                    .symbolEffect(.pulse, isActive: pending && !reduceMotion)
                    .contentTransition(.symbolEffect(.replace))
                Text(state.copyCompleted ? L("已复制") : L("复制"))
            }
            .font(.system(size: 12, weight: .semibold)).frame(minWidth: 54)
        }
        .buttonStyle(.borderedProminent).controlSize(.regular)
        .help(pending ? L("翻译完成后复制") : state.shortcuts.help(L("复制图片"), .copy))
    }

    private var moreMenu: some View {
        Menu {
            Button(L("保存图片…"), systemImage: "square.and.arrow.down") { action("save") }
            Button(L("重新框选"), systemImage: "viewfinder") { action("reselect") }
            if state.scrollable {
                Divider()
                Button(L("放大"), systemImage: "plus.magnifyingglass") { action("zoomIn") }
                Button(L("缩小"), systemImage: "minus.magnifyingglass") { action("zoomOut") }
                Button(L("适合宽度"), systemImage: "arrow.left.and.right") { action("zoomReset") }
            }
            Divider()
            Button(L("撤销"), systemImage: "arrow.uturn.backward") { action("undo") }.disabled(!state.annotations.canUndo)
            Button(L("重做"), systemImage: "arrow.uturn.forward") { action("redo") }.disabled(!state.annotations.canRedo)
            Button(L("删除选中标注"), systemImage: "trash") { action("delete") }.disabled(state.annotations.selectedID == nil)
            if state.annotations.selected?.tool == .text {
                Button(L("编辑文字…"), systemImage: "character.cursor.ibeam") { action("editText") }
            }
            if state.annotations.selected?.tool == .number {
                Button(L("修改编号…"), systemImage: "number") { showsStyle = true }
            }
            Divider()
            Button(L("交换语言") + " · \(state.direction)", systemImage: "arrow.left.arrow.right") { action("direction") }
            Button(L("重新翻译"), systemImage: "arrow.clockwise") { action("translate") }.disabled(state.working)
        } label: { icon("ellipsis") }
            .menuIndicator(.hidden).menuStyle(.borderlessButton).fixedSize().frame(width: 30, height: 30)
            .tint(CaptureAppearance.foreground)
            .help(L("保存与更多操作")).accessibilityLabel(L("更多操作"))
    }

    // MARK: Annotation

    private var tools: some View {
        HStack(spacing: 2) {
            ForEach(AnnotationTool.allCases) { tool in
                Button {
                    animate { action("tool." + (state.annotations.tool == tool ? AnnotationTool.move.rawValue : tool.rawValue)) }
                } label: { icon(tool.symbol) }
                    .buttonStyle(CaptureToolbarButtonStyle(selected: state.annotations.tool == tool && (tool != .move || state.annotations.selectedID != nil)))
                    .help(tool == .number ? L("编号 · 下一个：%ld", state.annotations.nextNumber) : tool.title)
                    .accessibilityLabel(tool.title)
                    .accessibilityAddTraits(state.annotations.tool == tool ? .isSelected : [])
            }
        }
    }

    private var inspector: some View {
        HStack(spacing: 10) {
            if effectiveTool != .redact {
                HStack(spacing: 2) {
                    ForEach(Array(colors.enumerated()), id: \.offset) { index, color in
                        Button { state.annotations.color = color } label: {
                            Circle().fill(Color(nsColor: color)).frame(width: 14, height: 14)
                                .overlay(Circle().strokeBorder(CaptureAppearance.foreground.opacity(0.18), lineWidth: 0.5))
                                .padding(3)
                                .overlay(Circle().strokeBorder(state.annotations.color == color ? CaptureAppearance.foreground.opacity(0.55) : .clear, lineWidth: 1.5))
                                .frame(width: 26, height: 28)
                                .contentShape(Rectangle())
                        }.buttonStyle(.plain).accessibilityLabel([L("红色"), L("橙色"), L("黄色"), L("绿色"), L("蓝色"), L("白色"), L("黑色")][index])
                            .accessibilityAddTraits(state.annotations.color == color ? .isSelected : [])
                    }
                }
                separator
                if effectiveTool == .text {
                    if state.annotations.selected?.tool == .text {
                        iconButton("character.cursor.ibeam", L("编辑文字")) { action("editText") }
                    }
                } else if let number = state.annotations.selected?.number {
                    Button { showsStyle = true } label: {
                        Text("\(number)").font(.system(size: 12, weight: .semibold)).monospacedDigit().frame(minWidth: 30, minHeight: 28)
                    }.buttonStyle(CaptureToolbarButtonStyle()).help(L("修改编号数字")).accessibilityLabel(L("修改编号数字"))
                } else {
                    HStack(spacing: 2) {
                        ForEach([CGFloat(2), 4, 8], id: \.self) { width in
                            Button { state.annotations.width = width } label: {
                                Capsule().fill(CaptureAppearance.foreground).frame(width: 15, height: width / 2)
                                    .frame(width: 28, height: 28)
                            }.buttonStyle(CaptureToolbarButtonStyle(selected: state.annotations.width == width, neutralSelection: true))
                                .help(effectiveTool == .number ? L("编号大小：%ld", Int(width)) : L("线宽：%ld", Int(width)))
                                .accessibilityLabel(effectiveTool == .number ? L("编号大小：%ld", Int(width)) : L("线宽：%ld", Int(width)))
                        }
                    }
                }
                iconButton("slider.horizontal.3", L("自定义颜色与粗细")) { showsStyle.toggle() }
                    .popover(isPresented: $showsStyle, arrowEdge: .bottom) { stylePicker }
            }
            Spacer(minLength: 0)
            HStack(spacing: 2) {
                iconButton("arrow.uturn.backward", state.shortcuts.help(L("撤销"), .undo)) { action("undo") }.disabled(!state.annotations.canUndo)
                iconButton("arrow.uturn.forward", state.shortcuts.help(L("重做"), .redo)) { action("redo") }.disabled(!state.annotations.canRedo)
                iconButton("trash", L("删除选中标注（Delete）")) { action("delete") }.disabled(state.annotations.selectedID == nil)
            }
        }.padding(.horizontal, 8).padding(.vertical, 5)
    }

    private var stylePicker: some View {
        VStack(alignment: .leading, spacing: 14) {
            if state.annotations.selected?.tool == .number {
                HStack {
                    Text(L("编号")).font(.system(size: 12))
                    TextField(L("编号"), value: Binding(get: { state.annotations.selected?.number ?? 1 }, set: { state.annotations.setSelectedNumber($0) }), format: .number.grouping(.never))
                        .textFieldStyle(.roundedBorder).focused($numberFocused).frame(width: 65).help(L("编号范围：1–9999"))
                        .onAppear { numberFocused = true }
                    Stepper(L("编号"), value: Binding(get: { state.annotations.selected?.number ?? 1 }, set: { state.annotations.setSelectedNumber($0) }), in: 1...9999)
                        .labelsHidden()
                }
            }
            ColorPicker(L("颜色"), selection: Binding(get: { Color(nsColor: state.annotations.color) }, set: { state.annotations.color = NSColor($0) }))
            if effectiveTool == .text {
                HStack {
                    Text(L("字号"))
                    Slider(value: Binding(get: { Double(state.annotations.selected?.fontSize ?? state.annotations.fontSize) }, set: {
                        state.annotations.fontSize = CGFloat($0)
                        state.annotations.modifySelected { $0.fontSize = state.annotations.fontSize }
                    }), in: 12...72, step: 1, onEditingChanged: { editing in
                        if editing { state.annotations.beginEdit() } else { state.annotations.commitEdit() }
                    })
                    Text("\(Int(state.annotations.selected?.fontSize ?? state.annotations.fontSize))").monospacedDigit()
                }
            } else {
                HStack(spacing: 10) {
                    Text(effectiveTool == .number ? L("大小") : L("粗细")).font(.system(size: 12))
                    Slider(value: Binding(get: { Double(state.annotations.width) }, set: { state.annotations.width = CGFloat($0) }), in: 1...10, step: 1, onEditingChanged: { editing in
                        if editing { state.annotations.beginEdit() } else { state.annotations.commitEdit() }
                    })
                    .controlSize(.small).accessibilityLabel(effectiveTool == .number ? L("编号大小") : L("线宽"))
                }
            }
        }.padding(16).frame(width: 260).onDisappear { state.annotations.commitEdit() }
    }

    // MARK: Parts

    private var separator: some View {
        Rectangle().fill(CaptureAppearance.foreground.opacity(0.13)).frame(width: 1, height: 16)
    }
    private func icon(_ name: String) -> some View {
        Image(systemName: name).font(.system(size: 14, weight: .regular)).frame(width: 30, height: 30)
            .contentShape(RoundedRectangle(cornerRadius: 7))
    }
    private func iconButton(_ symbol: String, _ help: String, selected: Bool = false, _ run: @escaping () -> Void) -> some View {
        Button(action: run) { icon(symbol) }
            .buttonStyle(CaptureToolbarButtonStyle(selected: selected))
            .help(help).accessibilityLabel(help)
    }
    private func animate(_ body: () -> Void) {
        withAnimation(reduceMotion ? nil : CaptureAppearance.quick, body)
    }
}
