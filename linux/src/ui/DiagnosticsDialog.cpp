#include "ui/DiagnosticsDialog.h"

#include "AppController.h"

#include <QClipboard>
#include <QFileDialog>
#include <QGuiApplication>
#include <QGridLayout>
#include <QHBoxLayout>
#include <QMessageBox>
#include <QPlainTextEdit>
#include <QPushButton>
#include <QSaveFile>
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
  auto *recoveryButtons = new QGridLayout;
  auto *outputButtons = new QHBoxLayout;
  auto *retry = new QPushButton(QStringLiteral("Retry"), this);
  auto *restore = new QPushButton(QStringLiteral("Emergency restore"), this);
  acceptCurrent_ = new QPushButton(QStringLiteral("Keep verified current hardware"), this);
  discardRecovery_ = new QPushButton(QStringLiteral("Discard unreadable recovery evidence"), this);
  replaceSettings_ = new QPushButton(QStringLiteral("Replace unreadable settings"), this);
  auto *copy = new QPushButton(QStringLiteral("Copy"), this);
  auto *exportButton = new QPushButton(QStringLiteral("Export…"), this);
  recoveryButtons->addWidget(retry, 0, 0);
  recoveryButtons->addWidget(restore, 0, 1);
  recoveryButtons->addWidget(acceptCurrent_, 1, 0);
  recoveryButtons->addWidget(discardRecovery_, 1, 1);
  recoveryButtons->addWidget(replaceSettings_, 2, 0, 1, 2);
  outputButtons->addStretch();
  outputButtons->addWidget(copy);
  outputButtons->addWidget(exportButton);
  root->addLayout(recoveryButtons);
  root->addLayout(outputButtons);
  connect(controller_, &AppController::statusChanged, this, [this](const QVariantMap &) { refreshFromController(); });
  connect(retry, &QPushButton::clicked, controller_, &AppController::retry);
  connect(restore, &QPushButton::clicked, controller_, &AppController::restore);
  connect(acceptCurrent_, &QPushButton::clicked, this, [this] {
    const auto choice = QMessageBox::warning(
        this, QStringLiteral("Resolve hardware recovery"),
        QStringLiteral("This keeps the current identity-verified brightness and automatic-brightness values instead of restoring Ember's saved baseline. No hardware value will be changed. Continue?"),
        QMessageBox::Yes | QMessageBox::Cancel, QMessageBox::Cancel);
    if (choice == QMessageBox::Yes) controller_->acceptCurrentHardwareState();
  });
  connect(discardRecovery_, &QPushButton::clicked, this, [this] {
    const auto choice = QMessageBox::critical(
        this, QStringLiteral("Discard unreadable recovery evidence"),
        QStringLiteral("Only continue after independently confirming that hardware brightness and automatic brightness are safe. This permanently discards unreadable recovery evidence, changes no hardware value, disables Backlight Lock, and keeps Sun automation paused."),
        QMessageBox::Yes | QMessageBox::Cancel, QMessageBox::Cancel);
    if (choice == QMessageBox::Yes) controller_->discardUnreadableRecoveryEvidence();
  });
  connect(replaceSettings_, &QPushButton::clicked, this, [this] {
    const auto choice = QMessageBox::warning(
        this, QStringLiteral("Replace unreadable settings"),
        QStringLiteral("This explicitly replaces the preserved unreadable or future-version settings file with the values currently shown by this version of Ember. Continue?"),
        QMessageBox::Yes | QMessageBox::Cancel, QMessageBox::Cancel);
    if (choice == QMessageBox::Yes) controller_->replaceUnreadableSettings();
  });
  connect(copy, &QPushButton::clicked, this, [this] { QGuiApplication::clipboard()->setText(text_->toPlainText()); });
  connect(exportButton, &QPushButton::clicked, this, [this] {
    const QString path = QFileDialog::getSaveFileName(this, QStringLiteral("Export diagnostics"), QStringLiteral("project-ember-diagnostics.json"), QStringLiteral("JSON (*.json);;Text (*.txt)"));
    if (path.isEmpty()) return;
    QSaveFile file(path);
    const QByteArray diagnostics = text_->toPlainText().toUtf8();
    if (!file.open(QIODevice::WriteOnly) || file.write(diagnostics) != diagnostics.size() || !file.commit()) {
      QMessageBox::critical(this, QStringLiteral("Export failed"),
                            QStringLiteral("Diagnostics could not be written to the selected file."));
    }
  });
  refreshFromController();
}

void DiagnosticsDialog::refreshFromController() {
  if (controller_ == nullptr || text_ == nullptr) return;
  const QVariantMap status = controller_->status();
  text_->setPlainText(controller_->diagnosticsText());
  if (acceptCurrent_ != nullptr) {
    acceptCurrent_->setEnabled(status.value(QStringLiteral("recoveryPending")).toBool()
                               && !status.value(QStringLiteral("recoveryUnreadable")).toBool());
  }
  if (discardRecovery_ != nullptr) {
    discardRecovery_->setEnabled(status.value(QStringLiteral("recoveryUnreadable")).toBool());
  }
  if (replaceSettings_ != nullptr) {
    replaceSettings_->setEnabled(status.value(QStringLiteral("settingsPersistenceBlocked")).toBool());
  }
}

} // namespace ember
