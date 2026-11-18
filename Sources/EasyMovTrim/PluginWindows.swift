import SwiftUI
import AppKit
import AVFoundation
import CoreAudioKit

/// Opens Audio Unit editor windows (custom plugin UI, or a generic parameter view).
final class PluginWindowManager: NSObject, NSWindowDelegate {
    static let shared = PluginWindowManager()

    private var windows: [UUID: NSWindow] = [:]

    func show(slot: EffectSlot) {
        if let window = windows[slot.id] {
            window.makeKeyAndOrderFront(nil)
            return
        }
        slot.au.requestViewController { [weak self] viewController in
            DispatchQueue.main.async {
                self?.present(slot: slot, custom: viewController)
            }
        }
    }

    private func present(slot: EffectSlot, custom: NSViewController?) {
        guard windows[slot.id] == nil else { return }
        let controller: NSViewController
        if let custom {
            controller = custom
            if controller.view.frame.size.width < 10 || controller.view.frame.size.height < 10 {
                let preferred = controller.preferredContentSize
                controller.view.setFrameSize(preferred.width > 10 ? preferred : NSSize(width: 480, height: 320))
            }
        } else {
            controller = NSHostingController(rootView: GenericAUView(au: slot.au, title: slot.name))
        }
        let window = NSWindow(contentViewController: controller)
        window.title = "\(slot.name) — \(slot.manufacturer)"
        window.styleMask.insert(.closable)
        window.styleMask.insert(.miniaturizable)
        if custom == nil { window.styleMask.insert(.resizable) }
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.level = .floating
        window.center()
        window.makeKeyAndOrderFront(nil)
        windows[slot.id] = window
    }

    func close(slotID: UUID) {
        if let window = windows.removeValue(forKey: slotID) {
            window.delegate = nil
            window.close()
        }
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        if let key = windows.first(where: { $0.value === window })?.key {
            windows.removeValue(forKey: key)
        }
    }
}

// MARK: - Generic parameter editor

struct GenericAUView: View {
    let au: AUAudioUnit
    let title: String
    @State private var presetIndex: Int = -1

    private var parameters: [AUParameter] {
        (au.parameterTree?.allParameters ?? []).filter { $0.flags.contains(.flag_IsWritable) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(title).font(.headline)
                Spacer()
                if let presets = au.factoryPresets, !presets.isEmpty {
                    Picker("プリセット", selection: $presetIndex) {
                        Text("—").tag(-1)
                        ForEach(Array(presets.enumerated()), id: \.offset) { idx, preset in
                            Text(preset.name).tag(idx)
                        }
                    }
                    .frame(maxWidth: 240)
                    .onChange(of: presetIndex) { _, idx in
                        if idx >= 0, idx < presets.count {
                            au.currentPreset = presets[idx]
                        }
                    }
                }
            }
            Divider()
            if parameters.isEmpty {
                Text("編集できるパラメーターはありません。")
                    .foregroundStyle(.secondary)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(parameters, id: \.address) { param in
                            ParameterRow(parameter: param)
                                .id("\(param.address)-\(presetIndex)")
                        }
                    }
                    .padding(.trailing, 8)
                }
            }
        }
        .padding(16)
        .frame(minWidth: 460, idealWidth: 520, minHeight: 160, idealHeight: min(CGFloat(parameters.count) * 34 + 90, 560))
    }
}

private struct ParameterRow: View {
    let parameter: AUParameter
    @State private var value: AUValue

    init(parameter: AUParameter) {
        self.parameter = parameter
        _value = State(initialValue: parameter.value)
    }

    var body: some View {
        HStack(spacing: 10) {
            Text(parameter.displayName)
                .lineLimit(1)
                .frame(width: 150, alignment: .leading)
                .help(parameter.displayName)
            control
        }
        .onChange(of: value) { _, newValue in
            parameter.setValue(newValue, originator: nil)
        }
    }

    @ViewBuilder
    private var control: some View {
        if let strings = parameter.valueStrings, !strings.isEmpty {
            Picker("", selection: Binding(
                get: { Int(value.rounded()) },
                set: { value = AUValue($0) }
            )) {
                ForEach(Array(strings.enumerated()), id: \.offset) { idx, s in
                    Text(s).tag(Int(parameter.minValue) + idx)
                }
            }
            .labelsHidden()
        } else if parameter.unit == .boolean {
            Toggle("", isOn: Binding(get: { value >= 0.5 }, set: { value = $0 ? 1 : 0 }))
                .labelsHidden()
            Spacer()
        } else if parameter.maxValue > parameter.minValue {
            Slider(value: $value, in: parameter.minValue...parameter.maxValue)
            Text(displayString)
                .monospacedDigit()
                .font(.caption)
                .frame(width: 90, alignment: .trailing)
        } else {
            Text(displayString).foregroundStyle(.secondary)
        }
    }

    private var displayString: String {
        var v = value
        let s = parameter.string(fromValue: &v)
        if let unit = parameter.unitName, !unit.isEmpty {
            return "\(s) \(unit)"
        }
        return s
    }
}
