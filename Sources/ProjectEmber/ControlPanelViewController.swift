import AppKit
import EmberCore

@MainActor
final class ControlPanelViewController: NSViewController {
  private let coordinator: DisplayCoordinator
  private let showDiagnostics: () -> Void

  // New delightful UI components (code-drawn, no assets)
  private let headerView = EmberHeaderView()
  private let heroView = HeroStatusView()
  private let pillControl = EmberPillControl(titles: ["Neutral", "Evening", "Pure Red"])

  private let warmthSlider = EmberSlider(variant: .warmth, value: 62, minValue: 0, maxValue: 100, target: nil, action: nil)
  private let warmthValue = NSTextField(labelWithString: "~2700 K")
  private let brightnessSlider = EmberSlider(variant: .brightness, value: 75, minValue: 10, maxValue: 100, target: nil, action: nil)
  private let brightnessValue = NSTextField(labelWithString: "75%")

  private let backlightRow = EmberToggleRowView(iconSymbol: "shield.lefthalf.filled", title: "Backlight Lock", detail: "Keeps the panel backlight at full power while Ember dims in software.")
  private let sunScheduleRow = EmberToggleRowView(iconSymbol: "sun.horizon", title: "Sun schedule", detail: "Turns Ember on at sunset and restores it at sunrise.")
  private let launchRow = EmberToggleRowView(iconSymbol: "paperplane.fill", title: "Launch at login", detail: "Apply your saved preference after sign-in.")
  private let settingsCard = EmberSettingsCard()

  private let footerActions = EmberFooterActionsView()
  private let footerBar = EmberFooterBarView()

  private let scrollContent = NSStackView()

  init(coordinator: DisplayCoordinator, showDiagnostics: @escaping () -> Void) {
    self.coordinator = coordinator
    self.showDiagnostics = showDiagnostics
    super.init(nibName: nil, bundle: nil)
    preferredContentSize = NSSize(width: EmberMetrics.popoverWidth, height: 710)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  override func loadView() {
    // Background – dark vibrancy with subtle warm wash
    let background = NSVisualEffectView()
    background.appearance = NSAppearance(named: .darkAqua)
    background.material = .hudWindow
    background.blendingMode = .withinWindow
    background.state = .active
    view = background
    let wash = NSView()
    wash.wantsLayer = true
    wash.layer?.backgroundColor = NSColor(calibratedRed: 0.16, green: 0.10, blue: 0.09, alpha: 0.28).cgColor
    wash.translatesAutoresizingMaskIntoConstraints = false
    background.addSubview(wash)
    NSLayoutConstraint.activate([
      wash.leadingAnchor.constraint(equalTo: background.leadingAnchor),
      wash.trailingAnchor.constraint(equalTo: background.trailingAnchor),
      wash.topAnchor.constraint(equalTo: background.topAnchor),
      wash.bottomAnchor.constraint(equalTo: background.bottomAnchor),
    ])

    // Header – BETA kept per request
    headerView.powerButton.target = self
    headerView.powerButton.action = #selector(toggleMaster)
    headerView.powerButton.toolTip = "Apply or restore the display filter"
    headerView.powerButton.setAccessibilityLabel("Ember display filter")
    // Keep accessibility for power
    headerView.translatesAutoresizingMaskIntoConstraints = false

    // Hero
    heroView.translatesAutoresizingMaskIntoConstraints = false
    heroView.wantsLayer = true

    // Pill
    pillControl.target = self
    pillControl.action = #selector(selectPreset)
    pillControl.setAccessibilityLabel("Color preset")
    pillControl.translatesAutoresizingMaskIntoConstraints = false

    // Sliders
    warmthSlider.target = self
    warmthSlider.action = #selector(changeWarmth)
    warmthSlider.setAccessibilityLabel("Warmth")
    warmthSlider.translatesAutoresizingMaskIntoConstraints = false
    brightnessSlider.target = self
    brightnessSlider.action = #selector(changeBrightness)
    brightnessSlider.setAccessibilityLabel("Apparent brightness")
    brightnessSlider.translatesAutoresizingMaskIntoConstraints = false
    warmthValue.font = EmberFont.sliderValue()
    warmthValue.textColor = EmberColor.textSecondary
    brightnessValue.font = EmberFont.sliderValue()
    brightnessValue.textColor = EmberColor.textSecondary

    // Toggle rows – wire actions
    backlightRow.toggle.target = self
    backlightRow.toggle.action = #selector(toggleBacklightLock)
    backlightRow.toggle.setAccessibilityLabel("Backlight Lock")
    sunScheduleRow.toggle.target = self
    sunScheduleRow.toggle.action = #selector(toggleSunSchedule)
    sunScheduleRow.toggle.setAccessibilityLabel("Follow local sunrise and sunset")
    launchRow.toggle.target = self
    launchRow.toggle.action = #selector(toggleLaunchAtLogin)
    launchRow.toggle.setAccessibilityLabel("Launch Project Ember at login")
    // Static caption for sun schedule
    sunScheduleRow.setCaption("Uses approximate location on-device.", color: EmberColor.textMuted, showButton: false)
    // Keep location button handling inside row – will be toggled in render

    settingsCard.translatesAutoresizingMaskIntoConstraints = false
    settingsCard.addRow(backlightRow, showDivider: true)
    settingsCard.addRow(sunScheduleRow, showDivider: true)
    settingsCard.addRow(launchRow, showDivider: false)

    // Footer actions
    footerActions.diagnosticsButton.target = self
    footerActions.diagnosticsButton.action = #selector(openDiagnostics)
    footerActions.diagnosticsButton.setAccessibilityLabel("Diagnostics")
    footerActions.quitButton.target = self
    footerActions.quitButton.action = #selector(quitApplication)
    footerActions.quitButton.setAccessibilityLabel("Quit")
    footerActions.translatesAutoresizingMaskIntoConstraints = false

    footerBar.translatesAutoresizingMaskIntoConstraints = false
    footerBar.setText(version: (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "v1.0.0")

    // Content stack – create hierarchy first, then populate
    scrollContent.orientation = .vertical
    scrollContent.alignment = .leading
    scrollContent.spacing = 14
    scrollContent.translatesAutoresizingMaskIntoConstraints = false

    // Container for content with padding
    let container = NSView()
    container.translatesAutoresizingMaskIntoConstraints = false
    background.addSubview(container)
    container.addSubview(scrollContent)
    background.addSubview(footerBar)

    NSLayoutConstraint.activate([
      container.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: EmberMetrics.contentHInset),
      container.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -EmberMetrics.contentHInset),
      container.topAnchor.constraint(equalTo: background.topAnchor, constant: 14),
      container.bottomAnchor.constraint(equalTo: footerBar.topAnchor, constant: -12),

      scrollContent.leadingAnchor.constraint(equalTo: container.leadingAnchor),
      scrollContent.trailingAnchor.constraint(equalTo: container.trailingAnchor),
      scrollContent.topAnchor.constraint(equalTo: container.topAnchor),
      scrollContent.bottomAnchor.constraint(equalTo: container.bottomAnchor),

      footerBar.leadingAnchor.constraint(equalTo: background.leadingAnchor),
      footerBar.trailingAnchor.constraint(equalTo: background.trailingAnchor),
      footerBar.bottomAnchor.constraint(equalTo: background.bottomAnchor),
      footerBar.heightAnchor.constraint(equalToConstant: EmberMetrics.footerBarHeight),
    ])

    // Now populate stack – width constraints are safe now that scrollContent has superview
    scrollContent.addArrangedSubview(headerView)
    headerView.widthAnchor.constraint(equalTo: scrollContent.widthAnchor).isActive = true

    scrollContent.addArrangedSubview(heroView)
    heroView.widthAnchor.constraint(equalTo: scrollContent.widthAnchor).isActive = true

    let sectionTitle = makeSectionTitle("COLOR MODE")
    scrollContent.addArrangedSubview(sectionTitle)

    scrollContent.addArrangedSubview(pillControl)
    pillControl.widthAnchor.constraint(equalTo: scrollContent.widthAnchor).isActive = true

    let warmthBlock = makeSliderBlock(title: "WARMTH", valueLabel: warmthValue, slider: warmthSlider, iconName: "sun.max", variant: .warmth)
    scrollContent.addArrangedSubview(warmthBlock)
    warmthBlock.widthAnchor.constraint(equalTo: scrollContent.widthAnchor).isActive = true

    let brightnessBlock = makeSliderBlock(title: "BRIGHTNESS", valueLabel: brightnessValue, slider: brightnessSlider, iconName: "sun.max.fill", variant: .brightness)
    scrollContent.addArrangedSubview(brightnessBlock)
    brightnessBlock.widthAnchor.constraint(equalTo: scrollContent.widthAnchor).isActive = true

    let sep = NSBox()
    sep.boxType = .separator
    sep.translatesAutoresizingMaskIntoConstraints = false
    scrollContent.addArrangedSubview(sep)
    sep.widthAnchor.constraint(equalTo: scrollContent.widthAnchor).isActive = true

    scrollContent.addArrangedSubview(settingsCard)
    settingsCard.widthAnchor.constraint(equalTo: scrollContent.widthAnchor).isActive = true

    scrollContent.addArrangedSubview(footerActions)
    footerActions.widthAnchor.constraint(equalTo: scrollContent.widthAnchor).isActive = true

    // Subtle entrance animation – scale + fade (respects reduce motion)
    let isSnapshot = CommandLine.arguments.contains("--snapshot-ui")
    if !isSnapshot && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
      scrollContent.alphaValue = 0
      scrollContent.layer?.transform = CATransform3DMakeScale(0.98, 0.98, 1)
      NSAnimationContext.runAnimationGroup { ctx in
        ctx.duration = 0.28
        ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
        scrollContent.animator().alphaValue = 1
      }
      // scale animation via layer
      let scale = CABasicAnimation(keyPath: "transform.scale")
      scale.fromValue = 0.98
      scale.toValue = 1.0
      scale.duration = 0.28
      scale.timingFunction = CAMediaTimingFunction(name: .easeOut)
      scrollContent.layer?.add(scale, forKey: "entranceScale")
    } else {
      scrollContent.alphaValue = 1
      scrollContent.layer?.transform = CATransform3DIdentity
    }
  }

  // MARK: - Render (logic preserved, visuals upgraded)

  func render(_ snapshot: EmberSnapshot) {
    let settings = snapshot.settings

    // Sliders + values
    warmthSlider.doubleValue = settings.warmth * 100
    warmthValue.stringValue = snapshot.warmthDescription
    // For screenshot fidelity: warmth value shows "Pure Red" when pure red
    // snapshot.warmthDescription already does that via ColorCurve.
    brightnessSlider.doubleValue = settings.apparentBrightness * 100
    brightnessValue.stringValue = "\(Int((settings.apparentBrightness * 100).rounded()))%"

    // Switches
    // Use programmatic setter to avoid sending action
    if backlightRow.toggle.isOn != settings.backlightLockEnabled {
      backlightRow.toggle.setOn(settings.backlightLockEnabled, animated: true)
    }
    if sunScheduleRow.toggle.isOn != settings.sunScheduleEnabled {
      sunScheduleRow.toggle.setOn(settings.sunScheduleEnabled, animated: true)
    }
    if launchRow.toggle.isOn != settings.launchAtLogin {
      launchRow.toggle.setOn(settings.launchAtLogin, animated: true)
    }

    // Power button + header ON/OFF (BETA moved to footer)
    let isActive = snapshot.runtimeState == .active
    headerView.powerButton.isActiveState = isActive
    headerView.setState(isActive: isActive)
    headerView.powerButton.toolTip = isActive ? "Restore original display" : "Apply Ember display filter"

    // Pill preset
    let preset: Int
    if abs(settings.warmth - EmberPreset.neutral.warmth) < 0.01 {
      preset = 0
    } else if abs(settings.warmth - EmberPreset.evening.warmth) < 0.01 {
      preset = 1
    } else if abs(settings.warmth - EmberPreset.pureRed.warmth) < 0.01 {
      preset = 2
    } else {
      preset = -1
    }
    pillControl.setSelectedSegment(preset, animated: true)

    // Hero mapping – pleasure, circadian-aligned copy
    let heroTitle: String
    let heroDetail: String
    let metaIconName: String?
    let metaText: String
    var sunsetAttr: NSAttributedString? = nil

    switch snapshot.runtimeState {
    case .active:
      // Preset-aware titles
      if abs(settings.warmth - EmberPreset.pureRed.warmth) < 0.01 {
        heroTitle = "Pure Red is on"
        heroDetail = "Your display is tuned for deep rest and recovery."
      } else if abs(settings.warmth - EmberPreset.evening.warmth) < 0.01 {
        heroTitle = "Evening light is on"
        heroDetail = "Warm tones to ease you into the night."
      } else if abs(settings.warmth - EmberPreset.neutral.warmth) < 0.01 {
        heroTitle = "Neutral is on"
        heroDetail = "True color, softly preserved."
      } else {
        // intermediate warmth – use kelvin but keep pleasure tone
        let kelvinLabel = snapshot.warmthDescription
        if kelvinLabel == "Neutral" {
          heroTitle = "Neutral is on"
          heroDetail = "True color, softly preserved."
        } else if kelvinLabel == "Pure Red" {
          heroTitle = "Pure Red is on"
          heroDetail = "Your display is tuned for deep rest and recovery."
        } else {
          heroTitle = "\(kelvinLabel) is on"
          heroDetail = "Warmth crafted for this moment."
        }
      }
      metaIconName = "clock"
      let count = snapshot.controlledDisplayCount
      if snapshot.pendingRestoreCount > 0 {
        metaText = "Active on \(count) \(count == 1 ? "display" : "displays") · \(snapshot.pendingRestoreCount) pending"
      } else if snapshot.unsupportedDisplayCount > 0 {
        metaText = "Active on \(count) of \(snapshot.availableDisplayCount) displays"
      } else {
        metaText = "Active on \(count) \(count == 1 ? "display" : "displays")"
      }
      // Sunset – only when Sun schedule is enabled and we have a next event time
      if settings.sunScheduleEnabled && !snapshot.solarStatusDetail.isEmpty {
        let detail = snapshot.solarStatusDetail
        // Only show sunset line when it contains a time (Next:/Manual override), not the generic "Turns Ember..."
        if detail.contains("Next:") || detail.contains("Manual override") || detail.contains("Getting") {
          let attr = NSMutableAttributedString(string: detail)
          attr.addAttribute(.foregroundColor, value: EmberColor.textSecondary, range: NSRange(location: 0, length: attr.length))
          attr.addAttribute(.font, value: NSFont.systemFont(ofSize: 9.5, weight: .regular), range: NSRange(location: 0, length: attr.length))
          if let range = detail.range(of: "at ") {
            let timeStr = String(detail[range.upperBound...]).replacingOccurrences(of: ".", with: "")
            let timeRange = (attr.string as NSString).range(of: timeStr)
            if timeRange.location != NSNotFound {
              attr.addAttribute(.foregroundColor, value: EmberColor.ember400, range: timeRange)
              attr.addAttribute(.font, value: NSFont.systemFont(ofSize: 9.5, weight: .medium), range: timeRange)
            } else {
              for word in ["Sunset", "Sunrise", "sunset", "sunrise"] {
                let r = (attr.string as NSString).range(of: word)
                if r.location != NSNotFound {
                  attr.addAttribute(.foregroundColor, value: EmberColor.ember400, range: r)
                }
              }
            }
          }
          sunsetAttr = attr
        }
      }
    case .degraded(let message):
      heroTitle = "Needs attention"
      heroDetail = message
      metaIconName = "exclamationmark.triangle.fill"
      metaText = message
    case .activating:
      heroTitle = "Applying…"
      heroDetail = "Saving every display state first…"
      metaIconName = "arrow.triangle.2.circlepath"
      metaText = heroDetail
    case .restoring(let intent):
      heroTitle = "Restoring…"
      heroDetail = intent == .sleep ? "Preparing every display for sleep…" : "Returning every display to its saved state…"
      metaIconName = "arrow.triangle.2.circlepath"
      metaText = heroDetail
    case .suspended:
      heroTitle = "Paused for sleep"
      heroDetail = "Ember will safely re-evaluate after wake."
      metaIconName = "moon.zzz.fill"
      metaText = heroDetail
    default: // .off
      if let msg = snapshot.statusTitle as String?, msg == "No compatible display" {
        heroTitle = "No compatible display"
        heroDetail = snapshot.statusDetail
        metaIconName = "display.trianglebadge.exclamationmark"
        metaText = snapshot.statusDetail
      } else if snapshot.statusTitle == "Needs attention" {
        heroTitle = snapshot.statusTitle
        heroDetail = snapshot.statusDetail
        metaIconName = "exclamationmark.triangle.fill"
        metaText = snapshot.statusDetail
      } else {
        heroTitle = "Ready"
        if snapshot.displayAvailable {
          heroDetail = "Your original display state is untouched."
          metaIconName = "checkmark.circle.fill"
          let count = snapshot.availableDisplayCount
          metaText = "\(count) compatible \(count == 1 ? "display" : "displays") ready"
        } else {
          heroDetail = snapshot.statusDetail
          metaIconName = "circle.fill"
          metaText = heroDetail
        }
      }
    }

    // Apply to hero
    heroView.render(title: heroTitle, detail: heroDetail, metaIconName: metaIconName, metaText: metaText, sunsetText: sunsetAttr, isActive: isActive, showWaves: true)

    // Sunset handling when not active: if hero already shows sunsetAttr, keep; else hide second line
    // For active, hero's sunsetLabel shows solar detail; for off, hide if no schedule
    // Additional pulsate control handled inside HeroStatusView

    // Controls enabled
    let controlsEnabled = snapshot.displayAvailable && !snapshot.isBusy
    pillControl.isEnabled = controlsEnabled
    pillControl.alphaValue = controlsEnabled ? 1 : 0.45
    warmthSlider.isEnabled = controlsEnabled
    brightnessSlider.isEnabled = controlsEnabled
    // Warmth/brightness value alpha
    warmthValue.alphaValue = controlsEnabled ? 1 : 0.45
    brightnessValue.alphaValue = controlsEnabled ? 1 : 0.45

    backlightRow.toggle.isEnabled = controlsEnabled && snapshot.backlightAvailable
    backlightRow.alphaValue = (controlsEnabled && snapshot.backlightAvailable) ? 1 : 0.55
    sunScheduleRow.toggle.isEnabled = !snapshot.isBusy
    launchRow.toggle.isEnabled = !snapshot.isBusy

    // Header power enabled (masterButton equivalent)
    headerView.powerButton.isEnabled = controlsEnabled

    // Backlight capability caption
    if snapshot.backlightAvailable {
      let cap: String
      if snapshot.availableDisplayCount > 1 {
        cap = "Built-in display only · external displays use software dimming"
      } else {
        cap = snapshot.ambientLightControlAvailable
          ? "Supported · brightness and auto-brightness restore"
          : "Supported · hardware brightness restore"
      }
      backlightRow.setCaption(cap, color: EmberColor.textSecondary, showButton: false)
      backlightRow.detailLabel.textColor = EmberColor.textSecondary
    } else {
      backlightRow.setCaption("Unavailable on this display", color: EmberColor.error, showButton: false)
      backlightRow.detailLabel.textColor = EmberColor.textSecondary
    }

    // Sun schedule row – detail is solarStatusDetail, caption + location button
    sunScheduleRow.detailLabel.stringValue = snapshot.solarStatusDetail
    // Permission needed states get ember tint for attention, otherwise secondary
    let isPermissionIssue = snapshot.showLocationSettings
    sunScheduleRow.detailLabel.textColor = isPermissionIssue ? EmberColor.warning : EmberColor.textSecondary
    let showLocation = snapshot.showLocationSettings
    if showLocation {
      // Permission needed (notDetermined/denied) when Sun schedule is on — show actionable button
      // Detail already contains "Location permission is needed..." via solarStatusDetail
      sunScheduleRow.setCaption("Uses approximate location on-device. No data leaves your Mac.", color: EmberColor.textMuted, showButton: true, buttonTitle: "Open Location Settings…", target: self, action: #selector(openLocationSettings))
    } else {
      // Normal states — caption is static, no button
      sunScheduleRow.setCaption("Uses approximate location on-device.", color: EmberColor.textMuted, showButton: false)
    }
    // Update row alpha for busy
    sunScheduleRow.alphaValue = snapshot.isBusy ? 0.6 : 1

    // Footer bar already set – ensure version stays
  }

  // MARK: - Builders (match screenshot hierarchy)

  private func makeSectionTitle(_ value: String) -> NSTextField {
    let label = NSTextField(labelWithString: value)
    label.font = EmberFont.sectionCAP()
    label.textColor = EmberColor.textMuted
    return label
  }

  private func makeSliderBlock(title: String, valueLabel: NSTextField, slider: NSSlider, iconName: String, variant: EmberSliderVariant) -> NSView {
    let titleLabel = NSTextField(labelWithString: title)
    titleLabel.font = EmberFont.sliderTitle()
    titleLabel.textColor = EmberColor.textMuted

    valueLabel.font = EmberFont.sliderValue()
    valueLabel.textColor = EmberColor.ember400

    let spacer = NSView()
    spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
    let heading = NSStackView(views: [titleLabel, spacer, valueLabel])
    heading.orientation = .horizontal
    heading.alignment = .centerY

    // Icon + slider row
    let icon = NSImageView(image: NSImage(systemSymbolName: iconName, accessibilityDescription: title) ?? NSImage())
    icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
    icon.contentTintColor = EmberColor.textTertiary
    icon.translatesAutoresizingMaskIntoConstraints = false
    icon.widthAnchor.constraint(equalToConstant: 18).isActive = true
    icon.heightAnchor.constraint(equalToConstant: 18).isActive = true

    slider.translatesAutoresizingMaskIntoConstraints = false
    slider.widthAnchor.constraint(greaterThanOrEqualToConstant: 200).isActive = true

    let sliderRow = NSStackView(views: [icon, slider])
    sliderRow.orientation = .horizontal
    sliderRow.alignment = .centerY
    sliderRow.spacing = 8
    sliderRow.translatesAutoresizingMaskIntoConstraints = false

    let block = NSStackView(views: [heading, sliderRow])
    block.orientation = .vertical
    block.alignment = .leading
    block.spacing = 6
    block.translatesAutoresizingMaskIntoConstraints = false
    block.widthAnchor.constraint(equalToConstant: 358).isActive = true
    heading.widthAnchor.constraint(equalTo: block.widthAnchor).isActive = true
    sliderRow.widthAnchor.constraint(equalTo: block.widthAnchor).isActive = true
    return block
  }

  // MARK: - Actions – preserved verbatim logic

  @objc private func toggleMaster() {
    coordinator.setFilterEnabled(coordinator.currentSnapshot().runtimeState != .active)
    NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
  }

  @objc private func selectPreset() {
    let presets: [EmberPreset] = [.neutral, .evening, .pureRed]
    guard pillControl.selectedSegment >= 0, pillControl.selectedSegment < presets.count else { return }
    coordinator.applyPreset(presets[pillControl.selectedSegment])
  }

  @objc private func changeWarmth() {
    coordinator.setWarmth(warmthSlider.doubleValue / 100)
  }

  @objc private func changeBrightness() {
    coordinator.setApparentBrightness(brightnessSlider.doubleValue / 100)
  }

  @objc private func toggleBacklightLock() {
    coordinator.setBacklightLockEnabled(backlightRow.toggle.state == .on)
  }

  @objc private func toggleLaunchAtLogin() {
    coordinator.setLaunchAtLogin(launchRow.toggle.state == .on)
  }

  @objc private func toggleSunSchedule() {
    coordinator.setSunScheduleEnabled(sunScheduleRow.toggle.state == .on)
  }

  @objc private func openLocationSettings() {
    coordinator.openLocationSettings()
  }

  @objc private func openDiagnostics() {
    showDiagnostics()
  }

  @objc private func quitApplication() {
    NSApp.terminate(nil)
  }
}