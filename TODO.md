[x] Main
    [x] Console
    [ ] PeerManager
        [ ] Peer
            [ ] PeerSender
            [ ] PeerHandler
            [ ] PeerReceiver
            [ ] PeerSenderQueue
    [x] TorrentManager
        [ ] Tracker
        [ ] FileAgent
        [ ] PieceManager
    [-] Listen
    [-] ChokeManager


Peer
    - исключения никуда не пишутся
    - при отключении пира, он не посылает сообщение PeerUnhave, PeerPutBackBlock
    - не ведется учет скачанных и отданных байт
    - не проверяется handshake

Console
    - использовать haskeline

TorrentManager
    - торрент стартует сразу, нужна опция
    - файл создается в текущей папке, нужна опция
    - для трекера передается дефолтный порт, нужна опция
    - в state хранится chan'ы от FileAgent и PieceManager. Желательно это скрыть от state
    - не обрабатываются события: pieceComplete, torrentComplete

Tracker
    - поменять обработку таймера

PieceManager
    - нет логики про заверение скачивания и переход в режим сидирования
    - сообщение про переход в режим endgame не доходит до пиров
