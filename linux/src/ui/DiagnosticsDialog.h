#pragma once

#include <QDialog>

class QLabel;
class QPlainTextEdit;
class QPushButton;

namespace ember {

class AppController;

class DiagnosticsDialog final : public QDialog {
  Q_OBJECT

public:
  explicit DiagnosticsDialog(AppController *controller);
  void refreshFromController();

private:
  AppController *controller_;
  QPlainTextEdit *text_ = nullptr;
  QPushButton *acceptCurrent_ = nullptr;
  QPushButton *discardRecovery_ = nullptr;
  QPushButton *replaceSettings_ = nullptr;
};

} // namespace ember
