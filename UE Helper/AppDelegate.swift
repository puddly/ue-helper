import Cocoa
import IOBluetooth
import CoreBluetooth

// CoreBluetooth doesn't seem to expose any way to do this
func getBluetoothAdapterMAC() -> Data? {
    let addressString = IOBluetoothHostController.default()?.addressAsString()
    var address = BluetoothDeviceAddress()
    let ret = IOBluetoothNSStringToDeviceAddress(addressString, &address)

    if ret != kIOReturnSuccess {
        return nil
    }

    let d = address.data

    return Data([d.0, d.1, d.2, d.3, d.4, d.5])
}

enum UEBluetoothAnnounceCurrentState: UInt8, CustomStringConvertible {
    case OFF               = 0b00000000
    case DISCONNECTED      = 0b00100000
    case CONNECTED_QUIET   = 0b01000000
    case CONNECTED_PLAYING = 0b01100000
    case CONNECTED_HEADSET = 0b11000000

    var description: String {
        switch self {
        case .OFF:
            return "Off"
        case .DISCONNECTED:
            return "Disconnected"
        case .CONNECTED_QUIET:
            return "Connected, not playing"
        case .CONNECTED_PLAYING:
            return "Connected, playing"
        case .CONNECTED_HEADSET:
            return "Connected, using microphone"
        }
    }
}

class UEBluetoothAnnounce {
    let batteryPercentage: UInt8
    let currentState: UEBluetoothAnnounceCurrentState
    let numShutdowns: UInt8
    let unknownRandom: Data
    let unknownFixed: Data

    init?(fromData data: Data) {
        if data.count != 15 && data.count != 21 {
            return nil
        }

        if data[0...3] != Data([0x03, 0x00, 0x00, 0x60]) {
            return nil
        }

        self.batteryPercentage = data[4] as UInt8
        assert(data[5] == 0x00)
        self.currentState = UEBluetoothAnnounceCurrentState(rawValue: data[6])!
        self.numShutdowns = data[7] as UInt8
        self.unknownRandom = data[8...13]

        if data.count == 15 {
            self.unknownFixed = Data([])
        } else {
            self.unknownFixed = data[14...19]
        }
    }
}


class LinkedBTDeviceMenu: NSObject, CBPeripheralDelegate {
    var blePeripheral: CBPeripheral
    var bluetoothDevice: IOBluetoothDevice?
    var menuItem: NSMenuItem
    var manager: CBCentralManager

    var blePeripheralStateObserver: NSKeyValueObservation!

    var bluetoothConnectNotification: IOBluetoothUserNotification?
    var bluetoothDisconnectNotification: IOBluetoothUserNotification?

    var lastUEAnnounce: UEBluetoothAnnounce
    var lastRSSI: NSNumber

    var deviceSubmenu: NSMenu
    var parentMenu: NSMenu

    var actionItem: NSMenuItem
    var batteryLevelItem: NSMenuItem
    var currentStateItem: NSMenuItem
    var rssiItem: NSMenuItem


    init(withDevice device: CBPeripheral, withMenuItem menuItem: NSMenuItem, withParentMenu parentMenu: NSMenu, withManager manager: CBCentralManager, lastAnnounce announce: UEBluetoothAnnounce, lastRSSI rssi: NSNumber) {
        self.blePeripheral = device
        self.menuItem = menuItem
        self.parentMenu = parentMenu
        self.manager = manager

        self.lastUEAnnounce = announce
        self.lastRSSI = rssi

        self.deviceSubmenu = NSMenu()
        self.actionItem = NSMenuItem()
        self.batteryLevelItem = NSMenuItem()
        self.currentStateItem = NSMenuItem()
        self.rssiItem = NSMenuItem()

        super.init()

        // Get the IOBluetoothDevice from our CBPeripheral
        let appleBluetoothCache = NSDictionary(contentsOfFile: "/Library/Preferences/com.apple.bluetooth.plist")

        if let cbCache = appleBluetoothCache?["CoreBluetoothCache"] as? NSDictionary {
            if let deviceEntry = cbCache[self.blePeripheral.identifier.uuidString] as? NSDictionary {
                if let deviceAddressString = deviceEntry["DeviceAddress"] as? String {
                    self.bluetoothDevice = IOBluetoothDevice(addressString: deviceAddressString)
                }
            }
        }

        if self.bluetoothDevice != nil {
            self.bluetoothDisconnectNotification = self.bluetoothDevice!.register(forDisconnectNotification: self, selector: #selector(self.onBluetoothDisconnect))
            self.bluetoothConnectNotification = IOBluetoothDevice.register(forConnectNotifications: self, selector: #selector(self.onBluetoothConnect))

            if self.bluetoothDevice!.isConnected() {
                self.onBluetoothConnect()
            } else {
                self.onBluetoothDisconnect()
            }
        }

        device.delegate = self

        parentMenu.setSubmenu(self.deviceSubmenu, for: self.menuItem)

        self.actionItem.target = self
        self.actionItem.action = #selector(handleActionClick(sender:))
        self.deviceSubmenu.addItem(self.actionItem)

        self.deviceSubmenu.addItem(NSMenuItem.separator())
        self.deviceSubmenu.addItem(self.batteryLevelItem)
        self.deviceSubmenu.addItem(self.currentStateItem)
        self.deviceSubmenu.addItem(self.rssiItem)

        self.updateLabels()

        self.blePeripheralStateObserver = self.blePeripheral.observe(\.state, options: [.old, .new], changeHandler: {(model, change) in
            switch self.blePeripheral.state {
                case .disconnecting:
                    print("We are disconnecting")
                case .connecting:
                    print("We are connecting")
                case .connected:
                    print("We are connected!")

                    if self.blePeripheral.services != nil {
                        self.peripheral(self.blePeripheral, didDiscoverServices: nil)
                    } else {
                        print("Discovering primary service...")
                        self.blePeripheral.discoverServices([CBUUID(string: "61FE")])
                    }
                case .disconnected:
                    print("We are disconnected!")
                    break

                @unknown default:
                    fatalError()
            }
        })
    }

    func updateLabels() {
        // Submenu: "UE BOOM 2 ->"

        // Clickable label
        if [.CONNECTED_QUIET, .CONNECTED_PLAYING, .CONNECTED_HEADSET].contains(self.lastUEAnnounce.currentState) {
            self.actionItem.title = "Turn off"
        } else {
            self.actionItem.title = "Turn on"
        }

        self.batteryLevelItem.title = "Battery Level: \(self.lastUEAnnounce.batteryPercentage)%"
        self.currentStateItem.title = "State: \(self.lastUEAnnounce.currentState)"
        self.rssiItem.title = "RSSI: \(self.lastRSSI)"
    }

    func notifyAnnounce(_ announce: UEBluetoothAnnounce) {
        self.lastUEAnnounce = announce
        self.updateLabels()
    }

    func notifyRSSI(_ rssi: NSNumber) {
        self.lastRSSI = rssi
        self.updateLabels()
    }

    func getDisplayName() -> String {
        // My UE BOOM 2 doesn't advertise its name until you connect, which is pointless if you're just displaying it during a scan
        // Try the CBPeripheral name, then the IOBluetoothDevice name, and finally display its CBPeriperal UUID
        if self.blePeripheral.name == nil || self.blePeripheral.name!.count == 0 {
            if self.bluetoothDevice != nil {
                return self.bluetoothDevice!.name
            } else {
                return "UE Speaker \(self.blePeripheral.identifier.uuidString)"
            }
        } else {
            return self.blePeripheral.name!
        }
    }

    @objc func onBluetoothConnect() {
        if !self.bluetoothDevice!.isConnected() {
            return;
        }

        print("Connected to device via Bluetooth classic!")
        self.menuItem.attributedTitle = NSAttributedString(string: self.getDisplayName(), attributes: [
            NSAttributedString.Key.font: NSFontManager.shared.convert(NSFont.menuBarFont(ofSize: 0), toHaveTrait: .boldFontMask)
        ])
    }

    @objc func onBluetoothDisconnect() {
        if self.bluetoothDevice!.isConnected() {
            return;
        }

        print("Disconnected from device via Bluetooth classic!")
        self.menuItem.attributedTitle = NSAttributedString(string: self.getDisplayName(), attributes: [
            NSAttributedString.Key.font: NSFontManager.shared.convert(NSFont.menuBarFont(ofSize: 0), toHaveTrait: .unboldFontMask)
        ])
    }

    @objc func handleActionClick(sender: NSMenuItem) {
        if [.CONNECTED_QUIET, .CONNECTED_PLAYING, .CONNECTED_HEADSET].contains(self.lastUEAnnounce.currentState)  {
            self.turnOff()
            //self.manager.cancelPeripheralConnection(self.blePeripheral)
        } else {
            self.manager.connect(self.blePeripheral)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if error != nil {
            print("Failed to discover services!")
            return
        }

        for service in self.blePeripheral.services! {
            // We're only interested in this one
            if service.uuid != CBUUID(string: "61FE") {
                continue
            }

            print("Discovered service: \(service.uuid). Now discovering the turn on characteristic...")

            // We're also only intersted in this one
            self.blePeripheral.discoverCharacteristics([CBUUID(string: "C6D6DC0D-07F5-47EF-9B59-630622B01FD3")], for: service)
            break
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        if error != nil || service.characteristics == nil {
            print("Failed to discover characteristics!")
            return
        }

        for characteristic in service.characteristics! {
            if characteristic.uuid != CBUUID(string: "C6D6DC0D-07F5-47EF-9B59-630622B01FD3") {
                continue
            }

            print("    Found our main characteristic \(characteristic.uuid)")
            self.turnOn(characteristic)
            break
        }
    }

    func turnOff() {
        print("Turning off!")

        var channel: IOBluetoothRFCOMMChannel? = IOBluetoothRFCOMMChannel()
        let ret = self.bluetoothDevice!.openRFCOMMChannelSync(&channel, withChannelID: 1, delegate: self)

        if ret != kIOReturnSuccess {
            print("Failed to open RFCOMM channel!")
            return
        }

        var payload = Data([0x02, 0x01, 0xb6])
        let count = payload.count  // we can't access this inside of the below closure

        _ = payload.withUnsafeMutableBytes { pointer in
            channel!.writeSync(pointer.baseAddress, length: UInt16(count))
        }
    }

    func turnOn(_ characteristic: CBCharacteristic) {
        print("Turning on!")

        // We need our device MAC to turn on the speaker??
        guard let adapterMac = getBluetoothAdapterMAC() else {
            print("Failed to get Bluetooth MAC!")
            return
        }

        self.blePeripheral.writeValue(adapterMac + Data([1]), for: characteristic, type: .withResponse)
    }
}


@NSApplicationMain
class AppDelegate: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate, NSApplicationDelegate, NSMenuDelegate {
    @IBOutlet weak var statusMenu: NSMenu!

    var centralBLEManager: CBCentralManager!
    let statusBarItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    var menuItems: [LinkedBTDeviceMenu] = []

    var seenUEDevices: [UUID:LinkedBTDeviceMenu] = [:]

    var beginScanning = false

    func centralManagerDidUpdateState(_ manager: CBCentralManager) {
        switch manager.state {
            case .poweredOff:
                print("BLE has powered off")
                self.centralBLEManager.stopScan()
            case .poweredOn:
                print("BLE is now powered on")

                if self.beginScanning {
                    print("Beginning scan")
                    self.centralBLEManager.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
                    self.beginScanning = false
                }
            case .resetting:  print("BLE is resetting")
            case .unauthorized:  print("Unauthorized BLE state")
            case .unknown:  print("Unknown BLE state")
            case .unsupported:  print("This platform does not support BLE")
            @unknown default:
                print("Unknown manager case!")
        }
    }

    func menuWillOpen(_ menu: NSMenu) {
        print("Opening the menu")

        self.beginScanning = true

        // Call this to trigger a scan
        self.centralManagerDidUpdateState(self.centralBLEManager)
    }

    func menuDidClose(_ menu: NSMenu) {
        print("Closing the menu")

        self.centralBLEManager.stopScan()
    }

    func centralManager(_ manager: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData advertisement: [String : Any], rssi: NSNumber) {
        if self.seenUEDevices.keys.contains(peripheral.identifier) {
            self.seenUEDevices[peripheral.identifier]!.notifyRSSI(rssi)
        }

        guard let data = advertisement["kCBAdvDataManufacturerData"] else {
            return
        }

        guard let ueAnnounce = UEBluetoothAnnounce(fromData: data as! Data) else {
            return
        }

        print("Received an announce with random \([UInt8](ueAnnounce.unknownRandom)), fixed \([UInt8](ueAnnounce.unknownFixed)), battery \(ueAnnounce.batteryPercentage), and state \(ueAnnounce.currentState)")

        if self.seenUEDevices.keys.contains(peripheral.identifier) {
            print("Already seen the device. Ignoring...")
            self.seenUEDevices[peripheral.identifier]!.notifyAnnounce(ueAnnounce)

            return
        }

        let menuItem = NSMenuItem()
        self.statusMenu.insertItem(menuItem, at: self.statusMenu.numberOfItems - 2)
        self.seenUEDevices[peripheral.identifier] = LinkedBTDeviceMenu(withDevice: peripheral, withMenuItem: menuItem, withParentMenu: self.statusMenu, withManager: self.centralBLEManager, lastAnnounce: ueAnnounce, lastRSSI: rssi)

        print("Created new UE device with peripheral identifier \(peripheral.identifier)")
    }
    
    @objc func quitButtonClickedWithSender(sender: NSMenuItem) {
        NSApplication.shared.terminate(self)
    }

    func applicationDidFinishLaunching(_ aNotification: Notification) {
        self.statusMenu.delegate = self

        // Setup the buttons
        self.statusBarItem.button?.title = "UE"
        self.statusBarItem.menu = self.statusMenu

        let scanningMessage = NSMenuItem()
        scanningMessage.title = "Scanning..."
        self.statusMenu.addItem(scanningMessage)

        // Horizontal separator
        self.statusMenu.addItem(NSMenuItem.separator())
        self.statusMenu.addItem(NSMenuItem(title: "Speakers", action: nil, keyEquivalent: ""))
        self.statusMenu.addItem(NSMenuItem.separator())

        // Quit button
        let quitItem = NSMenuItem()
        quitItem.title = "Quit UE Helper"
        quitItem.action = #selector(AppDelegate.quitButtonClickedWithSender(sender:))

        self.statusMenu.addItem(quitItem)

        // Begin scanning
        self.centralBLEManager = CBCentralManager(delegate: self, queue: nil)
    }

    func applicationWillTerminate(_ aNotification: Notification) {
        // Insert code here to tear down your application
    }
}
