[ ] Main
    [ ] Console
    [ ] PeerManager
        [ ] Peer
            [ ] PeerSender
            [ ] PeerHandler
            [ ] PeerReceiver
            [ ] PeerSenderQueue
    [ ] TorrentManager
        [ ] Tracker
        [ ] FileAgent
        [ ] PieceManager
    [ ] Listen
    [ ] ChokeManager


Peer
    - хранить "их" `peer id` и `capabilities`
Peer.Handler
    - endgame
        - отмена блоков, скачанных другими пирами
    - при отключении пира, он не посылает сообщение PeerUnhave, PeerPutBackBlock

Console
    - использовать haskeline

TorrentManager
    - торрент стартует сразу, нужна опция
    - файл создается в текущей папке, нужна опция
    - для трекера передается дефолтный порт, нужна опция
    - не обрабатываются события: pieceComplete, torrentComplete

Tracker
    - поменять обработку таймера

PieceManager
    - нет логики про заверение скачивания и переход в режим сидирования
