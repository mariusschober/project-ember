#include "ui/SettingsDialog.h"

#include "AppController.h"

#include <QCheckBox>
#include <QComboBox>
#include <QDoubleSpinBox>
#include <QFormLayout>
#include <QGroupBox>
#include <QHBoxLayout>
#include <QLabel>
#include <QPushButton>
#include <QSlider>
#include <QVBoxLayout>

namespace ember {

SettingsDialog::SettingsDialog(AppController *controller)
    : QDialog(nullptr), controller_(controller) {
  setWindowTitle(QStringLiteral("Project Ember"));
  setModal(false);
  setMinimumWidth(420);
  setAttribute(Qt::WA_DeleteOnClose, false);

  auto *root = new QVBoxLayout(this);
  statusLabel_ = new QLabel(this);
  statusLabel_->setTextInteractionFlags(Qt::TextSelectableByMouse);
  QFont statusFont = statusLabel_->font();
  statusFont.setBold(true);
  statusLabel_->setFont(statusFont);
  root->addWidget(statusLabel_);
  statusDetailLabel_ = new QLabel(this);
  statusDetailLabel_->setWordWrap(true);
  root->addWidget(statusDetailLabel_);

  auto *toggleRow = new QHBoxLayout;
  toggleButton_ = new QPushButton(this);
  toggleButton_->setAccessibleName(QStringLiteral("Turn Project Ember on or off"));
  toggleRow->addWidget(toggleButton_);
  auto *restoreButton = new QPushButton(QStringLiteral("Restore"), this);
  toggleRow->addWidget(restoreButton);
  root->addLayout(toggleRow);

  auto *presets = new QGroupBox(QStringLiteral("Warmth"), this);
  auto *presetLayout = new QHBoxLayout(presets);
  for (const auto &item : {std::pair<QString, QString>{QStringLiteral("Neutral"), QStringLiteral("neutral")},
                           {QStringLiteral("Evening"), QStringLiteral("evening")},
                           {QStringLiteral("Pure Red"), QStringLiteral("pure-red")}}) {
    auto *button = new QPushButton(item.first, presets);
    button->setAccessibleName(QStringLiteral("Set %1 preset").arg(item.first));
    connect(button, &QPushButton::clicked, this, [this, name = item.second] { controller_->setPreset(name); });
    presetLayout->addWidget(button);
  }
  root->addWidget(presets);

  auto *controls = new QFormLayout;
  warmthSlider_ = new QSlider(Qt::Horizontal, this);
  warmthSlider_->setRange(0, 100);
  warmthSlider_->setAccessibleName(QStringLiteral("Warmth from neutral to Pure Red"));
  warmthValue_ = new QLabel(this);
  auto *warmRow = new QHBoxLayout;
  warmRow->addWidget(warmthSlider_);
  warmRow->addWidget(warmthValue_);
  controls->addRow(QStringLiteral("Warmth"), warmRow);

  brightnessSlider_ = new QSlider(Qt::Horizontal, this);
  brightnessSlider_->setRange(10, 100);
  brightnessSlider_->setAccessibleName(QStringLiteral("Software brightness"));
  brightnessValue_ = new QLabel(this);
  auto *brightnessRow = new QHBoxLayout;
  brightnessRow->addWidget(brightnessSlider_);
  brightnessRow->addWidget(brightnessValue_);
  controls->addRow(QStringLiteral("Software brightness"), brightnessRow);
  root->addLayout(controls);

  backlightCheck_ = new QCheckBox(QStringLiteral("Backlight Lock (built-in LCD only)"), this);
  backlightCheck_->setToolTip(QStringLiteral("Requires an unambiguous writable built-in backlight and supervised crash recovery."));
  root->addWidget(backlightCheck_);

  auto *scheduleGroup = new QGroupBox(QStringLiteral("Sun schedule"), this);
  auto *scheduleLayout = new QVBoxLayout(scheduleGroup);
  scheduleCheck_ = new QCheckBox(QStringLiteral("Enable local sunrise/sunset scheduling"), scheduleGroup);
  scheduleLayout->addWidget(scheduleCheck_);
  auto *locationForm = new QFormLayout;
  latitude_ = new QDoubleSpinBox(scheduleGroup);
  latitude_->setRange(-90.0, 90.0);
  latitude_->setDecimals(1);
  latitude_->setSingleStep(0.1);
  latitude_->setSpecialValueText(QStringLiteral("0.0 is valid"));
  longitude_ = new QDoubleSpinBox(scheduleGroup);
  longitude_->setRange(-180.0, 180.0);
  longitude_->setDecimals(1);
  longitude_->setSingleStep(0.1);
  locationForm->addRow(QStringLiteral("Latitude"), latitude_);
  locationForm->addRow(QStringLiteral("Longitude"), longitude_);
  scheduleLayout->addLayout(locationForm);
  auto *locationButtons = new QHBoxLayout;
  auto *setLocationButton = new QPushButton(QStringLiteral("Save location"), scheduleGroup);
  auto *clearLocationButton = new QPushButton(QStringLiteral("Remove location"), scheduleGroup);
  locationButtons->addWidget(setLocationButton);
  locationButtons->addWidget(clearLocationButton);
  scheduleLayout->addLayout(locationButtons);
  root->addWidget(scheduleGroup);

  auto *credit = new QLabel(
      QStringLiteral("Designed by <a href=\"https://mariusschober.com/\">Marius Schober</a> for circadian-aware evenings."), this);
  credit->setTextFormat(Qt::RichText);
  credit->setOpenExternalLinks(true);
  credit->setTextInteractionFlags(Qt::TextBrowserInteraction);
  root->addWidget(credit);

  loginCheck_ = new QCheckBox(QStringLiteral("Launch at login"), this);
  root->addWidget(loginCheck_);
  primaryAction_ = new QComboBox(this);
  primaryAction_->addItem(QStringLiteral("Primary tray click opens settings"), QStringLiteral("openControls"));
  primaryAction_->addItem(QStringLiteral("Primary tray click toggles Ember"), QStringLiteral("toggleEmber"));
  root->addWidget(primaryAction_);

  auto *bottom = new QHBoxLayout;
  auto *diagnostics = new QPushButton(QStringLiteral("Diagnostics…"), this);
  auto *quitButton = new QPushButton(QStringLiteral("Quit"), this);
  bottom->addWidget(diagnostics);
  bottom->addStretch();
  bottom->addWidget(quitButton);
  root->addLayout(bottom);

  connect(controller_, &AppController::statusChanged, this, [this](const QVariantMap &) { refreshFromController(); });
  connect(toggleButton_, &QPushButton::clicked, this, [this] { controller_->setFilterEnabled(!controller_->settings().filterEnabled); });
  connect(restoreButton, &QPushButton::clicked, controller_, &AppController::restore);
  connect(warmthSlider_, &QSlider::valueChanged, this, &SettingsDialog::warmthChanged);
  connect(brightnessSlider_, &QSlider::valueChanged, this, &SettingsDialog::brightnessChanged);
  connect(backlightCheck_, &QCheckBox::toggled, controller_, &AppController::setBacklightLock);
  connect(scheduleCheck_, &QCheckBox::toggled, controller_, &AppController::setSchedule);
  connect(loginCheck_, &QCheckBox::toggled, controller_, &AppController::setLaunchAtLogin);
  connect(primaryAction_, &QComboBox::currentIndexChanged, this, [this](int index) {
    controller_->setPrimaryAction(primaryAction_->itemData(index).toString());
  });
  connect(setLocationButton, &QPushButton::clicked, this, &SettingsDialog::chooseLocation);
  connect(clearLocationButton, &QPushButton::clicked, controller_, &AppController::clearLocation);
  connect(diagnostics, &QPushButton::clicked, controller_, &AppController::openDiagnostics);
  connect(quitButton, &QPushButton::clicked, controller_, &AppController::quit);
  refreshFromController();
}

void SettingsDialog::refreshFromController() {
  if (controller_ == nullptr) return;
  const Settings &settings = controller_->settings();
  const QVariantMap status = controller_->status();
  statusLabel_->setText(status.value(QStringLiteral("statusTitle")).toString());
  QString detail = status.value(QStringLiteral("statusDetail")).toString();
  if (status.value(QStringLiteral("solarState")).toString() == QStringLiteral("waiting_for_location")) {
    detail += QStringLiteral("\nSun schedule is waiting for a location.");
  } else if (status.contains(QStringLiteral("solarNextEvent"))) {
    detail += QStringLiteral("\nNext %1: %2%3")
        .arg(status.value(QStringLiteral("solarNextEventKind")).toString(),
             status.value(QStringLiteral("solarNextEvent")).toString(),
             status.value(QStringLiteral("solarOverrideActive")).toBool() ? QStringLiteral(" (manual override active)") : QString());
  }
  statusDetailLabel_->setText(detail
      + (status.value(QStringLiteral("attentionMessage")).toString().isEmpty()
          ? QString() : QStringLiteral("\n\n%1").arg(status.value(QStringLiteral("attentionMessage")).toString())));
  toggleButton_->setText(settings.filterEnabled ? QStringLiteral("Turn Ember Off") : QStringLiteral("Turn Ember On"));
  warmthSlider_->blockSignals(true);
  warmthSlider_->setValue(qRound(settings.warmth * 100.0));
  warmthSlider_->blockSignals(false);
  warmthValue_->setText(QStringLiteral("%1 — %2").arg(qRound(settings.warmth * 100.0)).arg(describeWarmth(settings.warmth)));
  brightnessSlider_->blockSignals(true);
  brightnessSlider_->setValue(qRound(settings.brightness * 100.0));
  brightnessSlider_->blockSignals(false);
  brightnessValue_->setText(QStringLiteral("%1%").arg(qRound(settings.brightness * 100.0)));
  backlightCheck_->blockSignals(true);
  backlightCheck_->setChecked(settings.backlightLockEnabled);
  backlightCheck_->setEnabled(status.value(QStringLiteral("backlightAvailable")).toBool() || settings.backlightLockEnabled);
  backlightCheck_->setToolTip(status.value(QStringLiteral("backlightReason")).toString().isEmpty()
      ? QStringLiteral("Requires supervised crash recovery and a real built-in LCD backlight")
      : status.value(QStringLiteral("backlightReason")).toString());
  backlightCheck_->blockSignals(false);
  scheduleCheck_->blockSignals(true);
  scheduleCheck_->setChecked(settings.sunScheduleEnabled);
  scheduleCheck_->blockSignals(false);
  loginCheck_->blockSignals(true);
  loginCheck_->setChecked(status.value(QStringLiteral("loginRegistered")).toBool());
  loginCheck_->blockSignals(false);
  primaryAction_->blockSignals(true);
  const int actionIndex = primaryAction_->findData(primaryActionName(settings.primaryAction));
  primaryAction_->setCurrentIndex(actionIndex < 0 ? 0 : actionIndex);
  primaryAction_->blockSignals(false);
  if (settings.location.has_value()) {
    latitude_->setValue(settings.location->latitude);
    longitude_->setValue(settings.location->longitude);
  } else {
    latitude_->setValue(0.0);
    longitude_->setValue(0.0);
  }
}

void SettingsDialog::warmthChanged(int value) { controller_->setWarmth(static_cast<double>(value) / 100.0); }
void SettingsDialog::brightnessChanged(int value) { controller_->setBrightness(static_cast<double>(value) / 100.0); }
void SettingsDialog::chooseLocation() { controller_->setLocation(latitude_->value(), longitude_->value()); }

} // namespace ember
