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

  private let backlightRow = EmberToggleRowView(iconSymbol: "shield.lefthalf.filled", title: "Backlight Lock", detail: "Keeps a compatible built-in display at full hardware brightness while Ember dims in software.")
  private let sunScheduleRow = EmberToggleRowView(iconSymbol: "sun.horizon", title: "Sun schedule", detail: "Turns Ember on at sunset and restores it at sunrise.")
  private let launchRow = EmberToggleRowView(iconSymbol: "paperplane.fill", title: "Launch at login", detail: "Apply your saved preference after sign-in.")
  private let behaviorRow = EmberBehaviorRowView()
  private let settingsCard = EmberSettingsCard()

  private let footerActions = EmberFooterActionsView()
  private let footerBar = EmberFooterBarView()

  private let scrollContent = NSStackView()
  private var scrollView: NSScrollView?

  init(coordinator: DisplayCoordinator, showDiagnostics: @escaping () -> Void) {
    self.coordinator = coordinator
    self.showDiagnostics = showDiagnostics
    super.init(nibName: nil, bundle: nil)
    preferredContentSize = NSSize(width: EmberMetrics.popoverWidth, height: 710)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  override func loadView() {
    // Background – dark vibrancy, opaque when Reduce Transparency is enabled.
    let background: NSView
    if NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency {
      let opaque = NSView()
      opaque.wantsLayer = true
      opaque.layer?.backgroundColor = EmberColor.surfaceOpaque.cgColor
      background = opaque
    } else {
      let vibrancy = NSVisualEffectView()
      vibrancy.appearance = NSAppearance(named: .darkAqua)
      vibrancy.material = .hudWindow
      vibrancy.blendingMode = .withinWindow
      vibrancy.state = .active
      background = vibrancy
    }
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

    // Sliders — Software brightness naming (not physical backlight).
    warmthSlider.target = self
    warmthSlider.action = #selector(changeWarmth)
    warmthSlider.setAccessibilityLabel("Warmth")
    warmthSlider.translatesAutoresizingMaskIntoConstraints = false
    brightnessSlider.target = self
    brightnessSlider.action = #selector(changeBrightness)
    brightnessSlider.setAccessibilityLabel("Software brightness")
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
    behaviorRow.onSelect = { [weak self] action in
      self?.coordinator.setMenuBarPrimaryAction(action)
    }
    behaviorRow.setAccessibility()

    settingsCard.translatesAutoresizingMaskIntoConstraints = false
    settingsCard.addRow(backlightRow, showDivider: true)
    settingsCard.addRow(sunScheduleRow, showDivider: true)
    settingsCard.addRow(launchRow, showDivider: true)
    settingsCard.addRow(behaviorRow, showDivider: false)

    // Footer actions
    footerActions.diagnosticsButton.target = self
    footerActions.diagnosticsButton.action = #selector(openDiagnostics)
    footerActions.diagnosticsButton.setAccessibilityLabel("Diagnostics")
    footerActions.quitButton.target = self
    footerActions.quitButton.action = #selector(quitApplication)
    footerActions.quitButton.setAccessibilityLabel("Quit")
    footerActions.translatesAutoresizingMaskIntoConstraints = false

    footerBar.translatesAutoresizingMaskIntoConstraints = false
    footerBar.setText(version: (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String).map { "v\($0)" } ?? AppVersion.displayString)

    // Content: real NSScrollView with pinned footer. Normal state fits without
    // an always-visible scrollbar; larger text/localization/permission errors
    // and the Behavior row scroll instead of compressing controls.
    scrollContent.orientation = .vertical
    scrollContent.alignment = .leading
    scrollContent.spacing = 14
    scrollContent.translatesAutoresizingMaskIntoConstraints = false

    let scroll = NSScrollView()
    scroll.translatesAutoresizingMaskIntoConstraints = false
    scroll.hasVerticalScroller = true
    scroll.hasHorizontalScroller = false
    scroll.autohidesScrollers = true
    scroll.borderType = .noBorder
    scroll.drawsBackground = false
    scroll.documentView = scrollContent
    // Keep footer pinned outside the scroll region.
    background.addSubview(scroll)
    background.addSubview(footerBar)

    NSLayoutConstraint.activate([
      scroll.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: EmberMetrics.contentHInset),
      scroll.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -EmberMetrics.contentHInset),
      scroll.topAnchor.constraint(equalTo: background.topAnchor, constant: 14),
      scroll.bottomAnchor.constraint(equalTo: footerBar.topAnchor, constant: -12),

      scrollContent.widthAnchor.constraint(equalTo: scroll.widthAnchor),

      footerBar.leadingAnchor.constraint(equalTo: background.leadingAnchor),
      footerBar.trailingAnchor.constraint(equalTo: background.trailingAnchor),
      footerBar.bottomAnchor.constraint(equalTo: background.bottomAnchor),
      footerBar.heightAnchor.constraint(equalToConstant: EmberMetrics.footerBarHeight),
    ])
    scrollView = scroll

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

    let brightnessBlock = makeSliderBlock(title: "SOFTWARE BRIGHTNESS", valueLabel: brightnessValue, slider: brightnessSlider, iconName: "sun.max.fill", variant: .brightness)
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

    // Subtle entrance animation – set model transform to identity BEFORE adding
    // the scale animation so content cannot remain at or snap from 0.98.
    let isSnapshot = CommandLine.arguments.contains("--snapshot-ui")
    scrollContent.wantsLayer = true
    if !isSnapshot && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
      scrollContent.alphaValue = 0
      scrollContent.layer?.transform = CATransform3DIdentity
      NSAnimationContext.runAnimationGroup { ctx in
        ctx.duration = 0.28
        ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
        scrollContent.animator().alphaValue = 1
      }
      let scale = CABasicAnimation(keyPath: "transform.scale")
      scale.fromValue = 0.98
      scale.toValue = 1.0
      scale.duration = 0.28
      scale.timingFunction = CAMediaTimingFunction(name: .easeOut)
      scrollContent.layer?.transform = CATransform3DIdentity
      scrollContent.layer?.add(scale, forKey: "entranceScale")
    } else {
      scrollContent.alphaValue = 1
      scrollContent.layer?.transform = CATransform3DIdentity
      scrollContent.layer?.removeAnimation(forKey: "entranceScale")
    }
  }

  override func viewWillDisappear() {
    super.viewWillDisappear()
    // Flush debounced settings/journal; stop orb animation when popover closes.
    coordinator.flushPendingSettings()
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

    // Power button + header ON/OFF — observed truth drives the UI.
    let isActive = snapshot.isObservedActive
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

    // Hero mapping — mechanism-based copy (no health absolutes, no PWM claims).
    let heroTitle: String
    let heroDetail: String
    let metaIconName: String?
    let metaText: String
    var sunsetAttr: NSAttributedString? = nil

    // Render from the single coherent presentation model: never reinterpret raw
    // state separately. Pending-only uses calm copy; real degraded shows attention.
    if let attentionTitle = snapshot.attentionTitle,
      snapshot.statusTitle == "Needs attention"
    {
      heroTitle = attentionTitle
      heroDetail = snapshot.attentionMessage ?? snapshot.statusDetail
      metaIconName = "exclamationmark.triangle.fill"
      metaText = heroDetail
    } else {
      switch snapshot.runtimeState {
      case .active where isActive:
        // Preset-aware titles, mechanism language.
        if abs(settings.warmth - EmberPreset.pureRed.warmth) < 0.01 {
          heroTitle = "Pure Red is on"
          heroDetail = "A red-channel-only display mode for low-light evenings."
        } else if abs(settings.warmth - EmberPreset.evening.warmth) < 0.01 {
          heroTitle = "Evening light is on"
          heroDetail = "Reduces short-wavelength display output for evening use."
        } else if abs(settings.warmth - EmberPreset.neutral.warmth) < 0.01 {
          heroTitle = "Neutral is on"
          heroDetail = "Software dimming with original color preserved."
        } else {
          let kelvinLabel = snapshot.warmthDescription
          if kelvinLabel == "Neutral" {
            heroTitle = "Neutral is on"
            heroDetail = "Software dimming with original color preserved."
          } else if kelvinLabel == "Pure Red" {
            heroTitle = "Pure Red is on"
            heroDetail = "A red-channel-only display mode for low-light evenings."
          } else {
            heroTitle = "\(kelvinLabel) is on"
            heroDetail = "Lower melanopic output can be less disruptive at night, but sensitivity and display spectra vary."
          }
        }
        metaIconName = "clock"
        let count = snapshot.verifiedDisplayCount
        if snapshot.pendingRestoreCount > 0 {
          metaText = "Active on \(count) \(count == 1 ? "display" : "displays") · \(snapshot.pendingRestoreCount) pending"
        } else if snapshot.unsupportedDisplayCount > 0 {
          metaText = "Active on \(count) of \(snapshot.availableDisplayCount) displays"
        } else {
          metaText = "Active on \(count) \(count == 1 ? "display" : "displays")"
        }
        // Structured solar data — never parse English strings for styling.
        if settings.sunScheduleEnabled, let eventDate = snapshot.solarPresentation.eventDate,
          let kind = snapshot.solarPresentation.eventKind
        {
          let name = kind == .sunrise ? "Sunrise" : "Sunset"
          let time = eventDate.formatted(date: .omitted, time: .shortened)
          let prefix: String
          if let override = settings.automationOverride, override.expiresAt > Date() {
            prefix = "Manual override until \(name.lowercased())"
          } else {
            prefix = "Next: \(name)"
          }
          let full = "\(prefix) at \(time)"
          let attr = NSMutableAttributedString(string: full)
          attr.addAttribute(
            .foregroundColor, value: EmberColor.textSecondary,
            range: NSRange(location: 0, length: attr.length))
          attr.addAttribute(
            .font, value: NSFont.systemFont(ofSize: 9.5, weight: .regular),
            range: NSRange(location: 0, length: attr.length))
          let timeRange = (full as NSString).range(of: time)
          if timeRange.location != NSNotFound {
            attr.addAttribute(.foregroundColor, value: EmberColor.ember400, range: timeRange)
            attr.addAttribute(
              .font, value: NSFont.systemFont(ofSize: 9.5, weight: .medium), range: timeRange)
          }
          sunsetAttr = attr
        } else if settings.sunScheduleEnabled,
          snapshot.solarPresentation.isRefreshing
        {
          let attr = NSMutableAttributedString(string: "Getting an approximate location…")
          attr.addAttribute(
            .foregroundColor, value: EmberColor.textSecondary,
            range: NSRange(location: 0, length: attr.length))
          sunsetAttr = attr
        }
      case .degraded(let message):
        heroTitle = "Needs attention"
        heroDetail = message
        metaIconName = "exclamationmark.triangle.fill"
        metaText = message
      case .activating, .reconciling:
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
        if snapshot.statusTitle == "No compatible display" {
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
    }

    // Apply to hero — showWaves honored (extra glow only when active).
    heroView.render(title: heroTitle, detail: heroDetail, metaIconName: metaIconName, metaText: metaText, sunsetText: sunsetAttr, isActive: isActive, showWaves: isActive)

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

    // Backlight capability caption — accurate product language.
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
      backlightRow.detailLabel.stringValue =
        "Keeps a compatible built-in display at full hardware brightness while Ember dims in software. This may reduce brightness-related flicker on some displays; Ember does not measure or guarantee PWM behavior."
      backlightRow.detailLabel.textColor = EmberColor.textSecondary
    } else {
      backlightRow.detailLabel.stringValue =
        "Keeps a compatible built-in display at full hardware brightness while Ember dims in software."
      if case .unavailable(let reason) = snapshot.backlightEngagement,
        settings.backlightLockEnabled
      {
        backlightRow.setCaption(reason, color: EmberColor.warning, showButton: false)
      } else {
        backlightRow.setCaption("Unavailable on this display", color: EmberColor.error, showButton: false)
      }
      backlightRow.detailLabel.textColor = EmberColor.textSecondary
    }
    // Very low software brightness may reduce tonal precision on some displays.
    if settings.apparentBrightness < 0.25, isActive {
      brightnessValue.toolTip = "Very low software brightness may reduce tonal precision or cause banding on some displays."
    } else {
      brightnessValue.toolTip = nil
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
    // Behavior row — compact setting with right-click caption.
    behaviorRow.render(settings.menuBarPrimaryAction)
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
    // No brittle fixed text widths: let the stack determine width from scroll view.
    heading.translatesAutoresizingMaskIntoConstraints = false
    sliderRow.translatesAutoresizingMaskIntoConstraints = false
    return block
  }

  // MARK: - Actions – preserved verbatim logic

  @objc private func toggleMaster() {
    // Observed truth drives the toggle, not desired state alone.
    coordinator.setFilterEnabled(!coordinator.currentSnapshot().isObservedActive)
    NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
  }

  @objc private func selectPreset() {
    let presets: [EmberPreset] = [.neutral, .evening, .pureRed]
    guard pillControl.selectedSegment >= 0, pillControl.selectedSegment < presets.count else { return }
    coordinator.applyPreset(presets[pillControl.selectedSegment])
  }

  @objc private func changeWarmth() {
    // Update value text immediately during drag; gamma writes are coalesced.
    warmthValue.stringValue = {
      let w = warmthSlider.doubleValue / 100
      if let kelvin = ColorCurve.approximateKelvin(forWarmth: w) {
        if w < 0.01 { return "Neutral" }
        return "~\(Int(kelvin.rounded() / 50) * 50) K"
      }
      return "Pure Red"
    }()
    coordinator.setWarmth(warmthSlider.doubleValue / 100)
  }

  @objc private func changeBrightness() {
    brightnessValue.stringValue = "\(Int((brightnessSlider.doubleValue).rounded()))%"
    coordinator.setApparentBrightness(brightnessSlider.doubleValue / 100)
  }

  @objc private func sliderMouseUp() {
    // Flush final value on mouse-up (bounded debounce already coalesces).
    coordinator.flushPendingSettings()
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