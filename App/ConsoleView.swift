import SwiftUI
import UIKit

struct ConsoleView: View {
    @ObservedObject var scale: ScaleController
    @ObservedObject var recorder: ConsoleRecorder
    @State private var filter = "全部"
    @State private var marker = ""
    @State private var share: ExportFiles?
    @State private var message: String?
    @State private var showsNormalSync = false
    private let filters = ["全部", "接收", "连接", "测量"]

    var body: some View {
        List {
            Section("采集会话") {
                Text(scale.status)
                Text(recorder.isRecording ? "正在保存 · \(recorder.total) 条事件" : "采集已停止")
                    .foregroundStyle(recorder.isRecording ? .green : .secondary)
                if let error = recorder.errorMessage { Text(error).foregroundStyle(.red) }
                HStack {
                    Button(recorder.isRecording ? "新建会话" : "开始采集") { scale.startCapture() }
                    Spacer()
                    Button("停止") { scale.stopCapture() }.disabled(!recorder.isRecording)
                }
                if let url = recorder.activeURL {
                    NavigationLink("本次测量与标注") { CaptureDetailView(url: url, recorder: recorder) }
                    Button("导出本次日志") { export(url) }
                }
                HStack {
                    TextField("事件标记，例如：赤脚、修改秤内身高", text: $marker)
                    Button("标记") {
                        recorder.log("user.marker", ["note": marker])
                        marker = ""
                    }.disabled(marker.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !recorder.isRecording)
                }
                Text("关闭阿福 App，先填主页个人参数，再开始新会话。收到最终包后保持连接约 15 秒。切换到阿福 App 测量前先停止采集以释放连接。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("实时控制台（最近 300 条）") {
                Picker("筛选", selection: $filter) {
                    ForEach(filters, id: \.self) { Text($0) }
                }.pickerStyle(.segmented)
                ForEach(filteredEvents.reversed()) { event in
                    NavigationLink { EventDetailView(event: event) } label: { EventRow(event: event) }
                }
                Text("文件保留全部事件，不受屏幕 300 条限制。UUID、通知、读取、错误和无法解析的原始字节均记录。CoreBluetooth 不提供空中链路的全部底层包，也无法监听阿福 App。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("历史会话（重启后仍保留）") {
                ForEach(recorder.sessions, id: \.self) { url in
                    NavigationLink { CaptureDetailView(url: url, recorder: recorder) } label: {
                        Text(url.deletingPathExtension().lastPathComponent).font(.caption.monospaced())
                    }
                }
            }
            Section {
                Button("切换为体重 / BMI 同步模式") { showsNormalSync = true }
                Text("诊断模式不自动写健康。本版暂不写入体脂率，待日志验证协议或算法后再启用。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("蓝牙控制台")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $share) { ShareFilesView(urls: $0.urls) }
        .alert("导出失败", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("确定") { message = nil }
        } message: { Text(message ?? "") }
        .confirmationDialog("停止采集并启用体重 / BMI 同步？", isPresented: $showsNormalSync, titleVisibility: .visible) {
            Button("切换同步模式") { scale.enableNormalSync() }
        }
    }
    private var filteredEvents: [CaptureEvent] {
        recorder.events.filter { event in
            switch filter {
            case "接收": return event.kind.contains(".rx") || event.kind == "advertisement"
            case "连接": return event.kind.hasPrefix("connection") || event.kind.hasPrefix("bluetooth") || event.kind.hasPrefix("scan")
            case "测量": return event.kind.hasPrefix("measurement") || event.kind == "annotation" || event.kind == "user.marker"
            default: return true
            }
        }
    }
    private func export(_ url: URL) {
        do { share = ExportFiles(urls: try recorder.export(url)) }
        catch { message = error.localizedDescription }
    }
}

struct EventRow: View {
    let event: CaptureEvent
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("#\(event.sequence) \(event.kind)").font(.caption.monospaced()).foregroundStyle(.blue)
            Text(event.timestamp).font(.caption2.monospaced()).foregroundStyle(.secondary)
            if let hex = event.fields["hex"], !hex.isEmpty { Text(hex).font(.caption.monospaced()).lineLimit(2) }
            if let error = event.fields["error"], !error.isEmpty { Text(error).font(.caption).foregroundStyle(.red) }
        }
    }
}
struct EventDetailView: View {
    let event: CaptureEvent
    var body: some View {
        List {
            Section { EventRow(event: event); Text("uptime: \(event.uptime)").font(.caption.monospaced()) }
            ForEach(event.fields.keys.sorted(), id: \.self) { key in
                VStack(alignment: .leading, spacing: 6) {
                    Text(key).font(.caption).foregroundStyle(.secondary)
                    Text(event.fields[key] ?? "").font(.caption.monospaced()).textSelection(.enabled)
                }
            }
            if let hex = event.fields["hex"], !hex.isEmpty {
                Section("字节偏移（十进制，从 0 开始）") {
                    Text(hex.split(separator: " ").enumerated().map { "\($0.offset): \($0.element)" }.joined(separator: "\n"))
                        .font(.caption.monospaced()).textSelection(.enabled)
                }
            }
        }.navigationTitle("事件 #\(event.sequence)")
    }
}

struct CaptureDetailView: View {
    let url: URL
    @ObservedObject var recorder: ConsoleRecorder
    @State private var snapshot = CaptureSnapshot(events: [], damagedLines: 0)
    @State private var message: String?
    @State private var share: ExportFiles?
    var body: some View {
        List {
            Section("会话文件") {
                Text(url.lastPathComponent).font(.caption.monospaced()).textSelection(.enabled)
                Text("\(snapshot.events.count) 条事件 · \(snapshot.measurements.count) 个最终包")
                if snapshot.damagedLines > 0 {
                    Text("发现 \(snapshot.damagedLines) 个不完整行。可导出原始文件；请新建会话继续采集。")
                        .foregroundStyle(.orange)
                }
                Button("刷新") { reload() }
                Button("导出 JSONL + 可读摘要") {
                    do { share = ExportFiles(urls: try recorder.export(url)) }
                    catch { message = error.localizedDescription }
                }
            }
            Section("最终包 · 选择对应测量标注") {
                if snapshot.measurements.isEmpty { Text("尚未收到最终包。先完成一次赤脚测量，再点击刷新。") }
                ForEach(snapshot.measurements.reversed()) { event in
                    NavigationLink {
                        MeasurementAnnotationView(url: url, measurement: event,
                            saved: snapshot.annotation(for: event.sequence), recorder: recorder)
                    } label: {
                        VStack(alignment: .leading, spacing: 5) {
                            Text("#\(event.sequence) · \(event.fields["weightKg"] ?? "—") kg")
                            Text("A=\(event.fields["candidateA"] ?? "—") B=\(event.fields["candidateB"] ?? "—") · \(event.timestamp)")
                                .font(.caption.monospaced()).foregroundStyle(.secondary)
                            if !snapshot.annotation(for: event.sequence).isEmpty { Text("已标注").font(.caption).foregroundStyle(.green) }
                        }
                    }
                }
                Text("重复最终包会分别保留。标注选择你实际观察到的那一个，并在备注写明阿福数值是否来自另一次测量。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("最近 300 条事件 · 完整内容见导出") {
                ForEach(Array(snapshot.events.suffix(300).reversed())) { event in
                    NavigationLink { EventDetailView(event: event) } label: { EventRow(event: event) }
                }
            }
        }
        .navigationTitle("会话详情")
        .onAppear { reload() }
        .onChange(of: recorder.measurementRevision) { _, _ in if url == recorder.activeURL { reload() } }
        .sheet(item: $share) { ShareFilesView(urls: $0.urls) }
        .alert("日志操作失败", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("确定") { message = nil }
        } message: { Text(message ?? "") }
    }
    private func reload() {
        do { snapshot = try CaptureJournal.read(url) }
        catch { message = error.localizedDescription }
    }
}

struct MeasurementAnnotationView: View {
    let url: URL
    let measurement: CaptureEvent
    let saved: [String: String]
    @ObservedObject var recorder: ConsoleRecorder
    @State private var scaleFat = ""
    @State private var officialFat = ""
    @State private var officialWeight = ""
    @State private var officialProfile = ""
    @State private var scaleProfile = "未知"
    @State private var participant = ""
    @State private var appVersion = ""
    @State private var notes = ""
    @State private var message: String?
    @State private var loaded = false
    var body: some View {
        Form {
            Section("测量 #\(measurement.sequence)") {
                Text("\(measurement.fields["weightKg"] ?? "—") kg · A=\(measurement.fields["candidateA"] ?? "—") · B=\(measurement.fields["candidateB"] ?? "—")")
                Text(measurement.timestamp).font(.caption.monospaced())
                Text("本地参数：\(measurement.fields["heightCm"] ?? "—") cm / \(measurement.fields["age"] ?? "—") 岁 / \(measurement.fields["sex"] ?? "—")")
                    .font(.caption)
                NavigationLink("查看原始测量包") { EventDetailView(event: measurement) }
            }
            Section("人工对照值（可留空）") {
                TextField("秤面体脂率 %", text: $scaleFat).keyboardType(.decimalPad)
                TextField("阿福 App 体脂率 %", text: $officialFat).keyboardType(.decimalPad)
                TextField("阿福 App 对应体重 kg", text: $officialWeight).keyboardType(.decimalPad)
                TextField("阿福 App 版本 / 设备固件版本", text: $appVersion)
                TextField("样本代号，例如 A（无需真实姓名）", text: $participant)
            }
            Section("资料与实验条件") {
                TextField("阿福资料：身高、年龄、性别、运动员模式", text: $officialProfile, axis: .vertical)
                TextField("秤内用户资料；不知道请保留未知", text: $scaleProfile, axis: .vertical)
                TextField("备注：赤脚/袜子、时间差、是否另一次测量", text: $notes, axis: .vertical)
                Text("原始候选 A/B 未确认是欧姆值。仅靠复现厂商数值不能证明体脂率更准确。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section {
                Button("保存标注") { save() }
                Text("标注追加到日志并绑定本会话的测量编号；修改标注保留先前版本。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("测量标注")
        .onAppear {
            guard !loaded else { return }; loaded = true
            scaleFat = saved["scaleFatPercent"] ?? ""
            officialFat = saved["officialFatPercent"] ?? ""
            officialWeight = saved["officialWeightKg"] ?? ""
            officialProfile = saved["officialProfile"] ?? ""
            scaleProfile = saved["scaleStoredProfile"] ?? "未知"
            participant = saved["participantCode"] ?? ""
            appVersion = saved["officialAppVersion"] ?? ""
            notes = saved["notes"] ?? ""
        }
        .alert("标注", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("确定") { message = nil }
        } message: { Text(message ?? "") }
    }
    private func save() {
        func clean(_ value: String) -> String { value.trimmingCharacters(in: .whitespacesAndNewlines) }
        do {
            try recorder.annotate(url: url, sequence: measurement.sequence, fields: [
                "scaleFatPercent": clean(scaleFat), "officialFatPercent": clean(officialFat),
                "officialWeightKg": clean(officialWeight), "officialProfile": officialProfile,
                "scaleStoredProfile": scaleProfile, "participantCode": participant,
                "officialAppVersion": appVersion, "notes": notes, "source": "manual"])
            message = "已保存，可返回会话导出日志。"
        } catch { message = error.localizedDescription }
    }
}

struct ExportFiles: Identifiable {
    let id = UUID()
    let urls: [URL]
}
struct ShareFilesView: UIViewControllerRepresentable {
    let urls: [URL]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: urls, applicationActivities: nil)
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
