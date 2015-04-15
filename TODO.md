[x] Main
    [x] Console
    [x] PeerManager
    [ ] TorrentManager
        [ ] Tracker
        [ ] FileAgent
        [ ] PieceManager
    [-] Listen
    [-] ChokeManager


Peer
    - исключения никуда не пишутся

PieceManager
    - нет логики про заверение скачивания и переход в режим сидирования
    - сообщение про переход в режим endgame не доходит до пиров
