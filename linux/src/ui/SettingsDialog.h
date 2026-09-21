#pragma once

#include <QDialog>

class QLabel;
class QCheckBox;
class QComboBox;
class QDoubleSpinBox;
class QPushButton;
class QSlider;

namespace ember {

class AppController;

class SettingsDialog final : public QDialog {
  Q_OBJECT

public:
  explicit SettingsDialog(AppController *controller);
  void refreshFromController();

private slots:
  void warmthChanged(int value);
  void brightnessChanged(int value);
  void chooseLocation();

private:
  AppController *controller_;
  QLabel *statusLabel_ = nullptr;
  QLabel *statusDetailLabel_ = nullptr;
  QPushButton *toggleButton_ = nullptr;
  QPushButton *neutralButton_ = nullptr;
  QPushButton *eveningButton_ = nullptr;
  QPushButton *pureRedButton_ = nullptr;
  QPushButton *resumeAutomationButton_ = nullptr;
  QSlider *warmthSlider_ = nullptr;
  QSlider *brightnessSlider_ = nullptr;
  QLabel *warmthValue_ = nullptr;
  QLabel *brightnessValue_ = nullptr;
  QCheckBox *backlightCheck_ = nullptr;
  QCheckBox *scheduleCheck_ = nullptr;
  QCheckBox *loginCheck_ = nullptr;
  QComboBox *primaryAction_ = nullptr;
  QDoubleSpinBox *latitude_ = nullptr;
  QDoubleSpinBox *longitude_ = nullptr;
};

} // namespace ember
