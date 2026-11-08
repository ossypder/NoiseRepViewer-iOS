import SwiftUI

struct ContentView: View {
    @StateObject private var store = BandStore()

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    connectionCard
                    if store.snapshot.clockMayBeUnset {
                        Label("The band clock may be unset. Dates may be inaccurate until it is synced by the vendor app.", systemImage: "clock.badge.exclamationmark")
                            .font(.footnote)
                            .foregroundStyle(.orange)
                            .padding()
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 14))
                    }
                    if !store.snapshot.series.isEmpty {
                        Text("Latest recorded values").font(.title3.bold())
                        metricGrid
                    }
                    if let file = store.snapshot.rriFiles.last {
                        rriCard(file)
                    }
                    if !store.isSyncing && store.snapshot.series.isEmpty && store.snapshot.rriFiles.isEmpty {
                        ContentUnavailableView("No data yet", systemImage: "waveform.path.ecg",
                                               description: Text("Wake the band, turn off Bluetooth on the phone running NoiseFit, then tap Sync band."))
                    }
                    Text("Historical readings are fetched directly over Bluetooth. Metric names other than heart rate are inferred from captured data. Rest is estimated from RRI, not a sleep-stage reading.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.top, 4)
                }
                .padding()
            }
            .navigationTitle("Noise REP")
        }
    }

    private var connectionCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "waveform.path.ecg.rectangle")
                    .font(.title2)
                    .foregroundStyle(.tint)
                VStack(alignment: .leading) {
                    Text(store.snapshot.device?.model ?? "Your band").font(.headline)
                    if let device = store.snapshot.device {
                        Text("Firmware \(device.firmware)").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
            }
            if store.isSyncing { ProgressView() }
            Text(store.progress).font(.subheadline).foregroundStyle(.secondary)
            if let error = store.errorMessage {
                Text(error).font(.footnote).foregroundStyle(.red)
            }
            Button {
                Task { await store.sync() }
            } label: {
                Label(store.isSyncing ? "Syncing…" : "Sync band", systemImage: "arrow.triangle.2.circlepath")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(store.isSyncing)
        }
        .padding()
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
    }

    private var metricGrid: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
            metricCard("Heart rate", value: store.snapshot.latestValue(2), unit: "bpm", symbol: "heart.fill", note: "Verified")
            metricCard("Steps", value: store.snapshot.activity?.totals["steps"], unit: "steps", symbol: "figure.walk", note: "Likely")
            metricCard("Distance", value: store.snapshot.activity?.totals["distance"], unit: "m", symbol: "point.bottomleft.forward.to.point.topright.scurvepath", note: "Likely")
            metricCard("Active calories", value: store.snapshot.activity?.totals["calories"], unit: "kcal", symbol: "flame.fill", note: "Likely")
            metricCard("Active minutes", value: store.snapshot.activity?.totals["activeMinutes"], unit: "min", symbol: "timer", note: "Likely")
            metricCard("HRV", value: store.snapshot.latestValue(21), unit: "ms", symbol: "waveform.path", note: "Likely")
            metricCard("Stress", value: store.snapshot.latestValue(22), unit: "/100", symbol: "gauge", note: "Likely")
            metricCard("SpO₂", value: store.snapshot.latestValue(4), unit: "%", symbol: "lungs.fill", note: "Likely")
        }
    }

    private func metricCard(_ title: String, value: Int?, unit: String, symbol: String, note: String) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Image(systemName: symbol).foregroundStyle(.tint)
            Text(title).font(.subheadline).foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value.map(String.init) ?? "—").font(.title2.bold())
                if value != nil { Text(unit).font(.caption).foregroundStyle(.secondary) }
            }
            Text(note).font(.caption2).foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, minHeight: 105, alignment: .leading)
        .padding()
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
    }

    private func rriCard(_ file: RRIFile) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("RRI and possible rest").font(.title3.bold())
            HStack {
                Label("\(file.validIntervals.count) intervals", systemImage: "waveform.path.ecg")
                Spacer()
                if let bpm = file.averageBPM { Text("~\(bpm) bpm average") }
            }
            .font(.subheadline)
            if let rest = file.possibleRest {
                Text("Possible rest: \(rest.minutes) min")
                    .font(.headline)
                Text("\(rest.start.formatted(date: .abbreviated, time: .shortened)) – \(rest.end.formatted(date: .omitted, time: .shortened))")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                Text("No 30-minute rest window found in this RRI file.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Text("Rest is an estimate from recorded intervals; sleep stages are not available.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
    }
}

