#include "WhisperWallPlugin.h"
#include "WhisperWallBackend.h"

#include <QQmlContext>
#include <QQmlEngine>
#include <QQuickWidget>
#include <QUrl>
#include <cstdlib>

WhisperWallPlugin::WhisperWallPlugin(QObject* parent) : QObject(parent) {}
WhisperWallPlugin::~WhisperWallPlugin() = default;

void WhisperWallPlugin::initLogos(LogosAPI* api) {
    m_api = api;
}

QWidget* WhisperWallPlugin::createWidget(LogosAPI* api) {
    if (api) m_api = api;

    if (!m_backend)
        m_backend = new WhisperWallBackend(m_api, this);

    auto* view = new QQuickWidget();
    view->engine()->rootContext()->setContextProperty("backend", m_backend);
    view->setResizeMode(QQuickWidget::SizeRootObjectToView);

    // Prefer a file-system QML path for development (set QML_PATH=.../ui/qml).
    const char* qmlPath = std::getenv("QML_PATH");
    if (qmlPath) {
        view->setSource(QUrl::fromLocalFile(
            QString::fromUtf8(qmlPath) + "/Main.qml"));
    } else {
        view->setSource(QUrl("qrc:/qml/Main.qml"));
    }

    return view;
}

void WhisperWallPlugin::destroyWidget(QWidget* widget) {
    delete m_backend;
    m_backend = nullptr;
    delete widget;
}
