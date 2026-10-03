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

  private let backlightRow = EmberToggleRowView(iconSymbol: "shield.lefthalf.filled", title: "Backlight Lock", detail: "Full hardware brightness while Ember dims in software.")
  private let sunScheduleRow = EmberToggleRowView(iconSymbol: "sun.horizon", title: "Sun schedule", detail: "Turns Ember on at sunset and restores it at sunrise.")
  private let launchRow = EmberToggleRowView(iconSymbol: "paperplane.fill", title: "Launch at login", detail: "Apply your saved preference after sign-in.")
  private let behaviorRow = EmberBehaviorRowView()
  private let settingsCard = EmberSettingsCard()

  private let footerActions = EmberFooterActionsView()
  private let footerBar = EmberFooterBarView()

  private let scrollContent = NSStackView()
  /// Real scroll view: on short displays (or any state taller than the screen)
  /// the panel scrolls instead of clipping the Diagnostics/Quit row.
  private let scrollView = NSScrollView()
  private let documentView = FlippedDocumentView()
  /// One-time first-launch explanation, shown above the hero.
  private let firstRunHint = EmberFirstRunHintView()
  /// Requested hint visibility, remembered so a call made before the view is
  /// loaded still applies (AppDelegate asks for it before the popover opens).
  private var wantsFirstRunHint = false

  init(coordinator: DisplayCoordinator, showDiagnostics: @escaping () -> Void) {
    self.coordinator = coordinator
    self.showDiagnostics = showDiagnostics
    super.init(nibName: nil, bundle: nil)
    // Provisional size only: render() measures the content and sets the real
    // height, clamped to the screen (see preferredPanelSize).
    preferredContentSize = NSSize(width: EmberMetrics.popoverWidth, height: 700)
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

    // Header is static branding; the hero orb is the panel's on/off control.
    headerView.translatesAutoresizingMaskIntoConstraints = false

    // Hero
    heroView.translatesAutoresizingMaskIntoConstraints = false
    heroView.wantsLayer = true
    heroView.onOrbToggle = { [weak self] in self?.toggleMaster() }

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

    // Content: a scrolling document pinned to the fixed content width, with
    // the footer bar outside the scroll view so Quit/Diagnostics are always
    // one small scroll away rather than clipped off the panel (audit C1).
    // The document width is a constant, never derived from bounds, so the
    // width↔wrap feedback loop DesignTokens warns about cannot return here.
    scrollContent.orientation = .vertical
    scrollContent.alignment = .leading
    scrollContent.spacing = EmberMetrics.stackSpacing
    scrollContent.translatesAutoresizingMaskIntoConstraints = false

    documentView.addSubview(scrollContent)

    scrollView.drawsBackground = false
    scrollView.borderType = .noBorder
    scrollView.hasVerticalScroller = true
    scrollView.autohidesScrollers = true
    // Overlay scrollers never steal width from the fixed 390 pt column.
    scrollView.scrollerStyle = .overlay
    scrollView.horizontalScrollElasticity = .none
    scrollView.verticalScrollElasticity = .automatic
    scrollView.documentView = documentView
    scrollView.translatesAutoresizingMaskIntoConstraints = false

    background.addSubview(scrollView)
    background.addSubview(footerBar)

    NSLayoutConstraint.activate([
      scrollView.leadingAnchor.constraint(
        equalTo: background.leadingAnchor, constant: EmberMetrics.contentHInset),
      scrollView.trailingAnchor.constraint(
        equalTo: background.trailingAnchor, constant: -EmberMetrics.contentHInset),
      scrollView.topAnchor.constraint(
        equalTo: background.topAnchor, constant: EmberMetrics.panelTopInset),
      scrollView.bottomAnchor.constraint(
        equalTo: footerBar.topAnchor, constant: -EmberMetrics.panelBottomGap),

      // Top/leading/trailing only: the document's height comes from the content
      // (syncDocumentSize), never from the clip view, so scrolling cannot feed
      // back into layout.
      scrollContent.leadingAnchor.constraint(equalTo: documentView.leadingAnchor),
      scrollContent.trailingAnchor.constraint(equalTo: documentView.trailingAnchor),
      scrollContent.topAnchor.constraint(equalTo: documentView.topAnchor),

      footerBar.leadingAnchor.constraint(equalTo: background.leadingAnchor),
      footerBar.trailingAnchor.constraint(equalTo: background.trailingAnchor),
      footerBar.bottomAnchor.constraint(equalTo: background.bottomAnchor),
      footerBar.heightAnchor.constraint(equalToConstant: EmberMetrics.footerBarHeight),
    ])

    // Now populate stack – width constraints are safe now that scrollContent has superview
    scrollContent.addArrangedSubview(headerView)
    headerView.widthAnchor.constraint(equalTo: scrollContent.widthAnchor).isActive = true

    // First-launch explanation, hidden unless AppDelegate asks for it.
    firstRunHint.isHidden = !wantsFirstRunHint
    scrollContent.addArrangedSubview(firstRunHint)
    firstRunHint.widthAnchor.constraint(equalTo: scrollContent.widthAnchor).isActive = true

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
    // The first-launch explanation is once-per-install; the popover closing is
    // proof enough that it was seen.
    setFirstRunHint(false)
    // Reopening always starts at the top of the panel.
    scrollView.contentView.scroll(to: .zero)
    scrollView.reflectScrolledClipView(scrollView.contentView)
    // Flush debounced settings/journal; stop orb animation when popover closes.
    coordinator.flushPendingSettings()
  }

  // MARK: - Content-driven size (audit C1 / M11)

  /// Shows or hides the one-time first-launch explanation.
  func setFirstRunHint(_ visible: Bool) {
    wantsFirstRunHint = visible
    guard isViewLoaded else { return }
    // Target state, not the requested flag: comparing `isHidden == visible`
    // here inverts the test and the card could never be hidden again.
    let targetHidden = !visible
    guard firstRunHint.isHidden != targetHidden else { return }
    firstRunHint.isHidden = targetHidden
    updatePreferredContentSize()
  }

  /// Sizes the scrolling document to the content's natural height at the fixed
  /// content width. The height is measured from the stack (whose bottom is
  /// deliberately unpinned), so the clip view's own size can never feed back
  /// into wrapping.
  private func syncDocumentSize() {
    let width = EmberMetrics.contentWidth
    // Generous first pass: the stack resolves its natural height, then the
    // document adopts exactly that.
    documentView.setFrameSize(NSSize(width: width, height: 4000))
    documentView.layoutSubtreeIfNeeded()
    let natural = max(scrollContent.frame.height, scrollContent.fittingSize.height)
    let height = max(1, natural.rounded(.up))
    if documentView.frame.size != NSSize(width: width, height: height)
      || documentView.frame.origin != .zero
    {
      documentView.setFrameSize(NSSize(width: width, height: height))
      documentView.setFrameOrigin(.zero)
      documentView.layoutSubtreeIfNeeded()
    }
  }

  /// Content-driven panel size, clamped to the space that is actually available
  /// below the status item. Pure, so short-screen geometry can be exercised
  /// (offscreen probes, tests) without touching a display.
  func preferredPanelSize(forVisibleFrameHeight visibleHeight: CGFloat) -> NSSize {
    syncDocumentSize()
    let natural =
      EmberMetrics.panelTopInset + documentView.frame.height
      + EmberMetrics.panelBottomGap + EmberMetrics.footerBarHeight
    let available = max(160, visibleHeight - EmberMetrics.popoverChromeHeight)
    let height = min(max(natural.rounded(.up), EmberMetrics.panelMinHeight), available)
    return NSSize(width: EmberMetrics.popoverWidth, height: height)
  }

  private func updatePreferredContentSize() {
    guard isViewLoaded else { return }
    let visibleHeight = (view.window?.screen ?? NSScreen.main)?.visibleFrame.height ?? 900
    let size = preferredPanelSize(forVisibleFrameHeight: visibleHeight)
    if preferredContentSize != size { preferredContentSize = size }
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

    // Switches — programmatic sync never animates (7.3: avoids shimmer on
    // unrelated renders); only user toggles animate via the control itself.
    if backlightRow.toggle.isOn != settings.backlightLockEnabled {
      backlightRow.toggle.setOn(settings.backlightLockEnabled, animated: false)
    }
    if sunScheduleRow.toggle.isOn != settings.sunScheduleEnabled {
      sunScheduleRow.toggle.setOn(settings.sunScheduleEnabled, animated: false)
    }
    if launchRow.toggle.isOn != settings.launchAtLogin {
      launchRow.toggle.setOn(settings.launchAtLogin, animated: false)
    }

    // Observed truth drives the UI. The hero orb is the on/off control.
    let isActive = snapshot.isObservedActive
    let controlsEnabled = snapshot.displayAvailable && !snapshot.isBusy
    heroView.setOrbEnabled(controlsEnabled)

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
      // Never the body sentence again: the second copy was always ellipsized
      // (audit C3). The meta row is a short status, not a second paragraph.
      metaText = metaStatus(for: snapshot)
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
        metaText = metaStatus(for: snapshot)
      case .activating, .reconciling:
        heroTitle = "Applying…"
        heroDetail = "Saving every display state first…"
        metaIconName = "arrow.triangle.2.circlepath"
        metaText = "Working…"
      case .restoring(let intent):
        heroTitle = "Restoring…"
        heroDetail = intent == .sleep ? "Preparing every display for sleep…" : "Returning every display to its saved state…"
        metaIconName = "arrow.triangle.2.circlepath"
        metaText = intent == .sleep ? "Preparing for sleep" : "Restoring saved state"
      case .suspended:
        heroTitle = "Paused for sleep"
        heroDetail = "Ember will safely re-evaluate after wake."
        metaIconName = "moon.zzz.fill"
        metaText = "Paused"
      default: // .off
        if snapshot.statusTitle == "No compatible display" {
          heroTitle = "No compatible display"
          heroDetail = snapshot.statusDetail
          metaIconName = "display.trianglebadge.exclamationmark"
          metaText = metaStatus(for: snapshot)
        } else if snapshot.statusTitle == "Needs attention" {
          heroTitle = snapshot.statusTitle
          heroDetail = snapshot.statusDetail
          metaIconName = "exclamationmark.triangle.fill"
          metaText = metaStatus(for: snapshot)
        } else if let attentionMessage = snapshot.attentionMessage {
          // Info-level attention (e.g. "Waiting for display") used to be dropped
          // entirely while the panel still said "Ready".
          heroTitle = snapshot.attentionTitle ?? "Ember is off"
          heroDetail = attentionMessage
          metaIconName = "clock"
          metaText = metaStatus(for: snapshot)
        } else {
          // The off state is stated out loud and the orb is named as the way to
          // turn Ember on (audit C6).
          heroTitle = "Ember is off"
          if snapshot.displayAvailable {
            heroDetail = "Your original display state is untouched. Click the orb to turn it on."
            metaIconName = "checkmark.circle.fill"
          } else {
            heroDetail = snapshot.statusDetail
            metaIconName = "circle.fill"
          }
          metaText = metaStatus(for: snapshot)
        }
      }
    }

    // Apply to hero — showWaves honored (extra glow only when active).
    heroView.render(title: heroTitle, detail: heroDetail, metaIconName: metaIconName, metaText: metaText, sunsetText: sunsetAttr, isActive: isActive, showWaves: isActive)

    // Sunset handling when not active: if hero already shows sunsetAttr, keep; else hide second line
    // For active, hero's sunsetLabel shows solar detail; for off, hide if no schedule
    // Additional pulsate control handled inside HeroStatusView

    // Controls enabled
    pillControl.isEnabled = controlsEnabled
    pillControl.alphaValue = controlsEnabled ? 1 : 0.45
    warmthSlider.isEnabled = controlsEnabled
    brightnessSlider.isEnabled = controlsEnabled
    // Warmth/brightness value alpha
    warmthValue.alphaValue = controlsEnabled ? 1 : 0.45
    brightnessValue.alphaValue = controlsEnabled ? 1 : 0.45
    // VoiceOver reads the slider's value as a number by default; the formatted
    // readout ("~2700 K" / "62%") is what the panel actually shows.
    warmthSlider.setAccessibilityValueDescription(warmthValue.stringValue)
    brightnessSlider.setAccessibilityValueDescription(brightnessValue.stringValue)

    backlightRow.toggle.isEnabled = controlsEnabled && snapshot.backlightAvailable
    backlightRow.alphaValue = (controlsEnabled && snapshot.backlightAvailable) ? 1 : 0.55
    sunScheduleRow.toggle.isEnabled = !snapshot.isBusy
    sunScheduleRow.alphaValue = snapshot.isBusy ? 0.6 : 1
    // Launch row needs the same dimming as the other two: a disabled switch that
    // looks enabled is a lie the user only discovers by clicking (audit M8).
    launchRow.toggle.isEnabled = !snapshot.isBusy
    launchRow.alphaValue = snapshot.isBusy ? 0.6 : 1

    // Backlight capability caption — accurate product language, complete at the
    // three-line cap so the PWM qualification is never cut mid-sentence (C4).
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
        "Full hardware brightness while Ember dims in software. May reduce flicker; Ember does not measure PWM."
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

    // Content changed: re-measure the document and re-clamp the panel height
    // (audit C1/M11 — the panel used to be a fixed 810 pt with a dead band).
    updatePreferredContentSize()
  }

  /// Compact one-line status for the hero meta row. The body sentence already
  /// lives in the hero detail; repeating it here produced an always-ellipsized
  /// duplicate (audit C3) and, at 198 pt, widened the whole panel (C2).
  private func metaStatus(for snapshot: EmberSnapshot) -> String {
    if snapshot.pendingRestoreCount > 0 {
      let count = snapshot.pendingRestoreCount
      return "\(count) \(count == 1 ? "display" : "displays") pending restore"
    }
    if snapshot.failedDisplayCount > 0 {
      let count = snapshot.failedDisplayCount
      return "\(count) \(count == 1 ? "display" : "displays") need attention"
    }
    guard snapshot.displayAvailable else { return "Connect a supported display" }
    let count = snapshot.availableDisplayCount
    return "\(count) \(count == 1 ? "display" : "displays") available"
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
    // Fixed minimum width so value swaps ("Pure Red" ↔ "~2700 K" ↔ "62%")
    // never shift the heading or slider row.
    valueLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 64).isActive = true
    if let cell = valueLabel.cell as? NSTextFieldCell { cell.alignment = .right }

    let spacer = NSView()
    spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
    let heading = NSStackView(views: [titleLabel, spacer, valueLabel])
    heading.orientation = .horizontal
    heading.alignment = .centerY

    // Icon + slider row — leading inset matches the row grid (Sec 1) so the
    // sun icons line up with the toggle-row icon column.
    let icon = NSImageView(image: NSImage(systemSymbolName: iconName, accessibilityDescription: title) ?? NSImage())
    icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
    icon.contentTintColor = EmberColor.textTertiary
    icon.translatesAutoresizingMaskIntoConstraints = false
    icon.widthAnchor.constraint(equalToConstant: EmberMetrics.rowIconWidth).isActive = true
    icon.heightAnchor.constraint(equalToConstant: EmberMetrics.rowIconWidth).isActive = true

    let leadingPad = NSView()
    leadingPad.translatesAutoresizingMaskIntoConstraints = false
    leadingPad.widthAnchor.constraint(equalToConstant: EmberMetrics.rowLeadingInset).isActive = true

    slider.translatesAutoresizingMaskIntoConstraints = false
    slider.widthAnchor.constraint(greaterThanOrEqualToConstant: 200).isActive = true
    // The thumb is drawn 22 pt but NSSlider's intrinsic height is 16 pt, so the
    // top/bottom 3 pt of the visible thumb used to drop clicks (audit M12).
    slider.heightAnchor.constraint(
      greaterThanOrEqualToConstant: EmberMetrics.sliderHitHeight
    ).isActive = true

    let sliderRow = NSStackView(views: [leadingPad, icon, slider])
    sliderRow.orientation = .horizontal
    sliderRow.alignment = .centerY
    sliderRow.spacing = EmberMetrics.rowIconTextGap
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

  /// Using a preset or a slider while Ember is off turns Ember on, matching the
  /// status-item toggle semantics. Without this the control animates, the value
  /// label changes, and nothing happens on screen (audit M1/C6).
  private func ensureEmberIsOn() {
    let snapshot = coordinator.currentSnapshot()
    guard snapshot.displayAvailable, !snapshot.isBusy, !snapshot.isObservedActive,
      !snapshot.settings.filterEnabled
    else { return }
    coordinator.setFilterEnabled(true)
  }

  @objc private func toggleMaster() {
    // Observed truth drives the toggle, not desired state alone.
    coordinator.setFilterEnabled(!coordinator.currentSnapshot().isObservedActive)
    NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
  }

  @objc private func selectPreset() {
    let presets: [EmberPreset] = [.neutral, .evening, .pureRed]
    guard pillControl.selectedSegment >= 0, pillControl.selectedSegment < presets.count else { return }
    coordinator.applyPreset(presets[pillControl.selectedSegment])
    ensureEmberIsOn()
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
    ensureEmberIsOn()
  }

  @objc private func changeBrightness() {
    brightnessValue.stringValue = "\(Int((brightnessSlider.doubleValue).rounded()))%"
    coordinator.setApparentBrightness(brightnessSlider.doubleValue / 100)
    ensureEmberIsOn()
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

/// Scroll-view document that lays out top-down, so the clip view's origin
/// (0, 0) is the top of the panel — the header — rather than its bottom edge.
@MainActor
private final class FlippedDocumentView: NSView {
  override var isFlipped: Bool { true }
}
