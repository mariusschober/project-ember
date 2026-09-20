#include "ui/DiagnosticsDialog.h"

#include "AppController.h"

#include <QClipboard>
#include <QFileDialog>
#include <QGuiApplication>
#include <QHBoxLayout>
#include <QPlainTextEdit>
#include <QPushButton>
#include <QTextStream>
#include <QVBoxLayout>

namespace ember {

DiagnosticsDialog::DiagnosticsDialog(AppController *controller)
    : QDialog(nullptr), controller_(controller) {
  setWindowTitle(QStringLiteral("Project Ember diagnostics"));
  resize(620, 430);
  auto *root = new QVBoxLayout(this);
  text_ = new QPlainTextEdit(this);
  text_->setReadOnly(true);
  root->addWidget(text_);
  auto *buttons = new QHBoxLayout;
  auto *retry = new QPushButton(QStringLiteral("Retry"), this);
  auto *restore = new QPushButton(QStringLiteral("Emergency restore"), this);
  auto *copy = new QPushButton(QStringLiteral("Copy"), this);
  auto *exportButton = new QPushButton(QStringLiteral("Export…"), this);
  buttons->addWidget(retry);
  buttons->addWidget(restore);
  buttons->addStretch();
  buttons->addWidget(copy);
  buttons->addWidget(exportButton);
  root->addLayout(buttons);
  connect(controller_, &AppController::statusChanged, this, [this](const QVariantMap &) { refreshFromController(); });
  connect(retry, &QPushButton::clicked, controller_, &AppController::retry);
  connect(restore, &QPushButton::clicked, controller_, &AppController::restore);
  connect(copy, &QPushButton::clicked, this, [this] { QGuiApplication::clipboard()->setText(text_->toPlainText()); });
  connect(exportButton, &QPushButton::clicked, this, [this] {
    const QString path = QFileDialog::getSaveFileName(this, QStringLiteral("Export diagnostics"), QStringLiteral("project-ember-diagnostics.json"), QStringLiteral("JSON (*.json);;Text (*.txt)"));
    if (path.isEmpty()) return;
    QFile file(path);
    if (file.open(QIODevice::WriteOnly | QIODevice::Truncate)) {
      file.write(text_->toPlainText().toUtf8());
      file.close();
    }
  });
  refreshFromController();
}

void DiagnosticsDialog::refreshFromController() {
  if (controller_ != nullptr && text_ != nullptr) text_->setPlainText(controller_->diagnosticsText());
}

} // namespace ember
