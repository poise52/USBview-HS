# USBview HS

**English** · [Русский](README.ru.md)

USBview HS is a USB inspector for macOS. It shows how devices connect through ports and hubs and lets you reconnect a device from the USB tree.

The app pairs a SwiftUI window with a Haskell command-line tool. Both read the same USB topology from the macOS I/O Registry. The interface opens in Russian. Choose **English** in **Настройки → Язык интерфейса** to switch immediately.

## Install on Apple Silicon

On macOS 15 or later, download the archive ending in `-macos-arm64.zip` from [GitHub Releases](https://github.com/poise52/USBview-HS/releases), unzip it, and move `USBviewHS.app` to Applications. Release builds use an ad hoc signature and are not notarized by Apple.

## Build and launch

You need macOS 15 or later, Xcode with the macOS SDK and a Swift 6 compiler, GHC, cabal-install, and Make. From the repository root, run

```sh
make run
```

This builds and opens `build/USBviewHS.app`. The bundle includes the Haskell executable and is signed locally for the architecture of the Mac that built it. Use `make build` to build the bundle on its own. If Xcode is installed in a custom location, set `DEVELOPER_DIR` to its `Contents/Developer` directory.

## Menu bar and settings

Click the USB connector in the macOS menu bar to see connected devices. Click a device name to open its details, or use the reconnect button beside it. Resetting a device or hub requires confirmation. For a panel that stays above other windows, choose **USB mini window** at the bottom of the sidebar. It opens in the upper-left corner and can be moved.

Open **Settings** from the bottom of the sidebar, from the gear in the compact panel, or with **⌘,** while USBview HS is active. You can switch languages, hide the menu bar icon, and set auto-refresh to 1, 2, 5, or 10 seconds. These preferences carry over to the next launch.

## Reconnect a device or hub

Select the device in the sidebar or overview, click **Reconnect…**, and confirm. USBview HS asks macOS to reset the device and reports whether it reappears on the same port.

If the device has disappeared from the tree, you can reset its parent hub. This briefly disconnects every device on that branch. Eject any mounted volumes on the branch in Finder before resetting the hub.

## Inspect the USB tree

| Select | What you can see |
| --- | --- |
| Controller or hub | The devices below it, including nested hubs and empty ports. The tree groups the USB 2 and USB 3 sides of a connector when the registry links them. |
| Port | Current limits while awake and asleep, per-link error counters, and USB-C transport information when available. |
| Device | Vendor and product IDs, serial number, negotiated speed, active configuration, interfaces, and drivers. **Configuration descriptors…** reads configuration descriptors on demand, including alternate settings and endpoints. |
| Ethernet adapter or drive | BSD interface name, MAC address, MTU, and link state for adapters. Media and partition names, sizes, and write capability for drives. Available fields depend on the driver. |

Search by name, manufacturer, or `VID:PID`. Press **⌘R** to take a new snapshot, or enable **Auto-refresh** to take snapshots periodically (every two seconds by default). The log keeps the last 200 attach and detach events observed between snapshots. A device attached and removed within one interval may go unrecorded.

## Use from the terminal

| Command | Output |
| --- | --- |
| `make tree` | One snapshot as an indented USB tree |
| `make dump > topology.json` | The same topology and its properties as JSON, including serial numbers when available |
| `make watch` | The initial tree, then timestamped attach and detach events until you press Ctrl+C |
| `make descriptors` | Configuration descriptors for connected devices and hubs |

To inspect one category, run the executable inside the built app. Each command works without opening a window.

```sh
app=./build/USBviewHS.app/Contents/MacOS/USBviewHS
"$app" --network
"$app" --storage
"$app" --details
```

## Development

The [Cabal manifest](usbview-hs.cabal) defines the Haskell executable, dependencies, and topology tests. The [Haskell source](engine/) reads IOKit and builds the tree. The [Swift source](app/) displays snapshots, reads configuration descriptors through IOUSBLib, and reconnects devices through `IOUSBHostDevice.reset()`.

```sh
cabal build
cabal test
cabal run usbview-hs -- --dump-tree
cabal repl exe:usbview-hs
```

Run `make test` to check both languages together. It runs the topology and Swift tests, decodes a live snapshot from the bundled executable, and verifies the app signature.

To publish a release, push a tag in the form `v1.2.3`. GitHub Actions uses the tag for the app version, runs `make test`, and publishes the Apple Silicon ZIP and its SHA-256 checksum.

Every push to `main` and every pull request targeting it also runs `make test`. Download the tested app from the CI run’s **Artifacts** section. To build a release for an existing tag, open **Actions → Release for Apple Silicon → Run workflow**, select `main`, and enter the tag.

## License

USBview HS is distributed under the [MIT License](LICENSE).
