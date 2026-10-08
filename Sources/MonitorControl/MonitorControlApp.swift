import DDC
import SwiftUI

@main
struct MonitorControlApp: App {
    @StateObject private var model = Model()

    var body: some Scene {
        MenuBarExtra {
            Panel().environmentObject(model)
        } label: {
            Image(systemName: "sun.max")
        }
        .menuBarExtraStyle(.window)
    }
}

struct Panel: View {
    @EnvironmentObject var model: Model

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if model.monitors.isEmpty {
                Text("No external DDC monitors found").foregroundStyle(.secondary)
            }
            ForEach(model.monitors) { MonitorRow(monitor: $0) }

            if model.permission == .denied {
                Button("Grant System Audio Recording…") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture")!)
                }
                .font(.caption)
            }

            Divider()
            Toggle("Link monitors", isOn: $model.linked)
            Toggle("Launch at login", isOn: $model.launchAtLogin)
            HStack {
                Button("Rescan") { model.reload() }
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
            }
        }
        .toggleStyle(.switch)
        .controlSize(.small)
        .padding(14)
        .frame(width: 300)
        .onAppear { model.refreshBrightness() }
    }
}

struct MonitorRow: View {
    @EnvironmentObject var model: Model
    @ObservedObject var monitor: Monitor

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(monitor.title).font(.headline)

            HStack {
                Image(systemName: "sun.max.fill").frame(width: 20)
                Slider(value: Binding(get: { monitor.brightness },
                                      set: { model.setBrightness($0, from: monitor) }), in: 0...100)
                Text("\(Int(monitor.brightness))").monospacedDigit().frame(width: 28, alignment: .trailing)
            }

            if monitor.hasAudio {
                HStack {
                    Button { model.toggleMute(monitor) } label: {
                        Image(systemName: speakerIcon).frame(width: 20)
                    }
                    .buttonStyle(.plain)
                    Slider(value: Binding(get: { monitor.muted ? 0 : monitor.volume },
                                          set: { model.setVolume($0, from: monitor) }), in: 0...100)
                    Text(monitor.muted ? "–" : "\(Int(monitor.volume))")
                        .monospacedDigit().frame(width: 28, alignment: .trailing)
                }
            }
            if let err = monitor.audioError {
                Text(err).font(.caption).foregroundStyle(.red)
            }
        }
    }

    private var speakerIcon: String {
        if monitor.muted || monitor.volume == 0 { return "speaker.slash.fill" }
        return monitor.volume < 34 ? "speaker.wave.1.fill" : monitor.volume < 67 ? "speaker.wave.2.fill" : "speaker.wave.3.fill"
    }
}
