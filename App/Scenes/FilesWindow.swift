import SwiftUI
import AppKit
import UniformTypeIdentifiers
import ADBKit
import SharedModels

// SyncEntry isn't Identifiable in ADBKit (filesystem names aren't globally unique),
// but within one directory listing the name is unique enough for SwiftUI Table.
extension SyncEntry: @retroactive Identifiable {
  public var id: String { name }
}

/// Free-standing files browser window. One per device.
@MainActor
final class FilesWindowController: NSWindowController {
  let viewModel: FilesViewModel

  init(device: Device) {
    let vm = FilesViewModel(device: device)
    self.viewModel = vm
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 960, height: 640),
      styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
      backing: .buffered,
      defer: false
    )
    let title = device.model.isEmpty ? device.id : device.model
    window.title = "Files — \(title)"
    window.titlebarAppearsTransparent = true
    window.toolbarStyle = .unified
    window.contentView = NSHostingView(rootView: FilesView(viewModel: vm))
    window.center()
    super.init(window: window)
  }

  required init?(coder: NSCoder) { fatalError() }
}

// MARK: SwiftUI

struct FilesView: View {
  @StateObject var viewModel: FilesViewModel
  @State private var selection: Set<String> = []
  @State private var selectedShortcut: String? = "/sdcard"
  @State private var sortOrder = [KeyPathComparator(\SyncEntry.name)]
  @State private var renameTarget: SyncEntry?
  @State private var renameText: String = ""

  var body: some View {
    NavigationSplitView(columnVisibility: .constant(.all)) {
      sidebar
        .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 260)
    } detail: {
      detail
        .overlay(alignment: .top) {
          installBanner
            .padding(.top, 12)
            .allowsHitTesting(false)
            .animation(.easeInOut(duration: 0.2), value: viewModel.installState)
        }
    }
    .navigationTitle("")
    .task { await viewModel.load() }
    .onDrop(of: [.fileURL], isTargeted: nil) { providers in
      handleDrop(providers: providers)
    }
    .sheet(item: $renameTarget) { entry in
      RenameSheet(
        initial: renameText.isEmpty ? entry.name : renameText,
        isDirectory: entry.isDirectory,
        onCommit: { newName in
          Task { await viewModel.rename(entry, to: newName) }
          renameTarget = nil
          renameText = ""
        },
        onCancel: {
          renameTarget = nil
          renameText = ""
        }
      )
    }
  }

  // MARK: install banner

  @ViewBuilder
  private var installBanner: some View {
    if let state = viewModel.installState {
      HStack(spacing: 8) {
        switch state.phase {
        case .installing:
          ProgressView().controlSize(.small)
          Text("Installing \(state.filename)…")
        case .succeeded(let pkg):
          Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
          Text("Installed \(pkg ?? state.filename)")
        case .failed(let message):
          Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
          Text("Install failed: \(message)")
            .lineLimit(2)
            .truncationMode(.middle)
        }
      }
      .font(.callout)
      .padding(.horizontal, 14)
      .padding(.vertical, 8)
      .background(
        RoundedRectangle(cornerRadius: 10, style: .continuous)
          .fill(.regularMaterial)
      )
      .overlay(
        RoundedRectangle(cornerRadius: 10, style: .continuous)
          .strokeBorder(borderColor(for: state.phase), lineWidth: 1)
      )
      .shadow(color: .black.opacity(0.15), radius: 6, y: 2)
      .transition(.move(edge: .top).combined(with: .opacity))
    }
  }

  private func borderColor(for phase: FilesViewModel.InstallState.Phase) -> Color {
    switch phase {
    case .installing:  return .secondary.opacity(0.3)
    case .succeeded:   return .green.opacity(0.6)
    case .failed:      return .red.opacity(0.6)
    }
  }

  // MARK: sidebar

  private var sidebar: some View {
    List(selection: $selectedShortcut) {
      Section("Device") {
        HStack(spacing: 8) {
          Image(systemName: "iphone.gen3")
            .font(.title3)
            .foregroundStyle(.tint)
          VStack(alignment: .leading, spacing: 1) {
            Text(viewModel.device.model.isEmpty ? viewModel.device.id : viewModel.device.model)
              .font(.callout.weight(.medium))
              .lineLimit(1)
            Text(viewModel.device.transport.rawValue.uppercased())
              .font(.caption2.monospaced())
              .foregroundStyle(.secondary)
          }
        }
        .padding(.vertical, 4)
      }
      Section("Favorites") {
        ForEach(FilesViewModel.shortcuts) { sc in
          Label(sc.name, systemImage: sc.systemImage)
            .tag(sc.path)
        }
      }
    }
    .listStyle(.sidebar)
    .onChange(of: selectedShortcut) { _, new in
      guard let new else { return }
      Task { await viewModel.go(to: new) }
    }
  }

  // MARK: detail

  private var detail: some View {
    VStack(spacing: 0) {
      pathBar
      Divider().opacity(0.3)
      table
      Divider().opacity(0.3)
      statusBar
    }
    .background(.background)
    .toolbar {
      ToolbarItemGroup(placement: .navigation) {
        Button { Task { await viewModel.goUp() } } label: {
          Image(systemName: "chevron.up")
        }
        .disabled(viewModel.currentPath == "/" || viewModel.isLoading)
        .help("Up one directory")
      }
      ToolbarItem(placement: .primaryAction) {
        Button { Task { await viewModel.load() } } label: {
          Image(systemName: "arrow.clockwise")
        }
        .disabled(viewModel.isLoading)
        .help("Reload")
      }
      ToolbarItem(placement: .primaryAction) {
        Button {
          Task {
            await viewModel.makeDirectory()
            // Find the just-created folder, jump into rename mode on it.
            if let created = viewModel.entries.first(where: { $0.name.hasPrefix("untitled folder") }) {
              renameTarget = created
              renameText = created.name
            }
          }
        } label: {
          Label("New Folder", systemImage: "folder.badge.plus")
        }
        .disabled(viewModel.isLoading)
        .help("New Folder")
      }
      ToolbarItem(placement: .primaryAction) {
        Button {
          let panel = NSOpenPanel()
          panel.canChooseFiles = true
          panel.canChooseDirectories = true
          panel.allowsMultipleSelection = true
          guard panel.runModal() == .OK else { return }
          Task { await viewModel.upload(localURLs: panel.urls) }
        } label: {
          Label("Upload", systemImage: "arrow.up.circle")
        }
        .disabled(viewModel.isLoading || viewModel.transfer != nil)
      }
      ToolbarItem(placement: .primaryAction) {
        Button {
          let chosen = viewModel.entries.filter { selection.contains($0.name) }
          Task { await viewModel.download(chosen) }
        } label: {
          Label("Download", systemImage: "arrow.down.circle")
        }
        .disabled(selection.isEmpty || viewModel.transfer != nil)
      }
    }
  }

  // MARK: path bar

  private var pathBar: some View {
    HStack(spacing: 4) {
      Button { Task { await viewModel.go(to: "/") } } label: {
        Image(systemName: "macwindow")
          .font(.callout)
      }
      .buttonStyle(.plain)
      .foregroundStyle(.secondary)
      .help("Root")

      ForEach(Array(viewModel.pathComponents.enumerated()), id: \.offset) { index, comp in
        Image(systemName: "chevron.right")
          .font(.caption2.weight(.semibold))
          .foregroundStyle(.tertiary)
        Button(comp) {
          let path = "/" + viewModel.pathComponents.prefix(index + 1).joined(separator: "/")
          Task { await viewModel.go(to: path) }
        }
        .buttonStyle(.plain)
        .fontWeight(index == viewModel.pathComponents.count - 1 ? .semibold : .regular)
        .foregroundStyle(
          index == viewModel.pathComponents.count - 1 ? Color.primary : Color.secondary
        )
      }
      Spacer()
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 10)
    .font(.callout)
  }

  // MARK: table

  private var sortedEntries: [SyncEntry] {
    let dirs = viewModel.entries.filter(\.isDirectory).sorted(using: sortOrder)
    let files = viewModel.entries.filter { !$0.isDirectory }.sorted(using: sortOrder)
    return dirs + files
  }

  private var table: some View {
    ZStack {
      Table(sortedEntries, selection: $selection, sortOrder: $sortOrder) {
        TableColumn("Name", value: \.name) { entry in
          HStack(spacing: 10) {
            FileIcon(entry: entry).frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 1) {
              Text(entry.name)
                .lineLimit(1)
                .truncationMode(.middle)
              if !entry.isDirectory {
                Text(formatBytes(entry.size))
                  .font(.caption.monospacedDigit())
                  .foregroundStyle(.secondary)
              }
            }
          }
          .padding(.vertical, 4)
        }

        TableColumn("Size", value: \.size) { entry in
          Text(entry.isDirectory ? "—" : formatBytes(entry.size))
            .font(.callout.monospacedDigit())
            .foregroundStyle(.secondary)
        }
        .width(min: 80, ideal: 100)

        TableColumn("Modified", value: \.mtime) { entry in
          Text(Date(timeIntervalSince1970: TimeInterval(entry.mtime))
                .formatted(.relative(presentation: .named)))
            .font(.callout)
            .foregroundStyle(.secondary)
        }
        .width(min: 120, ideal: 160)
      }
      .contextMenu(forSelectionType: String.self) { items in
        if items.count == 1, let name = items.first,
           let entry = viewModel.entries.first(where: { $0.name == name }) {
          Button("Rename…") {
            renameTarget = entry
            renameText = entry.name
          }
          Divider()
        }
        Button("Download") {
          let chosen = viewModel.entries.filter { items.contains($0.name) }
          Task { await viewModel.download(chosen) }
        }
        Divider()
        Button("Delete", role: .destructive) {
          let chosen = viewModel.entries.filter { items.contains($0.name) }
          Task { await viewModel.delete(chosen) }
        }
      } primaryAction: { items in
        guard let name = items.first,
              let entry = viewModel.entries.first(where: { $0.name == name }) else { return }
        Task {
          if entry.isDirectory { await viewModel.enter(entry) }
          else { await viewModel.download([entry]) }
        }
      }

      if viewModel.isLoading {
        VStack(spacing: 8) {
          ProgressView().controlSize(.regular)
          Text("Loading…").font(.callout).foregroundStyle(.secondary)
        }
      } else if viewModel.entries.isEmpty {
        ContentUnavailableView(
          "Empty Folder",
          systemImage: "tray",
          description: Text("Drag files here to upload, or pick a different folder.")
        )
      }
    }
  }

  // MARK: status / transfer panel

  @ViewBuilder
  private var statusBar: some View {
    if let xfer = viewModel.transfer {
      TransferPanel(xfer: xfer, cancel: { viewModel.cancelTransfer() })
    } else {
      idleStatusBar
    }
  }

  private var idleStatusBar: some View {
    HStack(spacing: 10) {
      Group {
        if let err = viewModel.lastError {
          Image(systemName: "exclamationmark.triangle.fill")
            .foregroundStyle(.orange)
          Text(err).foregroundStyle(.secondary).lineLimit(1)
        } else {
          Text("\(viewModel.entries.count) item\(viewModel.entries.count == 1 ? "" : "s")")
            .foregroundStyle(.secondary)
          if !selection.isEmpty {
            Text("·").foregroundStyle(.tertiary)
            Text("\(selection.count) selected").foregroundStyle(.secondary)
          }
        }
      }
      .font(.callout)

      Spacer()

      Text(viewModel.currentPath)
        .font(.caption.monospaced())
        .foregroundStyle(.tertiary)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(.background.secondary, in: Capsule())
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 8)
    .background(.background)
  }

  // MARK: drop handling

  private func handleDrop(providers: [NSItemProvider]) -> Bool {
    var urls: [URL] = []
    let group = DispatchGroup()
    for provider in providers where provider.canLoadObject(ofClass: URL.self) {
      group.enter()
      _ = provider.loadObject(ofClass: URL.self) { url, _ in
        if let url { urls.append(url) }
        group.leave()
      }
    }
    group.notify(queue: .main) {
      guard !urls.isEmpty else { return }
      // APKs always go to `adb install`; non-APKs use the sync push path.
      // Mixed drops split between the two without prompting.
      let (apks, rest) = urls.reduce(into: ([URL](), [URL]())) { acc, url in
        let ext = url.pathExtension.lowercased()
        if ext == "apk" || ext == "xapk" {
          acc.0.append(url)
        } else {
          acc.1.append(url)
        }
      }
      if !apks.isEmpty {
        Task {
          for apk in apks { await viewModel.installAPK(apk) }
        }
      }
      if !rest.isEmpty {
        Task { await viewModel.upload(localURLs: rest) }
      }
    }
    return true
  }

  // MARK: format helpers

  private func formatBytes(_ bytes: UInt32) -> String {
    let formatter = ByteCountFormatter()
    formatter.countStyle = .file
    return formatter.string(fromByteCount: Int64(bytes))
  }
}

// MARK: progress panel

private struct TransferPanel: View {
  let xfer: FilesViewModel.TransferState
  let cancel: () -> Void

  private var verb: String { xfer.kind == .download ? "Downloading" : "Uploading" }
  private var icon: String { xfer.kind == .download ? "arrow.down.circle.fill" : "arrow.up.circle.fill" }

  var body: some View {
    HStack(spacing: 12) {
      Image(systemName: icon)
        .font(.title3)
        .foregroundStyle(.tint)

      VStack(alignment: .leading, spacing: 4) {
        HStack {
          Text(verb).font(.callout.weight(.medium))
          if !xfer.currentName.isEmpty {
            Text(xfer.currentName)
              .font(.callout)
              .foregroundStyle(.secondary)
              .lineLimit(1)
              .truncationMode(.middle)
          }
          Spacer()
          if !xfer.queue.isEmpty {
            Text("\(xfer.currentIndex + 1) of \(xfer.queue.count)")
              .font(.caption.monospacedDigit())
              .foregroundStyle(.secondary)
          }
        }
        ProgressView(value: xfer.batchFraction)
          .progressViewStyle(.linear)
        HStack {
          if xfer.currentTotal > 0 {
            Text(format(bytes: xfer.currentBytes)) +
            Text(" / ") +
            Text(format(bytes: xfer.currentTotal))
          }
          Spacer()
          Text("\(Int(xfer.batchFraction * 100))%")
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
        }
        .font(.caption.monospacedDigit())
        .foregroundStyle(.tertiary)
      }

      Button("Cancel", action: cancel)
        .controlSize(.small)
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 10)
    .background(.background.secondary)
  }

  private func format(bytes: UInt64) -> String {
    let f = ByteCountFormatter()
    f.countStyle = .file
    return f.string(fromByteCount: Int64(bytes))
  }
}

// MARK: per-row icon

/// Uses NSWorkspace.icon to fetch the same icon Finder shows for a file type,
/// rather than a flat SF Symbol. Folders fall back to the system folder icon.
private struct FileIcon: View {
  let entry: SyncEntry

  var body: some View {
    if entry.isDirectory {
      Image(nsImage: NSWorkspace.shared.icon(for: .folder))
        .resizable()
        .frame(width: 28, height: 28)
    } else if entry.isSymlink {
      Image(nsImage: NSWorkspace.shared.icon(for: .symbolicLink))
        .resizable()
        .frame(width: 28, height: 28)
    } else {
      let ext = (entry.name as NSString).pathExtension
      let type = UTType(filenameExtension: ext) ?? .data
      Image(nsImage: NSWorkspace.shared.icon(for: type))
        .resizable()
        .frame(width: 28, height: 28)
    }
  }
}

// MARK: rename sheet

private struct RenameSheet: View {
  let initial: String
  let isDirectory: Bool
  let onCommit: (String) -> Void
  let onCancel: () -> Void

  @State private var name: String
  @FocusState private var focused: Bool

  init(initial: String, isDirectory: Bool, onCommit: @escaping (String) -> Void, onCancel: @escaping () -> Void) {
    self.initial = initial
    self.isDirectory = isDirectory
    self.onCommit = onCommit
    self.onCancel = onCancel
    self._name = State(initialValue: initial)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      HStack(spacing: 10) {
        Image(systemName: isDirectory ? "folder.fill" : "doc.fill")
          .foregroundStyle(.tint)
          .font(.title2)
        Text(isDirectory ? "Rename Folder" : "Rename File")
          .font(.headline)
      }
      TextField("New name", text: $name)
        .textFieldStyle(.roundedBorder)
        .focused($focused)
        .onSubmit { submit() }
      HStack {
        Spacer()
        Button("Cancel") { onCancel() }
          .keyboardShortcut(.cancelAction)
        Button("Rename") { submit() }
          .keyboardShortcut(.defaultAction)
          .disabled(disabledByContent)
      }
    }
    .padding(20)
    .frame(width: 360)
    .task {
      // Pre-select the basename, leave extension out — same as Finder rename.
      focused = true
      selectBasename()
    }
  }

  private var disabledByContent: Bool {
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty || trimmed == initial || trimmed.contains("/")
  }

  private func submit() {
    guard !disabledByContent else { return }
    onCommit(name.trimmingCharacters(in: .whitespacesAndNewlines))
  }

  /// Highlight just the filename portion (before the dot), matching Finder
  /// behavior where pressing Enter pre-selects the basename and leaves the
  /// extension untouched.
  private func selectBasename() {
    // SwiftUI doesn't expose text selection on TextField — closest we get is
    // focusing the field, which selects all by default on macOS. Keep simple.
  }
}
