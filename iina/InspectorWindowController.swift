//
//  InspectorWindowController.swift
//  iina
//
//  Created by lhc on 21/12/2016.
//  Copyright © 2016 lhc. All rights reserved.
//

import Cocoa

fileprivate let watchTableBackgroundColor = NSColor(red: 2.0/3, green: 2.0/3, blue: 2.0/3, alpha: 0.1)
fileprivate let watchTableColumnHeaderColor = NSColor(red: 0.05, green: 0.05, blue: 0.05, alpha: 1)
private typealias InspectorRow = (key: String, label: String)
private typealias InspectorSection = (title: String, rows: [InspectorRow])

class InspectorWindowController: NSWindowController, NSWindowDelegate, NSTableViewDelegate, NSTableViewDataSource {

  override var windowNibName: NSNib.Name {
    return NSNib.Name("InspectorWindowController")
  }

  var updateTimer: Timer?

  var watchProperties: [String] = []

  private var observers: [NSObjectProtocol] = []

  @IBOutlet weak var tabView: NSTabView!
  @IBOutlet weak var tabButtonGroup: NSSegmentedControl!
  @IBOutlet weak var trackPopup: NSPopUpButton!

  @IBOutlet weak var pathField: NSTextField!
  @IBOutlet weak var fileSizeField: NSTextField!
  @IBOutlet weak var fileFormatField: NSTextField!
  @IBOutlet weak var chaptersField: NSTextField!
  @IBOutlet weak var editionsField: NSTextField!
  @IBOutlet weak var titleField: NSTextField!
  @IBOutlet weak var commentField: NSTextField!

  @IBOutlet weak var durationField: NSTextField!
  @IBOutlet weak var vformatField: NSTextField!
  @IBOutlet weak var vcodecField: NSTextField!
  @IBOutlet weak var vdecoderField: NSTextField!
  @IBOutlet weak var vcolorspaceField: NSTextField!
  @IBOutlet weak var vprimariesField: NSTextField!
  @IBOutlet weak var vPixelFormat: NSTextField!

  @IBOutlet weak var voField: NSTextField!
  @IBOutlet weak var vsizeField: NSTextField!
  @IBOutlet weak var vbitrateField: NSTextField!
  @IBOutlet weak var vfpsField: NSTextField!
  @IBOutlet weak var aformatField: NSTextField!
  @IBOutlet weak var acodecField: NSTextField!
  @IBOutlet weak var aoField: NSTextField!
  @IBOutlet weak var achannelsField: NSTextField!
  @IBOutlet weak var abitrateField: NSTextField!
  @IBOutlet weak var asamplerateField: NSTextField!

  @IBOutlet weak var trackIdField: NSTextField!
  @IBOutlet weak var trackDefaultField: NSTextField!
  @IBOutlet weak var trackForcedField: NSTextField!
  @IBOutlet weak var trackSelectedField: NSTextField!
  @IBOutlet weak var trackExternalField: NSTextField!
  @IBOutlet weak var trackSourceIdField: NSTextField!
  @IBOutlet weak var trackTitleField: NSTextField!
  @IBOutlet weak var trackLangField: NSTextField!
  @IBOutlet weak var trackFilePathField: NSTextField!
  @IBOutlet weak var trackCodecField: NSTextField!
  @IBOutlet weak var trackDecoderField: NSTextField!
  @IBOutlet weak var trackFPSField: NSTextField!
  @IBOutlet weak var trackChannelsField: NSTextField!
  @IBOutlet weak var trackSampleRateField: NSTextField!

  @IBOutlet weak var avsyncField: NSTextField!
  @IBOutlet weak var totalAvsyncField: NSTextField!
  @IBOutlet weak var droppedFramesField: NSTextField!
  @IBOutlet weak var mistimedFramesField: NSTextField!
  @IBOutlet weak var displayFPSField: NSTextField!
  @IBOutlet weak var voFPSField: NSTextField!
  @IBOutlet weak var edispFPSField: NSTextField!
  @IBOutlet weak var watchTableView: NSTableView!
  @IBOutlet weak var deleteButton: NSButton!

  @IBOutlet weak var watchTableContainerView: NSView!
  private var tableHeightConstraint: NSLayoutConstraint? = nil
  private var diagnosticFields: [String: NSTextField] = [:]
  private var diagnosticLabels: [String: String] = [:]
  private var diagnosticPageKeys = Array(repeating: [String](), count: 4)

  // MARK: - Window Delegate

  override func windowDidLoad() {
    super.windowDidLoad()

    watchProperties = Preference.array(for: .watchProperties) as! [String]
    watchTableView.delegate = self
    watchTableView.dataSource = self

    let headerFont = NSFont.boldSystemFont(ofSize: NSFont.smallSystemFontSize)
    for column in watchTableView.tableColumns {
      let headerCell = WatchTableColumnHeaderCell()
      // Use title from the XIB
      let title = column.headerCell.title
      // Use small bold system font
      headerCell.attributedStringValue = NSMutableAttributedString(string: title, attributes: [.font: headerFont])
      column.headerCell = headerCell
    }

    watchTableContainerView.wantsLayer = true
    watchTableContainerView.layer?.backgroundColor = watchTableBackgroundColor.cgColor

    tableHeightConstraint = watchTableContainerView.heightAnchor.constraint(greaterThanOrEqualToConstant: computeMinTableHeight())
    tableHeightConstraint!.isActive = true
    watchTableContainerView.layout()

    deleteButton.isEnabled = false
    installDiagnosticPages()

    updateInfo()
    watchTableView.scrollRowToVisible(0)

    let info = PlayerCore.lastActive.info
    log("""
      Video tracks:
      \(info.videoTracks.compactMap { String(describing: $0) }.joined(separator: "\n"))
      """, level: .verbose)
    log("""
      Audio tracks:
      \(info.audioTracks.compactMap { String(describing: $0) }.joined(separator: "\n"))
      """, level: .verbose)
    log("""
      Subtitle tracks:
      \(info.subTracks.compactMap { String(describing: $0) }.joined(separator: "\n"))
      """, level: .verbose)
  }

  override func showWindow(_ sender: Any?) {
    log("Showing Inspector window", level: .verbose)

    guard let _ = self.window else { return }  // trigger lazy load if not loaded

    updateInfo()

    removeTimerAndListeners()
    updateTimer = Timer.scheduledTimer(timeInterval: TimeInterval(1), target: self, selector: #selector(dynamicUpdate), userInfo: nil, repeats: true)

    observers.append(NotificationCenter.default.addObserver(forName: .iinaFileLoaded, object: nil, queue: .main, using: self.fileLoaded))
    observers.append(NotificationCenter.default.addObserver(forName: .iinaMainWindowChanged, object: nil, queue: .main, using: self.fileLoaded))

    super.showWindow(sender)

    // Log additional information for developers when the inspector window is shown.
    MemoryUsage.shared.logUsage("after showing inspector window")
  }

  func windowWillClose(_ notification: Notification) {
    log("Closing Inspector window", level: .verbose)
    // Remove timer & listeners to conserve resources
    removeTimerAndListeners()
  }
  
  /// Workaround (as of macOS 13.4): try to ensure `watchTableView` never scrolls vertically, because `NSTableView` will draw rows
  /// overlapping the header (maybe only a problem for custom `NSTableHeaderCell`s which are not opaque), but looks quite ugly.
  private func computeMinTableHeight() -> CGFloat {
    /// Add `1` to `numberOfRows` because it will scroll if there is not at least 1 empty row
    let fitted = watchTableView.headerView!.frame.height + CGFloat(
      watchTableView.numberOfRows + 1) * (watchTableView.rowHeight + watchTableView.intercellSpacing.height)
    // An empty watch list would otherwise collapse to a sliver of a table.
    return max(fitted, 160)
  }

  private func removeTimerAndListeners() {
    updateTimer?.invalidate()
    updateTimer = nil
    for observer in observers {
      NotificationCenter.default.removeObserver(observer)
    }
    observers = []
  }

  func updateInfo(dynamic: Bool = false) {
    let player = PlayerCore.lastActive
    guard player.info.state.active else { return }
    let controller = player.mpv!
    let info = player.info

    DispatchQueue.main.async {

      if !dynamic {

        // File level metadata.
        let commentKey = MPVProperty.metadata + "/by-key/comment"

        // string properties

        let strProperties: [String: NSTextField] = [
          MPVProperty.path: self.pathField,
          MPVProperty.fileFormat: self.fileFormatField,
          MPVProperty.chapters: self.chaptersField,
          MPVProperty.editions: self.editionsField,
          MPVProperty.mediaTitle: self.titleField,
          commentKey: self.commentField,
          // in mpv 0.38, video-codec-name is an alias of current-tracks/video/codec, etc
          MPVProperty.currentTracksVideoCodec: self.vformatField,
          MPVProperty.currentTracksVideoCodecDesc: self.vcodecField,
          MPVProperty.containerFps: self.vfpsField,
          MPVProperty.currentVo: self.voField,
          MPVProperty.currentTracksAudioCodecDesc: self.acodecField,
          MPVProperty.audioParamsFormat: self.aformatField,
          MPVProperty.audioParamsChannels: self.achannelsField,
          MPVProperty.audioParamsSamplerate: self.asamplerateField
        ]

        for (k, v) in strProperties {
          var value = controller.getString(k)
          if value == "" { value = nil }
          // If the video does not have a title then mpv returns the filename. If that is the case
          // then clear the value. The filename is already being displayed in the path.
          if k == MPVProperty.mediaTitle, let filename = controller.getString(MPVProperty.filename),
             value == filename {
            value = nil
          }
          // The value of these properties may contain links, if so make them clickable.
          if k == MPVProperty.path || k == commentKey, let value, let link = self.formLink(value) {
            v.attributedStringValue = link
            // Must enable this for the link to be clickable.
            v.allowsEditingTextAttributes = true
          } else {
            v.stringValue = value ?? NSLocalizedString("general.na", comment: "N/A")
            v.allowsEditingTextAttributes = false
          }
          v.isSelectable = value != nil
          self.setLabelColor(v, by: value != nil)
        }

        // other properties

        let duration = controller.getDouble(MPVProperty.duration)
        self.durationField.stringValue = VideoTime(duration).stringRepresentation

        let vwidth = controller.getInt(MPVProperty.width)
        let vheight = controller.getInt(MPVProperty.height)
        self.vsizeField.stringValue = "\(vwidth)\u{d7}\(vheight)"

        let fileSize = controller.getInt(MPVProperty.fileSize)
        self.fileSizeField.stringValue = "\(FloatingPointByteCountFormatter.string(fromByteCount: fileSize))B"

        // track list

        self.trackPopup.removeAllItems()
        var needSeparator = false
        for track in info.videoTracks {
          self.trackPopup.menu?.addItem(withTitle: NSLocalizedString("track.video", comment: "Video") + track.readableTitle,
                                   action: nil, tag: nil, obj: track, stateOn: false)
          needSeparator = true
        }
        if needSeparator && !info.audioTracks.isEmpty {
          self.trackPopup.menu?.addItem(NSMenuItem.separator())
        }
        for track in info.audioTracks {
          self.trackPopup.menu?.addItem(withTitle: NSLocalizedString("track.audio", comment: "Audio") + track.readableTitle,
                                   action: nil, tag: nil, obj: track, stateOn: false)
          needSeparator = true
        }
        if needSeparator && !info.subTracks.isEmpty {
          self.trackPopup.menu?.addItem(NSMenuItem.separator())
        }
        for track in info.subTracks {
          self.trackPopup.menu?.addItem(withTitle: NSLocalizedString("track.sub", comment: "Subtitle") + track.readableTitle,
                                   action: nil, tag: nil, obj: track, stateOn: false)
        }
        self.trackPopup.selectItem(at: 0)
        self.updateTrack()
      }

      let vbitrate = controller.getInt(MPVProperty.videoBitrate)
      self.vbitrateField.stringValue = FloatingPointByteCountFormatter.string(fromByteCount: vbitrate) + "bps"

      let abitrate = controller.getInt(MPVProperty.audioBitrate)
      self.abitrateField.stringValue = FloatingPointByteCountFormatter.string(fromByteCount: abitrate) + "bps"

      let dynamicStrProperties: [String: NSTextField] = [
        // At any point in time while the video is playing hardware decoding may fail causing a fall
        // back to software decoding.
        MPVProperty.hwdecCurrent: self.vdecoderField,
        MPVProperty.avsync: self.avsyncField,
        MPVProperty.totalAvsyncChange: self.totalAvsyncField,
        MPVProperty.frameDropCount: self.droppedFramesField,
        MPVProperty.mistimedFrameCount: self.mistimedFramesField,
        MPVProperty.displayFps: self.displayFPSField,
        MPVProperty.estimatedVfFps: self.voFPSField,
        MPVProperty.estimatedDisplayFps: self.edispFPSField,
        MPVProperty.currentAo: self.aoField,
      ]

      for (k, v) in dynamicStrProperties {
        let value = controller.getString(k)
        v.stringValue = value ?? NSLocalizedString("general.na", comment: "N/A")
        v.isSelectable = value != nil
        self.setLabelColor(v, by: value != nil)
      }

      let sigPeak = controller.getDouble(MPVProperty.videoParamsSigPeak);
      self.vprimariesField.stringValue = sigPeak > 0
        ? "\(controller.getString(MPVProperty.videoParamsPrimaries) ?? "?") / \(controller.getString(MPVProperty.videoParamsGamma) ?? "?") (\(sigPeak > 1 ? "H" : "S")DR)"
        : NSLocalizedString("general.na", comment: "N/A");
      self.vprimariesField.isSelectable = sigPeak > 0
      self.setLabelColor(self.vprimariesField, by: sigPeak > 0)

      let player = PlayerCore.lastActive
      if player.mainWindow.loaded && player.info.state.loaded {
        if let colorspace = player.mainWindow.videoView.videoLayer.colorspace {
          let screenColorSpace = player.mainWindow.window?.screen?.colorSpace
          let sdrColorSpace = screenColorSpace?.cgColorSpace ?? VideoView.SRGB
          let isHdr = colorspace != sdrColorSpace
          // Prefer the name of the CGColorSpace of the layer. If the CGColorSpace does not have a
          // name then if the layer is set to the color space of the screen then fall back to the
          // localized name on the NSColorSpace, if present. Otherwise report it as unspecified.
          let name: String = {
            if let name = colorspace.name { return name as String }
            if let screenColorSpace, colorspace == screenColorSpace.cgColorSpace,
               let name = screenColorSpace.localizedName { return name }
            return "Unspecified"
          }()
          self.vcolorspaceField.stringValue = "\(name) (\(isHdr ? "H" : "S")DR)"
        } else {
          self.vcolorspaceField.stringValue = "Unspecified (SDR)"
        }
        self.vcolorspaceField.isSelectable = true
      } else {
        self.vcolorspaceField.stringValue = NSLocalizedString("general.na", comment: "N/A")
        self.vcolorspaceField.isSelectable = false
      }
      self.setLabelColor(self.vcolorspaceField, by: player.info.state.loaded)

      if player.mainWindow.loaded && player.info.state.loaded {
        if let hwPf = controller.getString(MPVProperty.videoParamsHwPixelformat) {
          self.vPixelFormat.stringValue = "\(hwPf) (HW)"
          self.vPixelFormat.isSelectable = true
        } else if let swPf = controller.getString(MPVProperty.videoParamsPixelformat) {
          self.vPixelFormat.stringValue = "\(swPf) (SW)"
          self.vPixelFormat.isSelectable = true
        } else {
          self.vPixelFormat.stringValue = NSLocalizedString("general.na", comment: "N/A")
          self.vPixelFormat.isSelectable = false
        }
      }
      self.setLabelColor(self.vPixelFormat, by: player.info.state.loaded)
      self.updateDiagnostics(controller: controller, info: info)
    }
  }

  func fileLoaded(_ notification: Notification) {
    updateInfo()
  }

  @objc func dynamicUpdate() {
    updateInfo(dynamic: true)
    /// Do not call `reloadData()` (no arg version) because it will clear the selection. Also, because we know the number of rows will not change,
    /// calling `reloadData(forRowIndexes:)` will get the same result but much more efficiently
    watchTableView.reloadData(forRowIndexes: IndexSet(0..<watchTableView.numberOfRows), columnIndexes: IndexSet(0..<watchTableView.numberOfColumns))
  }

  func updateTrack() {
    guard let track = trackPopup.selectedItem?.representedObject as? MPVTrack else { return }

    trackIdField.stringValue = "\(track.id)"
    setLabelColor(trackDefaultField, by: track.isDefault)
    setLabelColor(trackForcedField, by: track.isForced)
    setLabelColor(trackSelectedField, by: track.isSelected)
    setLabelColor(trackExternalField, by: track.isExternal)

    let strProperties: [(String?, NSTextField)] = [
      (track.srcId?.description, trackSourceIdField),
      (track.title, trackTitleField),
      (track.readableLanguage, trackLangField),
      (track.externalFilename, trackFilePathField),
      (track.codec, trackCodecField),
      (track.decoderDesc, trackDecoderField),
      (track.demuxFps?.description, trackFPSField),
      (track.demuxChannels, trackChannelsField),
      (track.demuxSamplerate?.description, trackSampleRateField)
    ]

    for (str, field) in strProperties {
      field.stringValue = str ?? NSLocalizedString("general.na", comment: "N/A")
      field.isSelectable = str != nil
      setLabelColor(field, by: str != nil)
    }
    updateTrackDiagnostics(track)
  }

  // MARK: - NSTableView

  func numberOfRows(in tableView: NSTableView) -> Int {
    return watchProperties.count
  }

  func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
    guard let identifier = tableColumn?.identifier else { return nil }
    guard let cell = watchTableView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView else {
      return nil
    }
    guard let property = watchProperties[at: row] else { return nil }

    switch identifier {
    case .key:
      if let textField = cell.textField {
        textField.stringValue =  property
      }
      return cell
    case .value:
      let player = PlayerCore.lastActive

      if let textField = cell.textField {
        textField.allowsEditingTextAttributes = false
        if player.info.state.active, let value = player.mpv.getString(property) {
          if let link = formLink(value) {
            textField.attributedStringValue = link
            // Must enable this for the link to be clickable.
            textField.allowsEditingTextAttributes = true
          } else {
            textField.stringValue = value
          }
          textField.isSelectable = true
          textField.textColor = .labelColor
        } else {
          let errorString = NSLocalizedString("inspector.error", comment: "Error")

          let italicDescriptor: NSFontDescriptor = textField.font!.fontDescriptor.withSymbolicTraits(NSFontDescriptor.SymbolicTraits.italic)
          let errorFont = NSFont(descriptor: italicDescriptor, size: textField.font!.pointSize)

          textField.attributedStringValue = NSMutableAttributedString(string: errorString, attributes: [.font: errorFont!])
          textField.isSelectable = false
          textField.textColor = .disabledControlTextColor
        }
      }
      return cell
    default:
      log("Unrecognized column: '\(identifier.rawValue)'", level: .error)
      return nil
    }
  }

  func tableView(_ tableView: NSTableView, didAdd rowView: NSTableRowView, forRow row: Int) {
    /// The background color for a `NSTableRowView` will default to the parent's background color, which results in an
    /// unwanted additive effect for translucent backgrounds. Just make each row transparent.
    rowView.backgroundColor = .clear
  }

  func tableViewSelectionDidChange(_ notification: Notification) {
    deleteButton.isEnabled = !watchTableView.selectedRowIndexes.isEmpty
  }

  func resizeTableColumns(forTableWidth tableWidth: CGFloat) {
    guard let keyColumn = watchTableView.tableColumn(withIdentifier: .key),
          let valueColumn = watchTableView.tableColumn(withIdentifier: .value),
          let tableScrollView = watchTableView.enclosingScrollView else {
      return
    }

    let adjustedTableWidth = tableWidth - tableScrollView.verticalScroller!.frame.width
    let keyColumnMaxWidth = adjustedTableWidth - valueColumn.minWidth
    var newKeyColumnWidth = keyColumn.width
    if keyColumn.width > keyColumnMaxWidth {
      newKeyColumnWidth = keyColumnMaxWidth
      keyColumn.width = newKeyColumnWidth
    }
    valueColumn.width = adjustedTableWidth - newKeyColumnWidth
    tableScrollView.needsLayout = true
    tableScrollView.needsDisplay = true
  }

  func windowWillResize(_ sender: NSWindow, to newWindowSize: NSSize) -> NSSize {
    if let window = window, window.inLiveResize {
      /// Table size will change with window size, so need to find the new table width from `newWindowSize`.
      /// We know that our window's width is composed of 2 things: the table width + all other fixed "non-table" stuff.
      /// We first find the non-table width by subtracting current table size from current window size.
      /// Note: `NSTableView` does not give an honest answer for its width, but can use its parent (`NSClipView`) width.
      let oldTableWidth = watchTableView.superview!.frame.width
      let nonTableWidth = window.frame.width - oldTableWidth
      let newTableWidth = newWindowSize.width - nonTableWidth
      resizeTableColumns(forTableWidth: newTableWidth)
    }

    return newWindowSize
  }

  func windowDidResize(_ notification: Notification) {
    if let window = window, window.inLiveResize {
      let tableWidth = watchTableView.superview!.frame.width
      resizeTableColumns(forTableWidth: tableWidth)
    }
  }

  @IBAction func addWatchAction(_ sender: AnyObject) {
    Utility.quickPromptPanel("add_watch", sheetWindow: window) { [self] str in
      self.watchProperties.append(str)
      self.saveWatchList()

      // Append row to end of table, with animation if preferred
      let insertIndexSet = IndexSet(integer: watchTableView.numberOfRows)
      watchTableView.insertRows(at: insertIndexSet, withAnimation: AccessibilityPreferences.motionReductionEnabled ? [] : .slideDown)
      watchTableView.selectRowIndexes(insertIndexSet, byExtendingSelection: false)
      tableHeightConstraint?.constant = computeMinTableHeight()
      watchTableContainerView.layout()
    }
  }

  @IBAction func removeWatchAction(_ sender: AnyObject) {
    let rowIndexes = watchTableView.selectedRowIndexes
    guard !rowIndexes.isEmpty else { return }

    let watchPropertiesOld = watchProperties
    var watchPropertiesNew: [String] = []
    for (index, property) in watchPropertiesOld.enumerated() {
      if !rowIndexes.contains(index) {
        watchPropertiesNew.append(property)
      }
    }
    watchProperties = watchPropertiesNew
    saveWatchList()

    watchTableView.removeRows(at: rowIndexes, withAnimation: AccessibilityPreferences.motionReductionEnabled ? [] : .slideUp)
    tableHeightConstraint?.constant = computeMinTableHeight()
    watchTableContainerView.layout()
  }


  // MARK: - IBActions

  @IBAction func tabSwitched(_ sender: NSSegmentedControl) {
    tabView.selectTabViewItem(at: sender.selectedSegment)
  }

  @IBAction func trackSwitched(_ sender: AnyObject) {
    updateTrack()
  }


  // MARK: - Utils

  /// Form a link from the given string.
  /// - Parameter value: String value that may be a link.
  /// - Returns: If `value` should be represented as a clickable link, an attributed string containing a link, otherwise ` nil`.
  private func formLink(_ value: String) -> NSAttributedString? {
    guard let url = URL(string: value), let scheme = url.scheme,
          scheme == "http" || scheme == "https" else { return nil }
      return NSAttributedString(string: value, attributes: [.link: url])
  }

  private func log(_ message: @autoclosure () -> String, level: Logger.Level = .debug) {
    Logger.log(message, level: level, subsystem: Logger.Sub.inspector)
  }

  private func setLabelColor(_ label: NSTextField, by state: Bool) {
    label.textColor = state ? NSColor.labelColor : NSColor.disabledControlTextColor
  }

  private func saveWatchList() {
    Preference.set(watchProperties, for: .watchProperties)
  }

  class WatchTableColumnHeaderCell: NSTableHeaderCell {
    override func draw(withFrame cellFrame: NSRect, in controlView: NSView) {
      // Override background color
      self.drawsBackground = false
      watchTableColumnHeaderColor.set()
      cellFrame.fill(using: .sourceOver)

      super.draw(withFrame: cellFrame, in: controlView)
    }
  }
}

private extension InspectorWindowController {

  var generalDiagnosticSections: [InspectorSection] {
    [
      ("Video Source", [
        ("g.video.codec", "Codec"),
        ("g.video.profile", "Profile / level"),
        ("g.video.size", "Coded / display size"),
        ("g.video.crop", "Crop"),
        ("g.video.aspect", "Aspect / pixel aspect"),
        ("g.video.scan", "Scan"),
        ("g.video.fps", "Frame rate"),
        ("g.video.bitrate", "Bit rate"),
        ("g.video.pixel", "Pixel format"),
        ("g.video.depth", "Bit depth / chroma"),
      ]),
      ("Source Colour", [
        ("g.color.matrix", "Matrix / range"),
        ("g.color.primaries", "Primaries / transfer"),
        ("g.color.chroma", "Chroma location"),
        ("g.color.mastering", "Mastering luminance"),
        ("g.color.light", "MaxCLL / MaxFALL"),
      ]),
      ("HDR", [
        ("g.hdr.format", "Format"),
        ("g.hdr.metadata", "Metadata"),
        ("g.hdr.peak", "Source peak / average"),
        ("g.hdr.output", "Output handling"),
      ]),
      ("Dolby Vision", [
        ("g.dv.profile", "Profile / level"),
        ("g.dv.layers", "Layers"),
        ("g.dv.mode", "Enhancement mode"),
        ("g.dv.rpu", "RPU metadata"),
        ("g.dv.composition", "Composition"),
        ("g.dv.health", "Pairing health"),
        ("g.dv.decoders", "BL / EL decode"),
      ]),
      ("Video Decoder & Renderer", [
        ("g.render.decoder", "Decoder"),
        ("g.render.hwdec", "Hardware decode"),
        ("g.render.interop", "Hardware interop"),
        ("g.render.vo", "Video output"),
        ("g.render.gpu", "GPU context"),
        ("g.render.path", "Render path"),
        ("g.render.filters", "Video filters"),
        ("g.render.scaling", "Scaling"),
        ("g.render.tone", "Tone mapping"),
        ("g.render.dither", "Dithering"),
      ]),
      ("Display & Output", [
        ("g.display.name", "Display"),
        ("g.display.size", "Display / output size"),
        ("g.display.refresh", "Refresh rate"),
        ("g.display.colorspace", "Layer colour space"),
        ("g.display.target", "Target colour"),
        ("g.display.edr", "EDR headroom"),
      ]),
      ("Audio Source", [
        ("g.audio.codec", "Codec"),
        ("g.audio.profile", "Profile"),
        ("g.audio.decoder", "Decoder"),
        ("g.audio.bitrate", "Bit rate"),
        ("g.audio.input", "Input format"),
        ("g.audio.loss", "Compression"),
      ]),
      ("Object Audio", [
        ("g.object.class", "Presentation"),
        ("g.object.bed", "Bed / objects"),
        ("g.object.dialnorm", "DialNorm"),
        ("g.object.substreams", "Substreams"),
      ]),
      ("Audio Pipeline", [
        ("g.pipeline.route", "Active route"),
        ("g.pipeline.transport", "Transport"),
        ("g.pipeline.spatial", "Spatial path"),
        ("g.pipeline.state", "Route state"),
        ("g.pipeline.fallback", "Fallback"),
      ]),
      ("Audio Output", [
        ("g.output.driver", "Audio output"),
        ("g.output.device", "Device"),
        ("g.output.format", "Output format"),
        ("g.output.layout", "Output layout"),
        ("g.output.spatial", "Spatial layout"),
        ("g.output.delay", "Output delay"),
      ]),
    ]
  }

  var trackDiagnosticSections: [InspectorSection] {
    [
      ("Identity", [
        ("t.identity.type", "Type"),
        ("t.identity.ids", "Track / source / FFmpeg ID"),
        ("t.identity.program", "Program IDs"),
        ("t.identity.title", "Title"),
        ("t.identity.language", "Language"),
        ("t.identity.path", "External path"),
      ]),
      ("Roles", [
        ("t.roles.selection", "Selection"),
        ("t.roles.flags", "Roles"),
        ("t.roles.media", "Media flags"),
      ]),
      ("Codec", [
        ("t.codec.name", "Codec"),
        ("t.codec.profile", "Profile / level"),
        ("t.codec.decoder", "Decoder"),
        ("t.codec.format", "Format"),
        ("t.codec.bitrate", "Bit rate"),
        ("t.codec.duration", "Duration"),
        ("t.codec.hls", "HLS bit rate"),
      ]),
      ("Video", [
        ("t.video.size", "Size / crop"),
        ("t.video.fps", "Frame rate"),
        ("t.video.aspect", "Pixel aspect / rotation"),
        ("t.video.dv", "Dolby Vision"),
      ]),
      ("Audio", [
        ("t.audio.channels", "Channels"),
        ("t.audio.rate", "Sample rate"),
        ("t.audio.depth", "Sample format / depth"),
        ("t.audio.object", "Object audio"),
        ("t.audio.replaygain", "ReplayGain"),
      ]),
      ("Subtitle", [
        ("t.sub.type", "Subtitle type"),
        ("t.sub.canvas", "Canvas / frame rate"),
        ("t.sub.roles", "Subtitle roles"),
        ("t.sub.encoding", "External encoding"),
      ]),
    ]
  }

  var fileDiagnosticSections: [InspectorSection] {
    [
      ("Identity", [
        ("f.identity.path", "Path / URL"),
        ("f.identity.name", "Filename"),
        ("f.identity.title", "Title"),
        ("f.identity.comment", "Comment"),
        ("f.identity.size", "Size"),
        ("f.identity.duration", "Duration"),
        ("f.identity.kind", "Source"),
      ]),
      ("Container", [
        ("f.container.format", "Format / demuxer"),
        ("f.container.protocol", "Protocol"),
        ("f.container.stream", "Opened stream"),
        ("f.container.start", "Start time"),
        ("f.container.seek", "Seekability"),
        ("f.container.bitrate", "Aggregate bit rate"),
        ("f.container.tracks", "Streams"),
      ]),
      ("Metadata", [
        ("f.metadata.primary", "Primary"),
        ("f.metadata.credits", "Credits"),
        ("f.metadata.technical", "Technical"),
        ("f.metadata.all", "All metadata"),
      ]),
      ("Structure", [
        ("f.structure.chapters", "Chapters"),
        ("f.structure.editions", "Editions"),
        ("f.structure.programs", "Programs"),
        ("f.structure.playlist", "Playlist"),
        ("f.structure.attachments", "Attachments / cover art"),
      ]),
    ]
  }

  var statusDiagnosticSections: [InspectorSection] {
    [
      ("Playback", [
        ("s.playback.state", "State"),
        ("s.playback.position", "Position"),
        ("s.playback.remaining", "Remaining"),
        ("s.playback.speed", "Speed"),
        ("s.playback.chapter", "Chapter / edition"),
      ]),
      ("Synchronization", [
        ("s.sync.av", "A/V sync"),
        ("s.sync.total", "Total correction"),
        ("s.sync.pts", "Audio / video PTS"),
        ("s.sync.speed", "Speed correction"),
        ("s.sync.display", "Display sync"),
        ("s.sync.delay", "Audio delay"),
      ]),
      ("Frame Health", [
        ("s.frames.presented", "Frame"),
        ("s.frames.dropped", "Dropped"),
        ("s.frames.delayed", "Delayed / mistimed"),
        ("s.frames.info", "Current picture"),
      ]),
      ("Frame Pacing", [
        ("s.pacing.fps", "Source / output FPS"),
        ("s.pacing.display", "Display FPS"),
        ("s.pacing.vsync", "VSync ratio / jitter"),
        ("s.pacing.render", "Renderer timing"),
      ]),
      ("Dolby Vision Runtime", [
        ("s.dv.mode", "Mode / composition"),
        ("s.dv.pair", "Current BL/EL pair"),
        ("s.dv.counts", "Paired / missing / late"),
        ("s.dv.queues", "BL / EL queues"),
        ("s.dv.metadata", "Current metadata"),
      ]),
      ("Audio Runtime", [
        ("s.audio.route", "Route / decoder"),
        ("s.audio.layouts", "Input / output"),
        ("s.audio.objects", "Objects / bed"),
        ("s.audio.player", "AVPlayer / renderer"),
        ("s.audio.latency", "Output delay"),
      ]),
      ("Cache & Network", [
        ("s.cache.state", "State"),
        ("s.cache.duration", "Buffered duration"),
        ("s.cache.bytes", "Buffered bytes"),
        ("s.cache.rate", "Input rate"),
        ("s.cache.range", "Reader / cache end"),
        ("s.cache.flags", "BOF / EOF cached"),
      ]),
      ("Display", [
        ("s.display.name", "Display"),
        ("s.display.size", "Resolution / scale"),
        ("s.display.refresh", "Refresh"),
        ("s.display.color", "Colour / EDR"),
      ]),
      ("Versions", [
        ("s.version.iina", "IINA"),
        ("s.version.mpv", "mpv"),
        ("s.version.ffmpeg", "FFmpeg"),
        ("s.version.libass", "libass"),
        ("s.version.platform", "Platform"),
        ("s.version.build", "Build"),
      ]),
    ]
  }

  func installDiagnosticPages() {
    window?.minSize = NSSize(width: 560, height: 480)
    window?.setContentSize(NSSize(width: 720, height: 640))

    let pages = [
      generalDiagnosticSections,
      trackDiagnosticSections,
      fileDiagnosticSections,
      statusDiagnosticSections,
    ]

    for (pageIndex, sections) in pages.enumerated() {
      guard let page = tabView.tabViewItem(at: pageIndex).view else { continue }
      let legacyViews = page.subviews

      let scrollView = NSScrollView()
      scrollView.translatesAutoresizingMaskIntoConstraints = false
      scrollView.drawsBackground = false
      scrollView.hasVerticalScroller = true
      scrollView.autohidesScrollers = true

      let documentView = NSView()
      documentView.translatesAutoresizingMaskIntoConstraints = false
      let stack = NSStackView()
      stack.translatesAutoresizingMaskIntoConstraints = false
      stack.orientation = .vertical
      stack.alignment = .leading
      stack.spacing = 18

      documentView.addSubview(stack)
      scrollView.documentView = documentView
      page.addSubview(scrollView)

      NSLayoutConstraint.activate([
        scrollView.leadingAnchor.constraint(equalTo: page.leadingAnchor),
        scrollView.trailingAnchor.constraint(equalTo: page.trailingAnchor),
        scrollView.topAnchor.constraint(equalTo: page.topAnchor),
        scrollView.bottomAnchor.constraint(equalTo: page.bottomAnchor),
        documentView.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),
        stack.leadingAnchor.constraint(equalTo: documentView.leadingAnchor, constant: 18),
        stack.trailingAnchor.constraint(equalTo: documentView.trailingAnchor, constant: -18),
        stack.topAnchor.constraint(equalTo: documentView.topAnchor, constant: 16),
        stack.bottomAnchor.constraint(equalTo: documentView.bottomAnchor, constant: -18),
      ])

      if pageIndex == 1 {
        trackPopup.removeFromSuperview()
        trackPopup.translatesAutoresizingMaskIntoConstraints = false
        let label = NSTextField(labelWithString: "Track")
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
        label.textColor = .secondaryLabelColor
        let header = NSStackView(views: [label, trackPopup])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 10
        addFullWidth(header, to: stack)
        trackPopup.widthAnchor.constraint(greaterThanOrEqualToConstant: 400).isActive = true
      }

      for section in sections {
        addFullWidth(makeDiagnosticSection(section, pageIndex: pageIndex), to: stack)
      }

      if pageIndex == 3 {
        addFullWidth(makeWatchSection(), to: stack)
      }

      let copyPage = NSButton(title: "Copy Page", target: self,
                              action: #selector(copyCurrentInspectorPage(_:)))
      let buttons = pageIndex == 3
        ? [copyPage, NSButton(title: "Copy Report", target: self,
                             action: #selector(copyInspectorReport(_:)))]
        : [copyPage]
      let buttonRow = NSStackView(views: buttons)
      buttonRow.orientation = .horizontal
      buttonRow.spacing = 8
      addFullWidth(buttonRow, to: stack)

      // The XIB's own fields are superseded by the sections above. Keep them in
      // the hierarchy (the outlets are weak) but out of sight.
      for view in legacyViews where view.superview === page {
        view.isHidden = true
      }
    }
  }

  /// Stack views place arranged subviews by gravity, which leaves a narrower
  /// block floating in the stack. Pin both edges so every row spans the page.
  func addFullWidth(_ view: NSView, to stack: NSStackView) {
    stack.addArrangedSubview(view)
    view.leadingAnchor.constraint(equalTo: stack.leadingAnchor).isActive = true
    view.trailingAnchor.constraint(equalTo: stack.trailingAnchor).isActive = true
  }

  func makeDiagnosticSection(_ section: InspectorSection, pageIndex: Int) -> NSView {
    let container = NSStackView()
    container.orientation = .vertical
    container.alignment = .leading
    container.spacing = 6

    let title = NSTextField(labelWithString: section.title.uppercased())
    title.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
    title.textColor = .secondaryLabelColor
    addFullWidth(title, to: container)

    let gridRows = section.rows.map { row -> NSView in
      let label = NSTextField(labelWithString: row.label)
      label.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
      label.textColor = .secondaryLabelColor
      label.alignment = .right
      label.setContentHuggingPriority(.required, for: .horizontal)
      label.setContentCompressionResistancePriority(.required, for: .horizontal)
      label.widthAnchor.constraint(equalToConstant: 156).isActive = true

      let value = NSTextField(wrappingLabelWithString: NSLocalizedString("general.na", comment: "N/A"))
      value.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
      value.isSelectable = true
      value.maximumNumberOfLines = 0
      value.setContentHuggingPriority(.defaultLow, for: .horizontal)
      value.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

      diagnosticFields[row.key] = value
      diagnosticLabels[row.key] = row.label
      diagnosticPageKeys[pageIndex].append(row.key)

      let line = NSStackView(views: [label, value])
      line.orientation = .horizontal
      line.alignment = .firstBaseline
      line.spacing = 12
      return line
    }

    for line in gridRows {
      addFullWidth(line, to: container)
    }
    container.setCustomSpacing(6, after: title)
    return container
  }

  func makeWatchSection() -> NSView {
    let container = NSStackView()
    container.orientation = .vertical
    container.alignment = .leading
    container.spacing = 8

    let title = NSTextField(labelWithString: "CUSTOM PROPERTIES")
    title.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
    title.textColor = .secondaryLabelColor
    addFullWidth(title, to: container)

    watchTableContainerView.removeFromSuperview()
    watchTableContainerView.translatesAutoresizingMaskIntoConstraints = false
    addFullWidth(watchTableContainerView, to: container)

    deleteButton.removeFromSuperview()
    // The XIB button is the round "−"; drop the glyph so the title is readable.
    deleteButton.image = nil
    deleteButton.imagePosition = .noImage
    deleteButton.bezelStyle = .rounded
    deleteButton.title = "Remove"
    let addButton = NSButton(title: "Add", target: self, action: #selector(addWatchAction(_:)))
    let buttons = NSStackView(views: [addButton, deleteButton])
    buttons.orientation = .horizontal
    buttons.spacing = 8
    addFullWidth(buttons, to: container)
    return container
  }

  @objc func copyCurrentInspectorPage(_ sender: Any?) {
    guard let selected = tabView.selectedTabViewItem else { return }
    copyDiagnostics(keys: diagnosticPageKeys[tabView.indexOfTabViewItem(selected)])
  }

  @objc func copyInspectorReport(_ sender: Any?) {
    copyDiagnostics(keys: diagnosticPageKeys.flatMap { $0 })
  }

  func copyDiagnostics(keys: [String]) {
    let text = keys.compactMap { key -> String? in
      guard let label = diagnosticLabels[key], let value = diagnosticFields[key]?.stringValue else { return nil }
      return "\(label): \(value)"
    }.joined(separator: "\n")
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
  }
}

private extension InspectorWindowController {

  func updateDiagnostics(controller: MPVController, info: PlaybackInfo) {
    let video = info.videoTracks.first(where: \.isSelected)
    let audio = info.audioTracks.first(where: \.isSelected)
    updateGeneralDiagnostics(controller: controller, info: info, video: video, audio: audio)
    updateFileDiagnostics(controller: controller, info: info)
    updateStatusDiagnostics(controller: controller, audio: audio)
  }

  func setDiagnostic(_ key: String, _ value: String?) {
    guard let field = diagnosticFields[key] else { return }
    let value = value?.trimmingCharacters(in: .whitespacesAndNewlines)
    let available = value?.isEmpty == false
    field.stringValue = available ? value! : NSLocalizedString("general.na", comment: "N/A")
    field.textColor = available ? .labelColor : .disabledControlTextColor
    field.isSelectable = available
  }

  func property(_ controller: MPVController, _ name: String) -> String? {
    guard let value = controller.getString(name)?.trimmingCharacters(in: .whitespacesAndNewlines),
          !value.isEmpty else { return nil }
    return value
  }

  func propertyDouble(_ controller: MPVController, _ name: String) -> Double? {
    property(controller, name).flatMap(Double.init)
  }

  func propertyInt(_ controller: MPVController, _ name: String) -> Int64? {
    property(controller, name).flatMap(Int64.init)
  }

  func join(_ values: [String?], separator: String = " · ") -> String? {
    let values = values.compactMap { value -> String? in
      guard let value, !value.isEmpty else { return nil }
      return value
    }
    return values.isEmpty ? nil : values.joined(separator: separator)
  }

  func formatBitrate(_ value: Int?) -> String? {
    guard let value, value > 0 else { return nil }
    if value >= 1_000_000 { return String(format: "%.2f Mbps", Double(value) / 1_000_000) }
    if value >= 1_000 { return String(format: "%.1f kbps", Double(value) / 1_000) }
    return "\(value) bps"
  }

  func formatBytes(_ value: Int64?) -> String? {
    guard let value, value >= 0 else { return nil }
    return "\(FloatingPointByteCountFormatter.string(fromByteCount: Int(value)))B"
  }

  func formatTime(_ value: Double?) -> String? {
    guard let value, value.isFinite, value >= 0 else { return nil }
    return VideoTime(value).stringRepresentation
  }

  func codecLevel(_ codec: String?, _ level: Int?) -> String? {
    guard let level, level > 0 else { return nil }
    switch codec {
    case "hevc":
      return String(format: "%.1f", Double(level) / 30)
    case "h264":
      return String(format: "%.1f", Double(level) / 10)
    default:
      return "\(level)"
    }
  }

  func pixelDetails(_ pixelFormat: String?, bits: Int?) -> String? {
    guard let pixelFormat else { return bits.map { "\($0)-bit" } }
    let lower = pixelFormat.lowercased()
    let depth: String? = {
      if let bits, bits > 0 { return "\(bits)-bit" }
      if lower.contains("12") { return "12-bit" }
      if lower.contains("10") || lower.contains("p010") { return "10-bit" }
      if lower.contains("16") { return "16-bit" }
      return lower.contains("8") || lower.contains("420") ? "8-bit" : nil
    }()
    let chroma: String? = {
      if lower.contains("420") || lower.contains("p010") { return "4:2:0" }
      if lower.contains("422") { return "4:2:2" }
      if lower.contains("444") { return "4:4:4" }
      if lower.contains("rgb") || lower.contains("gbr") { return "RGB" }
      return nil
    }()
    return join([depth, chroma])
  }

  func objectCount(from profile: String?) -> String? {
    guard let profile,
          let range = profile.range(of: #"\d+ objects"#, options: .regularExpression) else { return nil }
    return String(profile[range])
  }

  func dialNorm(from profile: String?) -> String? {
    guard let profile,
          let range = profile.range(of: #"DialNorm -?\d+ dB"#, options: .regularExpression) else { return nil }
    return String(profile[range])
  }

  func bedLayout(from profile: String?) -> String? {
    guard let profile, let objects = objectCount(from: profile),
          let objectRange = profile.range(of: objects),
          let separator = profile[..<objectRange.lowerBound].lastIndex(of: "·") else { return nil }
    let bed = profile[profile.index(after: separator)..<objectRange.lowerBound]
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .trimmingCharacters(in: CharacterSet(charactersIn: "+"))
    return bed.isEmpty ? nil : bed
  }

  func metadataMap(_ controller: MPVController) -> [String: String] {
    controller.getNode(MPVProperty.metadata) as? [String: String] ?? [:]
  }

  func metadataValue(_ metadata: [String: String], _ keys: String...) -> String? {
    for key in keys {
      if let match = metadata.first(where: { $0.key.caseInsensitiveCompare(key) == .orderedSame }) {
        return match.value
      }
    }
    return nil
  }

  func updateGeneralDiagnostics(controller: MPVController, info: PlaybackInfo,
                                video: MPVTrack?, audio: MPVTrack?) {
  let sourcePixel = property(controller, "video-dec-params/pixelformat")
    ?? property(controller, MPVProperty.videoParamsPixelformat)
  let displayWidth = property(controller, "video-params/dw")
  let displayHeight = property(controller, "video-params/dh")
  let cropWidth = property(controller, "video-dec-params/crop-w")
  let cropHeight = property(controller, "video-dec-params/crop-h")
  let cropX = property(controller, "video-dec-params/crop-x")
  let cropY = property(controller, "video-dec-params/crop-y")

  setDiagnostic("g.video.codec", join([video?.codecDesc, video?.codec]))
  setDiagnostic("g.video.profile", join([
    video?.codecProfile,
    codecLevel(video?.codec, video?.codecLevel).map { "Level \($0)" },
  ]))
  setDiagnostic("g.video.size", join([
    video.flatMap { track in
      guard let w = track.demuxW, let h = track.demuxH, w > 0, h > 0 else { return nil }
      return "\(w)×\(h) coded"
    },
    displayWidth.flatMap { w in displayHeight.map { "\(w)×\($0) display" } },
  ]))
  setDiagnostic("g.video.crop", cropWidth.flatMap { w in
    cropHeight.map { "\(w)×\($0) at \(cropX ?? "0"),\(cropY ?? "0")" }
  })
  setDiagnostic("g.video.aspect", join([
    property(controller, "video-dec-params/aspect-name")
      ?? property(controller, "video-dec-params/aspect"),
    property(controller, "video-dec-params/par").map { "PAR \($0)" },
  ]))
  let interlaced = property(controller, "video-frame-info/interlaced")
  let fieldOrder = property(controller, "video-frame-info/tff") == "yes" ? "top field first" : "bottom field first"
  setDiagnostic("g.video.scan", interlaced == "yes" ? "Interlaced · \(fieldOrder)" : "Progressive")
  setDiagnostic("g.video.fps", join([
    video?.demuxFps.map { String(format: "%.3f fps container", $0) },
    propertyDouble(controller, MPVProperty.estimatedVfFps).map { String(format: "%.3f fps output", $0) },
  ]))
  setDiagnostic("g.video.bitrate", formatBitrate(Int(propertyInt(controller, MPVProperty.videoBitrate) ?? Int64(video?.demuxBitrate ?? 0))))
  setDiagnostic("g.video.pixel", sourcePixel)
  setDiagnostic("g.video.depth", pixelDetails(sourcePixel, bits: video?.bitsPerSample))

  let matrix = property(controller, "video-dec-params/colormatrix")
  let range = property(controller, "video-dec-params/colorlevels")
  let primaries = property(controller, "video-dec-params/primaries")
  let transfer = property(controller, "video-dec-params/gamma")
  setDiagnostic("g.color.matrix", join([matrix, range]))
  setDiagnostic("g.color.primaries", join([primaries, transfer]))
  setDiagnostic("g.color.chroma", property(controller, "video-dec-params/chroma-location"))
  setDiagnostic("g.color.mastering", join([
    property(controller, "video-dec-params/min-luma").map { "min \($0) cd/m²" },
    property(controller, "video-dec-params/max-luma").map { "max \($0) cd/m²" },
  ]))
  setDiagnostic("g.color.light", join([
    property(controller, "video-dec-params/max-cll").map { "MaxCLL \($0)" },
    property(controller, "video-dec-params/max-fall").map { "MaxFALL \($0)" },
  ]))

  let dvProfile = property(controller, "current-tracks/video/dolby-vision-profile")
    ?? video?.dolbyVisionProfile.map(String.init)
  let dvLevel = property(controller, "current-tracks/video/dolby-vision-level")
    ?? video?.dolbyVisionLevel.map(String.init)
  let hdr10Plus = property(controller, "video-params/scene-avg") != nil
  let hdrFormat: String = {
    if dvProfile != nil { return "Dolby Vision" }
    if hdr10Plus { return "HDR10+" }
    if transfer == "pq" { return "HDR10" }
    if transfer == "hlg" { return "HLG" }
    return "SDR"
  }()
  setDiagnostic("g.hdr.format", hdrFormat)
  setDiagnostic("g.hdr.metadata", dvProfile != nil ? "Dynamic Dolby Vision RPU" :
    hdr10Plus ? "Dynamic HDR10+" :
    transfer == "pq" ? "Static HDR10" : "None")
  setDiagnostic("g.hdr.peak", join([
    property(controller, "video-params/max-pq-y").map { "max \($0)" },
    property(controller, "video-params/avg-pq-y").map { "average \($0)" },
    property(controller, "video-params/max-luma").map { "mastered \($0) cd/m²" },
  ]))
  setDiagnostic("g.hdr.output", join([
    "\(hdrFormat) source",
    property(controller, "video-target-params/gamma").map { "→ \($0)" },
    property(controller, "video-target-params/primaries"),
    property(controller, MPVProperty.options("tone-mapping")).map { "\($0) tone mapping" },
  ]))

  let hasEL = property(controller, "current-tracks/video/dolby-vision-enhancement-layer") == "yes"
    || video?.hasDolbyVisionEnhancementLayer == true
  setDiagnostic("g.dv.profile", dvProfile.map { "Profile \($0)" }
    .flatMap { profile in join([profile, dvLevel.map { "Level \($0)" }]) })
  setDiagnostic("g.dv.layers", dvProfile == nil ? nil :
    hasEL ? "Dual layer · base + enhancement" : "Single layer")
  setDiagnostic("g.dv.mode", property(controller, "video-frame-info/dolby-vision-mode"))
  setDiagnostic("g.dv.rpu", property(controller, "video-frame-info/dolby-vision-rpu").map {
    $0 == "yes" ? "Detected and applied" : "Not present on current frame"
  })
  setDiagnostic("g.dv.composition", property(controller, "video-frame-info/dolby-vision-composition"))
  setDiagnostic("g.dv.health", hasEL ? join([
    property(controller, "video-frame-info/dolby-vision-el-pairs").map { "\($0) paired" },
    property(controller, "video-frame-info/dolby-vision-el-misses").map { "\($0) missing" },
    property(controller, "video-frame-info/dolby-vision-el-late").map { "\($0) late" },
  ]) : nil)
  setDiagnostic("g.dv.decoders", dvProfile == nil ? nil : join([
    property(controller, MPVProperty.hwdecCurrent).map { "BL \($0)" },
    property(controller, "video-frame-info/dolby-vision-el-format").map { "EL \($0)" },
  ]))

  let configuredHwdec = property(controller, MPVProperty.hwdec)
  let activeHwdec = property(controller, MPVProperty.hwdecCurrent)
  setDiagnostic("g.render.decoder", join([
    property(controller, "current-tracks/video/decoder"),
    property(controller, MPVProperty.currentTracksVideoDecoderDesc),
  ]))
  setDiagnostic("g.render.hwdec", join([
    configuredHwdec.map { "configured \($0)" },
    activeHwdec.map { "active \($0)" } ?? "software fallback",
  ]))
  setDiagnostic("g.render.interop", property(controller, MPVProperty.hwdecInterop))
  setDiagnostic("g.render.vo", property(controller, MPVProperty.currentVo))
  setDiagnostic("g.render.gpu", property(controller, MPVProperty.currentGpuContext))
  setDiagnostic("g.render.path", join([
    property(controller, MPVProperty.currentVo),
    property(controller, MPVProperty.currentGpuContext),
    activeHwdec,
  ], separator: " → "))
  setDiagnostic("g.render.filters", property(controller, MPVProperty.vf) ?? "None")
  setDiagnostic("g.render.scaling", join([
    property(controller, MPVProperty.options("scale")).map { "luma \($0)" },
    property(controller, MPVProperty.options("cscale")).map { "chroma \($0)" },
  ]))
  setDiagnostic("g.render.tone", join([
    property(controller, MPVProperty.options("tone-mapping")),
    property(controller, MPVProperty.options("hdr-compute-peak")).map { "peak detection \($0)" },
    property(controller, MPVProperty.options("target-peak")).map { "target \($0)" },
  ]))
  setDiagnostic("g.render.dither", join([
    property(controller, MPVProperty.options("dither-depth")).map { "\($0)-bit" },
    property(controller, MPVProperty.options("dither")).map { "algorithm \($0)" },
  ]))

  let player = PlayerCore.lastActive
  let screen = player.mainWindow.window?.screen
  setDiagnostic("g.display.name", screen?.localizedName
    ?? property(controller, MPVProperty.displayNames))
  setDiagnostic("g.display.size", join([
    property(controller, MPVProperty.displayWidth).flatMap { w in
      property(controller, MPVProperty.displayHeight).map { "\(w)×\($0) display" }
    },
    property(controller, "video-target-params/dw").flatMap { w in
      property(controller, "video-target-params/dh").map { "\(w)×\($0) output" }
    },
    screen.map { String(format: "%.1f× scale", $0.backingScaleFactor) },
  ]))
  setDiagnostic("g.display.refresh", join([
    propertyDouble(controller, MPVProperty.displayFps).map { String(format: "%.3f Hz current", $0) },
    propertyDouble(controller, MPVProperty.estimatedDisplayFps).map { String(format: "%.3f Hz estimated", $0) },
  ]))
  setDiagnostic("g.display.colorspace", vcolorspaceField.stringValue)
  setDiagnostic("g.display.target", join([
    property(controller, "video-target-params/primaries"),
    property(controller, "video-target-params/gamma"),
    property(controller, "video-target-params/sig-peak").map { "peak \($0)" },
  ]))
  setDiagnostic("g.display.edr", screen.map {
    String(format: "%.2f× current · %.2f× maximum",
           $0.maximumExtendedDynamicRangeColorComponentValue,
           $0.maximumPotentialExtendedDynamicRangeColorComponentValue)
  })

  let audioProfile = audio?.codecProfile
    ?? property(controller, MPVProperty.currentTracksAudioCodecProfile)
  let audioInputFormat = property(controller, MPVProperty.audioParamsFormat)
  let audioOutFormat = property(controller, "audio-out-params/format")
  let audioPipeline = property(controller, "current-tracks/audio/audio-pipeline")
  let audioDecoder = property(controller, "current-tracks/audio/decoder")
    ?? audio?.decoderDesc
  let ao = property(controller, MPVProperty.currentAo)
  let compressed = audioOutFormat?.contains("spdif") == true
  let avPlayerRoute = ao == "avfoundation" && compressed && audio?.codec == "eac3"
  let route: String? = avPlayerRoute ? "AVPlayer fMP4/HLS" :
    audioPipeline?.hasPrefix("liborender") == true ? "liborender → \(ao ?? "audio output")" :
    compressed ? "\(ao ?? "audio output") compressed passthrough" :
    ao == "avfoundation" ? "AVSampleBufferAudioRenderer" : ao
  let transport: String? = audio == nil ? nil :
    avPlayerRoute ? "Compressed E-AC-3/JOC" :
    compressed ? "IEC 61937 compressed" : "Decoded PCM"

  setDiagnostic("g.audio.codec", join([audio?.codecDesc, audio?.codec]))
  setDiagnostic("g.audio.profile", audioProfile)
  setDiagnostic("g.audio.decoder", join([audioDecoder, audioPipeline]))
  setDiagnostic("g.audio.bitrate", formatBitrate(audio?.demuxBitrate
    ?? Int(propertyInt(controller, MPVProperty.audioBitrate) ?? 0)))
  setDiagnostic("g.audio.input", join([
    audioInputFormat,
    property(controller, MPVProperty.audioParamsSamplerate).map { "\($0) Hz" },
    property(controller, MPVProperty.audioParamsHrChannels)
      ?? property(controller, MPVProperty.audioParamsChannels),
  ]))
  let losslessCodecs = ["truehd", "flac", "alac", "ape", "wavpack"]
  let lossless = audio.map {
    losslessCodecs.contains($0.codec ?? "") || ($0.codec == "dts" && ($0.codecProfile?.contains("MA") == true))
  }
  setDiagnostic("g.audio.loss", lossless.map { $0 ? "Lossless" : "Lossy" })

  setDiagnostic("g.object.class", audioProfile)
  setDiagnostic("g.object.bed", join([
    bedLayout(from: audioProfile).map { "bed \($0)" },
    objectCount(from: audioProfile),
  ]))
  setDiagnostic("g.object.dialnorm", dialNorm(from: audioProfile))
  let dependentAudio = info.audioTracks.filter(\.isDependent).count
  setDiagnostic("g.object.substreams", audio == nil ? nil :
    dependentAudio > 0 ? "\(dependentAudio) dependent track(s)" :
    audioProfile?.contains("Atmos") == true ? "Atmos metadata in selected stream" : "None")

  setDiagnostic("g.pipeline.route", route)
  setDiagnostic("g.pipeline.transport", transport)
  setDiagnostic("g.pipeline.spatial", avPlayerRoute ? "System-managed Dolby Atmos" :
    audioPipeline ?? (audioProfile?.contains("Atmos") == true || audioProfile?.contains("DTS:X") == true
      ? "Object metadata detected" : "Channel based"))
  setDiagnostic("g.pipeline.state", route == nil ? nil : "Active")
  setDiagnostic("g.pipeline.fallback", audioPipeline?.hasPrefix("host") == true
    ? audioPipeline : "None")

  setDiagnostic("g.output.driver", ao)
  setDiagnostic("g.output.device", audioDeviceName(controller))
  setDiagnostic("g.output.format", join([
    audioOutFormat,
    property(controller, "audio-out-params/samplerate").map { "\($0) Hz" },
  ]))
  let outputChannels = property(controller, "audio-out-params/hr-channels")
    ?? property(controller, "audio-out-params/channels")
  setDiagnostic("g.output.layout", outputChannels)
  setDiagnostic("g.output.spatial", outputChannels.map {
    let count = property(controller, "audio-out-params/channel-count") ?? "?"
    return "\(count) channels · \($0)"
  })
  setDiagnostic("g.output.delay", property(controller, "audio-device-delay").map { "\($0) s" })
}

func audioDeviceName(_ controller: MPVController) -> String? {
  guard let selected = property(controller, MPVProperty.audioDevice) else { return nil }
  guard let devices = controller.getNode(MPVProperty.audioDeviceList) as? [[String: Any]] else {
    return selected
  }
  let device = devices.first { ($0["name"] as? String) == selected }
  return join([device?["description"] as? String, selected])
}
}

private extension InspectorWindowController {

  func updateTrackDiagnostics(_ track: MPVTrack) {
    setDiagnostic("t.identity.type", track.type.rawValue.capitalized)
    setDiagnostic("t.identity.ids", join([
      "track \(track.id)",
      track.srcId.map { "source \($0)" },
      track.ffIndex.map { "FFmpeg \($0)" },
    ]))
    setDiagnostic("t.identity.program", track.programIds.isEmpty ? nil :
      track.programIds.map(String.init).joined(separator: ", "))
    setDiagnostic("t.identity.title", track.title)
    setDiagnostic("t.identity.language", join([track.readableLanguage, track.lang]))
    setDiagnostic("t.identity.path", track.externalFilename)

    var selectionFlags: [String] = []
    if track.isSelected { selectionFlags.append("Selected") }
    if track.isDefault { selectionFlags.append("Default") }
    if track.isForced { selectionFlags.append("Forced") }
    if track.isExternal { selectionFlags.append("External") }
    setDiagnostic("t.roles.selection", selectionFlags.isEmpty ? "None" : selectionFlags.joined(separator: " · "))

    var roles: [String] = []
    if track.isDependent { roles.append("Dependent") }
    if track.isOriginal { roles.append("Original") }
    if track.isCommentary { roles.append("Commentary") }
    if track.isHearingImpaired { roles.append("Hearing impaired") }
    if track.isVisualImpaired { roles.append("Visual impaired") }
    setDiagnostic("t.roles.flags", roles.isEmpty ? "None" : roles.joined(separator: " · "))
    setDiagnostic("t.roles.media", join([
      track.isImage ? "Image" : nil,
      track.isAlbumart ? "Album art" : nil,
    ]) ?? "None")

    setDiagnostic("t.codec.name", join([track.codecDesc, track.codec]))
    setDiagnostic("t.codec.profile", join([
      track.codecProfile,
      codecLevel(track.codec, track.codecLevel).map { "Level \($0)" },
    ]))
    setDiagnostic("t.codec.decoder", track.decoderDesc)
    setDiagnostic("t.codec.format", track.formatName)
    setDiagnostic("t.codec.bitrate", formatBitrate(track.demuxBitrate))
    setDiagnostic("t.codec.duration", formatTime(track.demuxDuration))
    setDiagnostic("t.codec.hls", formatBitrate(track.hlsBitrate))

    setDiagnostic("t.video.size", track.type == .video ? join([
      track.demuxW.flatMap { w in track.demuxH.map { "\(w)×\($0)" } },
      track.metadata["CROP"].map { "crop \($0)" },
    ]) : nil)
    setDiagnostic("t.video.fps", track.type == .video
      ? track.demuxFps.map { String(format: "%.3f fps", $0) } : nil)
    setDiagnostic("t.video.aspect", track.type == .video ? join([
      track.demuxPar.map { String(format: "PAR %.4f", $0) },
      track.demuxRotation.map { "\($0)° rotation" },
    ]) : nil)
    setDiagnostic("t.video.dv", track.dolbyVisionProfile.map { profile in
      join([
        "Profile \(profile)",
        track.dolbyVisionLevel.map { "Level \($0)" },
        track.hasDolbyVisionEnhancementLayer == true ? "enhancement layer" : nil,
      ])!
    })

    setDiagnostic("t.audio.channels", track.type == .audio ? join([
      track.demuxChannelCount.map { "\($0) channels" },
      track.demuxChannels,
    ]) : nil)
    setDiagnostic("t.audio.rate", track.type == .audio
      ? track.demuxSamplerate.map { "\($0) Hz" } : nil)
    setDiagnostic("t.audio.depth", track.type == .audio ? join([
      track.formatName,
      track.bitsPerSample.map { "\($0)-bit" },
    ]) : nil)
    setDiagnostic("t.audio.object", track.type == .audio ? track.codecProfile : nil)
    setDiagnostic("t.audio.replaygain", track.type == .audio ? join([
      track.metadata["REPLAYGAIN_TRACK_GAIN"].map { "track \($0)" },
      track.metadata["REPLAYGAIN_ALBUM_GAIN"].map { "album \($0)" },
    ]) : nil)

    let subtitleKind: String? = {
      guard track.type == .sub || track.type == .secondSub else { return nil }
      if track.isImageSub { return "Bitmap · \(track.codecDesc ?? track.codec ?? "subtitle")" }
      if track.codec == "dvb_teletext" { return "Teletext" }
      return "Text · \(track.codecDesc ?? track.codec ?? "subtitle")"
    }()
    setDiagnostic("t.sub.type", subtitleKind)
    setDiagnostic("t.sub.canvas", subtitleKind == nil ? nil : join([
      track.demuxW.flatMap { w in track.demuxH.map { "\(w)×\($0)" } },
      track.demuxFps.map { String(format: "%.3f fps", $0) },
    ]))
    setDiagnostic("t.sub.roles", subtitleKind == nil ? nil : roles.isEmpty
      ? join([track.isForced ? "Forced" : nil, track.isDefault ? "Default" : nil]) ?? "None"
      : roles.joined(separator: " · "))
    setDiagnostic("t.sub.encoding", subtitleKind == nil ? nil :
      track.metadata["ENCODING"] ?? (track.isExternal ? "Automatic" : "Container managed"))
  }

  func updateFileDiagnostics(controller: MPVController, info: PlaybackInfo) {
    let path = property(controller, MPVProperty.path)
    let url = path.flatMap { $0.hasPrefix("/") ? URL(fileURLWithPath: $0) : URL(string: $0) }
    let metadata = metadataMap(controller)

    setDiagnostic("f.identity.path", path)
    setDiagnostic("f.identity.name", property(controller, MPVProperty.filename))
    setDiagnostic("f.identity.title", property(controller, MPVProperty.mediaTitle))
    setDiagnostic("f.identity.comment", metadataValue(metadata, "comment", "description"))
    setDiagnostic("f.identity.size", formatBytes(propertyInt(controller, MPVProperty.fileSize)))
    setDiagnostic("f.identity.duration", formatTime(propertyDouble(controller, MPVProperty.durationFull)
      ?? propertyDouble(controller, MPVProperty.duration)))
    setDiagnostic("f.identity.kind", path.map { _ in
      url?.scheme.map { $0 == "file" ? "Local file" : "Network / \($0.uppercased())" } ?? "Local file"
    })

    setDiagnostic("f.container.format", join([
      property(controller, MPVProperty.fileFormat),
      property(controller, MPVProperty.currentDemuxer),
    ]))
    setDiagnostic("f.container.protocol", path.map { _ in url?.scheme ?? "file" })
    setDiagnostic("f.container.stream", join([
      property(controller, MPVProperty.streamOpenFilename),
      property(controller, MPVProperty.streamPath),
    ]))
    setDiagnostic("f.container.start", formatTime(propertyDouble(controller, MPVProperty.timeStart)))
    setDiagnostic("f.container.seek", join([
      property(controller, "seekable").map { $0 == "yes" ? "Seekable" : "Not seekable" },
      property(controller, "partially-seekable").flatMap { $0 == "yes" ? "partially seekable" : nil },
    ]))
    let totalBitrate = (info.videoTracks + info.audioTracks + info.subTracks)
      .compactMap(\.demuxBitrate).reduce(0, +)
    setDiagnostic("f.container.bitrate", formatBitrate(totalBitrate))
    setDiagnostic("f.container.tracks",
      "\(info.videoTracks.count) video · \(info.audioTracks.count) audio · \(info.subTracks.count) subtitle")

    setDiagnostic("f.metadata.primary", join([
      metadataValue(metadata, "title"),
      metadataValue(metadata, "artist"),
      metadataValue(metadata, "album"),
      metadataValue(metadata, "date"),
      metadataValue(metadata, "genre"),
    ]))
    setDiagnostic("f.metadata.credits", join([
      metadataValue(metadata, "album_artist", "album artist").map { "album artist \($0)" },
      metadataValue(metadata, "composer").map { "composer \($0)" },
      metadataValue(metadata, "copyright"),
    ]))
    setDiagnostic("f.metadata.technical", join([
      metadataValue(metadata, "encoder").map { "encoder \($0)" },
      metadataValue(metadata, "creation_time", "creation time").map { "created \($0)" },
    ]))
    setDiagnostic("f.metadata.all", metadata.isEmpty ? nil :
      metadata.sorted { $0.key.localizedCaseInsensitiveCompare($1.key) == .orderedAscending }
        .map { "\($0.key): \($0.value)" }.joined(separator: "\n"))

    setDiagnostic("f.structure.chapters", listSummary(controller.getNode(MPVProperty.chapterList),
                                                      titleKey: "title", timeKey: "time"))
    setDiagnostic("f.structure.editions", listSummary(controller.getNode(MPVProperty.editionList),
                                                      titleKey: "title", timeKey: nil))
    setDiagnostic("f.structure.programs", programSummary(info))
    let playlistCount = propertyInt(controller, MPVProperty.playlistCount) ?? 0
    setDiagnostic("f.structure.playlist", playlistCount > 0 ? "\(playlistCount) entries" : nil)
    let coverArt = info.videoTracks.filter(\.isAlbumart).count
    let imageSubs = info.subTracks.filter(\.isImageSub).count
    setDiagnostic("f.structure.attachments", join([
      coverArt > 0 ? "\(coverArt) cover art" : nil,
      imageSubs > 0 ? "\(imageSubs) bitmap subtitle track(s)" : nil,
    ]))
  }

  func listSummary(_ node: Any?, titleKey: String, timeKey: String?) -> String? {
    guard let items = node as? [[String: Any]], !items.isEmpty else { return nil }
    return items.enumerated().map { index, item in
      let title = item[titleKey] as? String ?? "#\(index + 1)"
      guard let timeKey, let time = item[timeKey] as? Double else { return title }
      return "\(formatTime(time) ?? "\(time)") \(title)"
    }.joined(separator: "\n")
  }

  func programSummary(_ info: PlaybackInfo) -> String? {
    let programs = Set((info.videoTracks + info.audioTracks + info.subTracks)
      .flatMap(\.programIds)).sorted()
    return programs.isEmpty ? nil : programs.map(String.init).joined(separator: ", ")
  }

  func updateStatusDiagnostics(controller: MPVController, audio: MPVTrack?) {
    let paused = property(controller, "pause") == "yes"
    let seeking = property(controller, MPVProperty.seeking) == "yes"
    let buffering = property(controller, MPVProperty.pausedForCache) == "yes"
    let eof = property(controller, MPVProperty.eofReached) == "yes"
    let state = eof ? "End of file" : seeking ? "Seeking" : buffering ? "Buffering" :
      paused ? "Paused" : "Playing"
    setDiagnostic("s.playback.state", state)
    setDiagnostic("s.playback.position", join([
      formatTime(propertyDouble(controller, MPVProperty.timePos)),
      propertyDouble(controller, MPVProperty.percentPos).map { String(format: "%.1f%%", $0) },
    ]))
    setDiagnostic("s.playback.remaining", formatTime(propertyDouble(controller, MPVProperty.timeRemaining)))
    setDiagnostic("s.playback.speed", property(controller, "speed").map { "\($0)×" })
    setDiagnostic("s.playback.chapter", join([
      property(controller, MPVProperty.chapter).map { "chapter \($0)" },
      property(controller, MPVProperty.currentEdition).map { "edition \($0)" },
    ]))

    setDiagnostic("s.sync.av", property(controller, MPVProperty.avsync).map { "\($0) s" })
    setDiagnostic("s.sync.total", property(controller, MPVProperty.totalAvsyncChange).map { "\($0) s" })
    setDiagnostic("s.sync.pts", join([
      property(controller, MPVProperty.audioPts).map { "audio \($0)" },
      property(controller, "video-pts").map { "video \($0)" },
    ]))
    setDiagnostic("s.sync.speed", join([
      property(controller, MPVProperty.audioSpeedCorrection).map { "audio \($0)" },
      property(controller, MPVProperty.videoSpeedCorrection).map { "video \($0)" },
    ]))
    setDiagnostic("s.sync.display", property(controller, MPVProperty.displaySyncActive))
    setDiagnostic("s.sync.delay", property(controller, "audio-delay").map { "\($0) s" })

    setDiagnostic("s.frames.presented", join([
      property(controller, MPVProperty.estimatedFrameNumber).map { "frame \($0)" },
      property(controller, MPVProperty.estimatedFrameCount).map { "of \($0)" },
    ]))
    setDiagnostic("s.frames.dropped", join([
      property(controller, MPVProperty.frameDropCount).map { "\($0) output" },
      property(controller, MPVProperty.decoderFrameDropCount).map { "\($0) decoder" },
    ]))
    setDiagnostic("s.frames.delayed", join([
      property(controller, MPVProperty.voDelayedFrameCount).map { "\($0) delayed" },
      property(controller, MPVProperty.mistimedFrameCount).map { "\($0) mistimed" },
    ]))
    setDiagnostic("s.frames.info", join([
      property(controller, MPVProperty.videoFrameInfoPictureType).map { "\($0)-frame" },
      property(controller, MPVProperty.videoFrameInfoInterlaced).map { $0 == "yes" ? "interlaced" : "progressive" },
      property(controller, MPVProperty.videoFrameInfoRepeat).flatMap { $0 == "yes" ? "repeat" : nil },
    ]))

    setDiagnostic("s.pacing.fps", join([
      propertyDouble(controller, MPVProperty.containerFps).map { String(format: "%.3f source", $0) },
      propertyDouble(controller, MPVProperty.estimatedVfFps).map { String(format: "%.3f output", $0) },
    ]))
    setDiagnostic("s.pacing.display", join([
      propertyDouble(controller, MPVProperty.displayFps).map { String(format: "%.3f actual", $0) },
      propertyDouble(controller, MPVProperty.estimatedDisplayFps).map { String(format: "%.3f estimated", $0) },
    ]))
    setDiagnostic("s.pacing.vsync", join([
      property(controller, MPVProperty.vsyncRatio).map { "ratio \($0)" },
      property(controller, MPVProperty.vsyncJitter).map { "jitter \($0)" },
    ]))
    setDiagnostic("s.pacing.render", renderPassSummary(controller.getNode(MPVProperty.voPasses)))

    setDiagnostic("s.dv.mode", join([
      property(controller, "video-frame-info/dolby-vision-mode"),
      property(controller, "video-frame-info/dolby-vision-composition"),
    ]))
    setDiagnostic("s.dv.pair", property(controller, "video-frame-info/dolby-vision-el-paired").map {
      $0 == "yes" ? "Paired" : "Base-layer fallback"
    })
    setDiagnostic("s.dv.counts", join([
      property(controller, "video-frame-info/dolby-vision-el-pairs").map { "\($0) paired" },
      property(controller, "video-frame-info/dolby-vision-el-misses").map { "\($0) missing" },
      property(controller, "video-frame-info/dolby-vision-el-late").map { "\($0) late" },
    ]))
    setDiagnostic("s.dv.queues", join([
      property(controller, "video-frame-info/dolby-vision-bl-queue").map { "BL \($0)" },
      property(controller, "video-frame-info/dolby-vision-el-queue").map { "EL \($0)" },
    ]))
    setDiagnostic("s.dv.metadata", join([
      property(controller, "video-frame-info/dolby-vision-rpu").map { $0 == "yes" ? "RPU active" : "RPU absent" },
      property(controller, "video-params/max-pq-y").map { "max PQ \($0)" },
      property(controller, "video-params/avg-pq-y").map { "average PQ \($0)" },
    ]))

    let audioProfile = audio?.codecProfile
      ?? property(controller, MPVProperty.currentTracksAudioCodecProfile)
    setDiagnostic("s.audio.route", join([
      property(controller, "current-tracks/audio/audio-pipeline"),
      diagnosticValue("g.pipeline.route"),
      audio?.decoderDesc,
    ]))
    setDiagnostic("s.audio.layouts", join([
      property(controller, MPVProperty.audioParamsHrChannels)
        ?? property(controller, MPVProperty.audioParamsChannels),
      property(controller, "audio-out-params/hr-channels")
        ?? property(controller, "audio-out-params/channels"),
    ], separator: " → "))
    setDiagnostic("s.audio.objects", join([
      bedLayout(from: audioProfile).map { "bed \($0)" },
      objectCount(from: audioProfile),
      dialNorm(from: audioProfile),
    ]))
    setDiagnostic("s.audio.player", diagnosticValue("g.pipeline.spatial"))
    setDiagnostic("s.audio.latency", join([
      property(controller, "audio-device-delay").map { "\($0) s device" },
      property(controller, "audio-delay").map { "\($0) s user" },
    ]))

    let cache = controller.getNode(MPVProperty.demuxerCacheState) as? [String: Any]
    setDiagnostic("s.cache.state", join([
      buffering ? "Buffering" : nil,
      (cache?["idle"] as? Bool).map { $0 ? "Idle" : "Reading" },
      (cache?["underrun"] as? Bool).flatMap { $0 ? "Underrun" : nil },
    ]) ?? "Inactive")
    setDiagnostic("s.cache.duration", cacheDouble(cache, "cache-duration").flatMap(formatTime))
    setDiagnostic("s.cache.bytes", join([
      cacheInt(cache, "fw-bytes").flatMap(formatBytes).map { "\($0) forward" },
      cacheInt(cache, "file-cache-bytes").flatMap(formatBytes).map { "\($0) file cache" },
    ]))
    setDiagnostic("s.cache.rate", cacheInt(cache, "raw-input-rate").map {
      "\(FloatingPointByteCountFormatter.string(fromByteCount: Int($0)))B/s"
    })
    setDiagnostic("s.cache.range", join([
      cacheDouble(cache, "reader-pts").flatMap(formatTime).map { "reader \($0)" },
      cacheDouble(cache, "cache-end").flatMap(formatTime).map { "end \($0)" },
    ]))
    setDiagnostic("s.cache.flags", join([
      (cache?["bof-cached"] as? Bool).map { "BOF \($0 ? "cached" : "not cached")" },
      (cache?["eof-cached"] as? Bool).map { "EOF \($0 ? "cached" : "not cached")" },
    ]))

    setDiagnostic("s.display.name", diagnosticValue("g.display.name"))
    setDiagnostic("s.display.size", diagnosticValue("g.display.size"))
    setDiagnostic("s.display.refresh", diagnosticValue("g.display.refresh"))
    setDiagnostic("s.display.color", join([
      diagnosticValue("g.display.colorspace"),
      diagnosticValue("g.display.edr"),
    ]))

    let (version, build) = InfoDictionary.shared.version
    setDiagnostic("s.version.iina", "\(version) (\(build))")
    setDiagnostic("s.version.mpv", property(controller, MPVProperty.mpvVersion))
    setDiagnostic("s.version.ffmpeg", property(controller, MPVProperty.ffmpegVersion))
    setDiagnostic("s.version.libass", property(controller, MPVProperty.libassVersion))
    setDiagnostic("s.version.platform", property(controller, MPVProperty.platform))
    setDiagnostic("s.version.build", join([
      InfoDictionary.shared.buildType.description,
      InfoDictionary.shared.shortCommitSHA,
      property(controller, MPVProperty.mpvConfiguration),
    ]))
  }

  func diagnosticValue(_ key: String) -> String? {
    guard let value = diagnosticFields[key]?.stringValue,
          value != NSLocalizedString("general.na", comment: "N/A") else { return nil }
    return value
  }

  func cacheDouble(_ cache: [String: Any]?, _ key: String) -> Double? {
    cache?[key] as? Double
  }

  func cacheInt(_ cache: [String: Any]?, _ key: String) -> Int64? {
    cache?[key] as? Int64
  }

  func renderPassSummary(_ node: Any?) -> String? {
    guard let groups = node as? [String: Any] else { return nil }
    var passes: [String] = []
    for value in groups.values {
      guard let entries = value as? [[String: Any]] else { continue }
      for entry in entries.prefix(3) {
        guard let description = entry["desc"] as? String else { continue }
        let average = entry["avg"] as? Int64
        passes.append(average.map { "\(description) \(String(format: "%.2f ms", Double($0) / 1_000_000))" }
          ?? description)
      }
    }
    return passes.isEmpty ? nil : passes.joined(separator: " · ")
  }
}

extension Logger.Sub {
  static let inspector = Logger.makeSubsystem("inspector", ["tablecells"])
}
