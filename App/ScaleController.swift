import CoreBluetooth
import Foundation

@MainActor
final class ScaleController: NSObject, ObservableObject {
    let console = ConsoleRecorder()
    @Published private(set) var captureMode = true
    private var wantsConnection = true
    @Published var status = "初始化"
    @Published var latest: ScaleMeasurement?
    @Published var latestRawHex = ""
    @Published var lastSavedText = "尚未写入"
    @Published var needsHealthAuthorization = false
    @Published var records: [SavedRecord] = []
    /// 改走快捷指令写入：用户主动选择，或 Health 不可写时自动落到这里。
    @Published var usesShortcut = UserDefaults.standard.bool(forKey: "AFUScale.usesShortcut") {
        didSet { UserDefaults.standard.set(usesShortcut, forKey: "AFUScale.usesShortcut") }
    }
    /// 签名不含 HealthKit entitlement（免费证书侧载）：授权必然报错，锁死在快捷指令，不允许切回。
    @Published var healthUnavailable = UserDefaults.standard.bool(forKey: "AFUScale.healthUnavailable") {
        didSet { UserDefaults.standard.set(healthUnavailable, forKey: "AFUScale.healthUnavailable") }
    }
    /// 已交给快捷指令、等回跳确认的那一条。
    @Published private var pendingRecord: LocalRecord?

    enum WriteTarget: Hashable { case health, shortcut }

    /// 给切换控件用：切到 Health 要先过授权校验，没过就维持快捷指令（控件自动回弹）。
    var writeTarget: WriteTarget {
        get { usesShortcut ? .shortcut : .health }
        set {
            switch newValue {
            case .shortcut: useShortcut()
            case .health: requestHealthAuthorization()
            }
        }
    }

    // ponytail: 快捷指令名写死，用户按这个名字建捷径即可；要改名再加设置项。
    nonisolated static let shortcutName = "AFUScale 写入健康"
    /// 快捷指令跑完通过 x-callback-url 跳回本 App 用的 scheme（同步登记在 Info.plist）。
    nonisolated static let callbackScheme = "afuscale"

    /// 交给「快捷指令」的文本输入为 JSON，捷径里用「从输入获取词典」取值。
    /// fat 是百分数本身（18.70 即 18.70%），快捷指令里直接填入，不要再乘除 100；
    /// 秤没测到阻抗时整个 fat 键不传（空文本在 Shortcuts 里算「有值」，会被当成数字去转而报错），
    /// 捷径里用「如果 词典值 fat 有任何值」包住体脂率那一步。
    nonisolated static func shortcutURL(name: String = shortcutName, weight: Double, bmi: Double, fat: Double?) -> URL? {
        var fields = [String(format: "\"weight\":%.2f", weight), String(format: "\"bmi\":%.2f", bmi)]
        if let fat {
            fields.append(String(format: "\"fat\":%.2f", fat))
        }
        var components = URLComponents(string: "shortcuts://x-callback-url/run-shortcut")
        components?.queryItems = [
            URLQueryItem(name: "name", value: name),
            URLQueryItem(name: "input", value: "text"),
            URLQueryItem(name: "text", value: "{" + fields.joined(separator: ",") + "}"),
            URLQueryItem(name: "x-success", value: "\(callbackScheme)://saved"),
            URLQueryItem(name: "x-error", value: "\(callbackScheme)://failed"),
            URLQueryItem(name: "x-cancel", value: "\(callbackScheme)://cancelled")
        ]
        return components?.url
    }

    /// 处理快捷指令跑完后回跳的 x-callback-url。
    func handleCallback(_ url: URL) {
        guard url.scheme == Self.callbackScheme else { return }
        switch url.host {
        case "saved":
            // 快捷指令写 Health 的结果读不回来，回跳即视为成功，本地存一份用于展示。
            if let pendingRecord {
                localRecords.append(pendingRecord)
                lastSavedText = Self.summary("已写入", pendingRecord.weightKg, pendingRecord.bmi, pendingRecord.bodyFatPercent)
                self.pendingRecord = nil
                loadRecords()
            }
            status = "快捷指令写入完成"
        case "cancelled":
            status = "快捷指令已取消"
        default:
            let message = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first { $0.name == "errorMessage" }?.value
            status = "快捷指令写入失败：\(message ?? "未知错误")"
        }
    }

    /// 待写入那条对应的快捷指令链接；没测过则为 nil。
    var shortcutURL: URL? {
        guard let pendingRecord else { return nil }
        return Self.shortcutURL(weight: pendingRecord.weightKg, bmi: pendingRecord.bmi, fat: pendingRecord.bodyFatPercent)
    }

    /// 快捷指令写入的记录 Health 里读不到，存在本地。
    private struct LocalRecord: Codable {
        let date: Date
        let weightKg: Double
        let bmi: Double
        let bodyFatPercent: Double?
    }

    /// 体脂率可能因缺阻抗而缺失，统一在这里拼文案。
    nonisolated static func summary(_ prefix: String, _ weight: Double, _ bmi: Double, _ fat: Double?) -> String {
        prefix + String(format: "：%.2f kg / BMI %.1f / 体脂 ", weight, bmi)
            + (fat.map { String(format: "%.1f%%", $0) } ?? "—")
    }

    private static let localRecordsKey = "AFUScale.shortcutRecords"
    private var localRecords: [LocalRecord] = [] {
        didSet { UserDefaults.standard.set(try? JSONEncoder().encode(localRecords), forKey: Self.localRecordsKey) }
    }

    private let health = HealthWriter()
    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var lastSavedAt: Date?

    private let targetName = "AFU-WL-TZ-A1"
    private let ffb0 = CBUUID(string: "0000FFB0-0000-1000-8000-00805F9B34FB")
    private let ffb2 = CBUUID(string: "0000FFB2-0000-1000-8000-00805F9B34FB")

    // 本地个人参数只用于 BMI 与日志快照，不会写入秤。
    @Published var heightCm: Double { didSet { UserDefaults.standard.set(heightCm, forKey: "AFUScale.heightCm"); console.log("profile.changed", profileFields) } }
    @Published var age: Int { didSet { UserDefaults.standard.set(age, forKey: "AFUScale.age"); console.log("profile.changed", profileFields) } }
    @Published var sex: Sex = .male {
        didSet { UserDefaults.standard.set(sex.rawValue, forKey: "AFUScale.sex"); console.log("profile.changed", profileFields) }
    }
    var profileFields: [String: String] {
        ["heightCm": String(heightCm), "age": String(age), "sex": sex.rawValue,
         "profileSource": "AFUScale local; scale stored profile unknown"]
    }

    func startCapture() {
        captureMode = true
        latest = nil
        latestRawHex = ""
        wantsConnection = true
        console.start(profile: profileFields)
        // Re-discover the full GATT tree when beginning a fresh session.
        if let peripheral, peripheral.state == .connected {
            console.log("connection.existing", deviceFields(peripheral))
            discover(peripheral)
        } else { startScanningIfReady() }
    }

    func stopCapture() {
        wantsConnection = false
        console.log("scan.stop")
        central.stopScan()
        if let peripheral {
            console.log("connection.cancel", deviceFields(peripheral))
            central.cancelPeripheralConnection(peripheral)
        }
        console.stop()
        status = "采集已停止，日志保留在本机"
    }

    func enableNormalSync() {
        stopCapture()
        captureMode = false
        wantsConnection = true
        requestHealthAuthorization()
        loadRecords()
        startScanningIfReady()
    }

    func lifecycle(_ state: String) { console.log("app.lifecycle", ["state": state]) }

    private func deviceFields(_ device: CBPeripheral) -> [String: String] {
        ["deviceID": device.identifier.uuidString, "deviceName": device.name ?? ""]
    }
    private func characteristicFields(_ device: CBPeripheral, _ ch: CBCharacteristic) -> [String: String] {
        var fields = deviceFields(device)
        fields["serviceUUID"] = ch.service?.uuid.uuidString ?? ""
        fields["characteristicUUID"] = ch.uuid.uuidString
        fields["serviceIndex"] = ch.service.flatMap { svc in device.services?.firstIndex { $0 === svc } }.map(String.init) ?? ""
        fields["characteristicIndex"] = ch.service?.characteristics?.firstIndex { $0 === ch }.map(String.init) ?? ""
        fields["propertiesRaw"] = String(ch.properties.rawValue)
        fields["isNotifying"] = String(ch.isNotifying)
        return fields
    }
    private func discover(_ device: CBPeripheral) {
        console.log("gatt.discoverServices.request", deviceFields(device).merging(["filter": captureMode ? "all" : "FFB0"], uniquingKeysWith: { _, new in new }))
        device.discoverServices(captureMode ? nil : [ffb0])
    }
    private func advFields(_ advertisement: [String: Any]) -> [String: String] {
        advertisement.reduce(into: [:]) { result, item in
            if let data = item.value as? Data { result[item.key] = Self.hex(data) }
            else if let values = item.value as? [CBUUID: Data] {
                result[item.key] = values.keys.sorted { $0.uuidString < $1.uuidString }.map { "\($0.uuidString)=\(Self.hex(values[$0]!))" }.joined(separator: "; ")
            } else if let values = item.value as? [CBUUID] { result[item.key] = values.map(\.uuidString).joined(separator: ",") }
            else { result[item.key] = String(describing: item.value) }
        }
    }
    nonisolated static func hex(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined(separator: " ") }


    override init() {
        let d = UserDefaults.standard
        heightCm = d.object(forKey: "AFUScale.heightCm") as? Double ?? 170.0
        age = d.object(forKey: "AFUScale.age") as? Int ?? 25
        sex = Sex(rawValue: d.string(forKey: "AFUScale.sex") ?? "male") ?? .male
        super.init()
        console.onWriteFailure = { [weak self] in
            guard let self else { return }
            self.wantsConnection = false
            self.central?.stopScan()
            if let device = self.peripheral { self.central?.cancelPeripheralConnection(device) }
            self.status = "日志保存失败，已停止连接；请新建会话重试"
        }
        console.start(profile: profileFields)
        localRecords = d.data(forKey: Self.localRecordsKey)
            .flatMap { try? JSONDecoder().decode([LocalRecord].self, from: $0) } ?? []
        needsHealthAuthorization = !health.isWriteAuthorized
        central = CBCentralManager(
            delegate: self,
            queue: .main,
            options: [CBCentralManagerOptionRestoreIdentifierKey: "AFUScale.central"]
        )
    }

    /// 改用快捷指令写入。
    func useShortcut() {
        usesShortcut = true
        if pendingRecord == nil, let latest {
            pendingRecord = record(latest)
        }
        status = "使用快捷指令写入"
    }

    /// 锁定是持久的，换成带 HealthKit 权限的签名后靠这个解锁重试。
    func retryHealth() {
        healthUnavailable = false
        requestHealthAuthorization()
    }

    /// 切回 Apple 健康：只有拿到写入权限才真的切，否则维持快捷指令。
    func requestHealthAuthorization() {
        guard !healthUnavailable else { return }
        if health.isWriteAuthorized {
            healthAuthorized()
            return
        }
        Task {
            do {
                try await health.requestAuthorization()
                if health.isWriteAuthorized {
                    healthAuthorized()
                } else {
                    needsHealthAuthorization = true
                    status = usesShortcut ? "未获得健康写入权限，继续用快捷指令" : "Health 未授权写入"
                }
            } catch {
                // entitlement 被剥掉时必然走这里，不再拿授权错误刷状态栏。
                healthUnavailable = true
                useShortcut()
            }
        }
    }

    private func healthAuthorized() {
        needsHealthAuthorization = false
        healthUnavailable = false
        usesShortcut = false
        status = "Health 已授权，等待秤"
        loadRecords()
        startScanningIfReady()
    }

    func loadRecords() {
        Task {
            let fromHealth = (try? await health.fetchRecords()) ?? []
            let fromShortcut = localRecords.map {
                SavedRecord(date: $0.date, weightKg: $0.weightKg, bmi: $0.bmi, bodyFatPercent: $0.bodyFatPercent)
            }
            records = (fromHealth + fromShortcut).sorted { $0.date > $1.date }
        }
    }

    private func startScanningIfReady() {
        guard wantsConnection, central != nil, central.state == .poweredOn, peripheral == nil else { return }
        status = captureMode ? "采集模式 · 等待秤" : "等待秤"
        console.log("scan.start", ["filter": "all; connect AFU name or FFB0", "allowDuplicates": "true"])
        // 前台调试用 nil 扫描所有设备，避免 iOS 因广告包服务字段差异漏掉设备。
        // 连接时再按名称/FFB0 过滤。后台唤醒稳定后可改回 [ffb0]。
        central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
    }

    private func handle(_ measurement: ScaleMeasurement, rawHex: String) {
        latest = measurement
        latestRawHex = rawHex
        print("[AFUScale][parsed] weight=\(measurement.weightKg) stable=\(measurement.isStable) final=\(measurement.isFinal) impedance=\(String(describing: measurement.impedance))")
        // 只写最终结果包（byte[2] == 0x02）。阻抗可能为 0，体重仍有效。
        guard measurement.isFinal else {
            print("[AFUScale][skip] not final result packet")
            return
        }
        print("[AFUScale][final] final result packet")
        guard !captureMode else { status = "已收到最终包，继续采集"; return }
        save(measurement)
    }

    private func save(_ measurement: ScaleMeasurement) {
        guard heightCm.isFinite, heightCm > 0, measurement.weightKg.isFinite, measurement.weightKg > 0 else {
            status = "身高或体重无效，未写入健康"
            return
        }
        if let lastSavedAt, Date().timeIntervalSince(lastSavedAt) < 90 {
            disconnectFromScale()
            return
        }
        lastSavedAt = Date()

        let (weight, bmi, fat) = metrics(measurement)
        guard !usesShortcut else {
            pendingRecord = record(measurement)
            lastSavedText = Self.summary("待写入", weight, bmi, fat)
            status = "等待通过快捷指令写入"
            disconnectFromScale()
            return
        }
        Task {
            do {
                try await health.save(weightKg: weight, bmi: bmi, bodyFatPercent: fat)
                loadRecords()
                lastSavedText = Self.summary("已写入", weight, bmi, fat)
                status = "写入完成，断开连接"
                disconnectFromScale()
            } catch {
                pendingRecord = record(measurement)
                usesShortcut = true
                lastSavedText = Self.summary("待写入", weight, bmi, fat)
                status = "Health 写入失败，改用快捷指令"
                disconnectFromScale()
            }
        }
    }

    private func record(_ measurement: ScaleMeasurement, date: Date = Date()) -> LocalRecord {
        let m = metrics(measurement)
        return LocalRecord(date: date, weightKg: m.weight, bmi: m.bmi, bodyFatPercent: m.fat)
    }

    /// 原项目的 BMI 体脂估算未使用阻抗；诊断版本暂不把它写入健康。
    private func metrics(_ measurement: ScaleMeasurement) -> (weight: Double, bmi: Double, fat: Double?) {
        let weight = (measurement.weightKg * 100).rounded() / 100
        return (weight, BodyMetrics.bmi(weightKg: weight, heightCm: heightCm), nil)
    }

    private func disconnectFromScale() {
        guard let peripheral else {
            startScanningIfReady()
            return
        }
        central.cancelPeripheralConnection(peripheral)
    }
}

// CBCentralManager uses the main queue. Execute callbacks synchronously on that
// actor so journal sequence preserves callback order (no unstructured Task hops).
extension ScaleController: CBCentralManagerDelegate {
    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        MainActor.assumeIsolated {
            console.log("bluetooth.state", ["stateRaw": String(central.state.rawValue)])
            if central.state == .poweredOn { startScanningIfReady() }
            else { status = "蓝牙不可用：\(central.state.rawValue)" }
        }
    }
    nonisolated func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
        MainActor.assumeIsolated {
            console.log("bluetooth.restore", ["keys": dict.keys.sorted().joined(separator: ",")])
            let devices = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral] ?? []
            // End old connections, then discover again so this journal gets the GATT tree.
            for device in devices { central.cancelPeripheralConnection(device) }
        }
    }
    nonisolated func centralManager(_ central: CBCentralManager, didDiscover device: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        MainActor.assumeIsolated {
            let name = advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? device.name ?? ""
            let services = advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? []
            guard (name == targetName || services.contains(ffb0)), !name.contains("Clone") else { return }
            var fields = advFields(advertisementData)
            fields.merge(deviceFields(device), uniquingKeysWith: { _, new in new })
            fields["rssi"] = RSSI.stringValue
            console.log("advertisement", fields)
            guard wantsConnection, peripheral == nil else { return }
            peripheral = device
            device.delegate = self
            status = "发现 \(name.isEmpty ? "FFB0 设备" : name)，连接中"
            console.log("scan.stop")
            central.stopScan()
            console.log("connection.request", deviceFields(device))
            central.connect(device, options: nil)
        }
    }
    nonisolated func centralManager(_ central: CBCentralManager, didConnect device: CBPeripheral) {
        MainActor.assumeIsolated {
            guard wantsConnection, device === peripheral else { central.cancelPeripheralConnection(device); return }
            console.log("connection.connected", deviceFields(device))
            status = "已连接，发现服务"
            discover(device)
        }
    }
    nonisolated func centralManager(_ central: CBCentralManager, didFailToConnect device: CBPeripheral, error: Error?) {
        MainActor.assumeIsolated {
            console.log("connection.failed", deviceFields(device).merging(["error": error?.localizedDescription ?? ""], uniquingKeysWith: { _, new in new }))
            if device === peripheral { peripheral = nil }
            startScanningIfReady()
        }
    }
    nonisolated func centralManager(_ central: CBCentralManager, didDisconnectPeripheral device: CBPeripheral, error: Error?) {
        MainActor.assumeIsolated {
            console.log("connection.disconnected", deviceFields(device).merging(["error": error?.localizedDescription ?? ""], uniquingKeysWith: { _, new in new }))
            if device === peripheral { peripheral = nil }
            startScanningIfReady()
        }
    }
}

extension ScaleController: CBPeripheralDelegate {
    nonisolated func peripheral(_ device: CBPeripheral, didDiscoverServices error: Error?) {
        MainActor.assumeIsolated {
            guard wantsConnection, device === peripheral else { return }
            console.log("gatt.services.result", ["deviceID": device.identifier.uuidString, "error": error?.localizedDescription ?? "", "count": String(device.services?.count ?? 0)])
            guard error == nil else { return }
            for (index, service) in (device.services ?? []).enumerated() where captureMode || service.uuid == ffb0 {
                console.log("gatt.service", ["serviceUUID": service.uuid.uuidString, "serviceIndex": String(index), "isPrimary": String(service.isPrimary)])
                console.log("gatt.discoverCharacteristics.request", ["serviceUUID": service.uuid.uuidString, "filter": captureMode ? "all" : "FFB2"])
                device.discoverCharacteristics(captureMode ? nil : [ffb2], for: service)
            }
        }
    }
    nonisolated func peripheral(_ device: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        MainActor.assumeIsolated {
            guard wantsConnection, device === peripheral else { return }
            console.log("gatt.characteristics.result", ["serviceUUID": service.uuid.uuidString, "error": error?.localizedDescription ?? ""])
            guard error == nil else { return }
            for ch in service.characteristics ?? [] where captureMode || ch.uuid == ffb2 {
                let fields = characteristicFields(device, ch)
                console.log("gatt.characteristic", fields)
                if captureMode {
                    console.log("gatt.discoverDescriptors.request", fields)
                    device.discoverDescriptors(for: ch)
                    if ch.properties.contains(.read) {
                        console.log("gatt.read.request", fields)
                        device.readValue(for: ch)
                    }
                }
                if ch.properties.contains(.notify) || ch.properties.contains(.indicate) {
                    console.log("gatt.subscribe.request", fields)
                    device.setNotifyValue(true, for: ch)
                    status = captureMode ? "采集中 · 已请求数据订阅" : "订阅称重数据"
                }
            }
        }
    }
    nonisolated func peripheral(_ device: CBPeripheral, didUpdateValueFor ch: CBCharacteristic, error: Error?) {
        MainActor.assumeIsolated {
            guard wantsConnection, device === peripheral else { return }
            var fields = characteristicFields(device, ch)
            fields["error"] = error?.localizedDescription ?? ""
            fields["hex"] = ch.value.map(Self.hex) ?? ""
            fields["length"] = String(ch.value?.count ?? 0)
            fields["delivery"] = "CoreBluetooth value callback (read/notify not distinguished by API)"
            let event = console.log("gatt.value.rx", fields)
            guard error == nil, ch.uuid == ffb2, let data = ch.value else { return }
            latestRawHex = Self.hex(data)
            guard let measurement = ScalePacketParser.parse(data) else {
                console.log("packet.unparsed", ["sourceSequence": event.map { String($0.sequence) } ?? "", "hex": Self.hex(data)])
                return
            }
            if measurement.isFinal {
                var parsed = profileFields
                parsed["sourceSequence"] = event.map { String($0.sequence) } ?? ""
                parsed["weightKg"] = String(measurement.weightKg)
                parsed["candidateA"] = measurement.impedance.map { String($0.a) } ?? "0"
                parsed["candidateB"] = measurement.impedance.map { String($0.b) } ?? "0"
                parsed["hex"] = Self.hex(data)
                parsed["scaleStoredProfile"] = "unknown"
                console.log("measurement.final", parsed)
            }
            handle(measurement, rawHex: Self.hex(data))
        }
    }
    nonisolated func peripheral(_ device: CBPeripheral, didUpdateNotificationStateFor ch: CBCharacteristic, error: Error?) {
        MainActor.assumeIsolated {
            var fields = characteristicFields(device, ch)
            fields["error"] = error?.localizedDescription ?? ""
            console.log("gatt.subscribe.result", fields)
        }
    }
    nonisolated func peripheral(_ device: CBPeripheral, didDiscoverDescriptorsFor ch: CBCharacteristic, error: Error?) {
        MainActor.assumeIsolated {
            guard wantsConnection, device === peripheral else { return }
            var fields = characteristicFields(device, ch)
            fields["error"] = error?.localizedDescription ?? ""
            console.log("gatt.descriptors.result", fields)
            guard captureMode, error == nil else { return }
            for descriptor in ch.descriptors ?? [] {
                var item = fields
                item["descriptorUUID"] = descriptor.uuid.uuidString
                console.log("gatt.descriptor.read.request", item)
                device.readValue(for: descriptor)
            }
        }
    }
    nonisolated func peripheral(_ device: CBPeripheral, didUpdateValueFor descriptor: CBDescriptor, error: Error?) {
        MainActor.assumeIsolated {
            var fields = descriptor.characteristic.map { characteristicFields(device, $0) } ?? deviceFields(device)
            fields["descriptorUUID"] = descriptor.uuid.uuidString
            fields["error"] = error?.localizedDescription ?? ""
            if let data = descriptor.value as? Data { fields["hex"] = Self.hex(data) }
            else { fields["value"] = descriptor.value.map { String(describing: $0) } ?? "" }
            console.log("gatt.descriptor.rx", fields)
        }
    }
    nonisolated func peripheral(_ device: CBPeripheral, didWriteValueFor ch: CBCharacteristic, error: Error?) {
        MainActor.assumeIsolated {
            var fields = characteristicFields(device, ch)
            fields["error"] = error?.localizedDescription ?? ""
            console.log("gatt.write.result", fields)
        }
    }
    nonisolated func peripheral(_ device: CBPeripheral, didModifyServices invalidatedServices: [CBService]) {
        MainActor.assumeIsolated {
            console.log("gatt.services.invalidated", ["UUIDs": invalidatedServices.map { $0.uuid.uuidString }.joined(separator: ",")])
            if wantsConnection, device === peripheral { discover(device) }
        }
    }
}
