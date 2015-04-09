[x] Main
    [x] Console
    [x] PeerManager
    [x] TorrentManager
        [x] Tracker
        [x] FileAgent
        [x] PieceManager
    [-] ChokeManager
    [-] Listen


Tracker
    - нет сообщения про новых пиров с трекера для PeerManager

PeerManager
    - подключение пира не реализовано

PieceManager
    - нет логики про заверение скачивания и переход в режим сидирования
    - сообщение про переход в режим endgame не доходит до пиров
