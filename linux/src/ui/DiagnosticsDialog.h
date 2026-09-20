#pragma once

#include <QDialog>

class QLabel;
class QPlainTextEdit;

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
};

} // namespace ember
