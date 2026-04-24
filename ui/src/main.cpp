// Standalone test harness — loads WhisperWallPlugin directly without Basecamp.
// Usage:
//   QML_PATH=ui/qml ./whisper_wall_app
//   NSSA_WALLET_HOME_DIR=/tmp/ww-wallet NSSA_SEQUENCER_URL=http://127.0.0.1:3040 \
//   WHISPER_WALL_PROGRAM_ID_HEX=<64-hex> QML_PATH=ui/qml ./whisper_wall_app

#include "WhisperWallPlugin.h"

#include <QApplication>
#include <QMainWindow>

int main(int argc, char* argv[]) {
    QApplication app(argc, argv);
    app.setApplicationName("WhisperWall");
    app.setApplicationVersion("0.1.0");

    WhisperWallPlugin plugin;

    QMainWindow window;
    window.setWindowTitle("WhisperWall — Basecamp module preview");
    window.resize(480, 640);

    QWidget* view = plugin.createWidget(nullptr);
    window.setCentralWidget(view);
    window.show();

    return app.exec();
}
