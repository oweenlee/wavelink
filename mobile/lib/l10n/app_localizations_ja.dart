// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for Japanese (`ja`).
class AppLocalizationsJa extends AppLocalizations {
  AppLocalizationsJa([String locale = 'ja']) : super(locale);

  @override
  String get appTitle => 'WaveLink';

  @override
  String get tabLibrary => 'ライブラリ';

  @override
  String get tabPlay => '再生中';

  @override
  String get tabSettings => '設定';

  @override
  String get titleLibrary => 'ライブラリ';

  @override
  String get titleSettings => '設定';

  @override
  String get navPlaying => '再生中';

  @override
  String get favMusic => 'お気に入りの曲';

  @override
  String songsCount(Object count) {
    return '$count 曲';
  }

  @override
  String get shufflePlay => 'シャッフル再生';

  @override
  String get play => '再生';

  @override
  String get playNext => '次を再生';

  @override
  String get addToQueue => 'キューに追加';

  @override
  String get addToPlaylist => 'プレイリストに追加';

  @override
  String get unfavorite => 'お気に入りから削除';

  @override
  String get favorite => 'お気に入り';

  @override
  String get noSongs => '曲がありません';

  @override
  String get noLyrics => '歌詞がありません';

  @override
  String get nowPlayingEmpty => '再生中の曲はありません';

  @override
  String get currentPlaying => '再生中';

  @override
  String get favorited => 'お気に入り登録済み';

  @override
  String get queue => 'キュー';

  @override
  String get queueTitle => '再生キュー';

  @override
  String get sound => 'サウンド';

  @override
  String get lyrics => '歌詞';

  @override
  String get queueEmpty => 'キューは空です';

  @override
  String get soundSettings => 'サウンド設定';

  @override
  String get eq10Band => 'イコライザー (10バンド PEQ)';

  @override
  String get enabled => '有効';

  @override
  String get disabled => '無効';

  @override
  String get bauerCrossfeed => 'Bauer クロスフィード';

  @override
  String get stereoWidening => 'ステレオ拡幅';

  @override
  String get truePeakLimiter => 'トゥルーピークリミッター';

  @override
  String get tpdfDither => 'TPDF ディザー';

  @override
  String get noiseShaping => 'ノイズシェーピング';

  @override
  String get roomCorrection => 'ルーム補正';

  @override
  String get roomCorrectionBitPerfectWarn =>
      'Bit-perfect が有効です：DSP はバイパスされるためルーム補正は適用されません';

  @override
  String get roomCorrectionHint => 'REW のスピーカー測定結果から補正フィルターを生成し、部屋の定在波を平坦化します';

  @override
  String get roomCorrectionOff => 'オフ';

  @override
  String get roomCorrectionActive => '適用中';

  @override
  String get roomCorrectionImport => 'REW の書き出しファイルを選択';

  @override
  String get roomCorrectionImportHint =>
      'REW の周波数特性書き出し（Freq/Level 列を含む .txt/.csv）';

  @override
  String get roomCorrectionPaste => 'REW のテキストを貼り付け';

  @override
  String roomCorrectionValidPoints(Object count) {
    return '有効な測定ポイント $count 個';
  }

  @override
  String get roomCorrectionFreqRange => '補正周波数範囲';

  @override
  String roomCorrectionFreqSpan(Object max, Object min) {
    return '範囲 ${min}Hz - ${max}Hz';
  }

  @override
  String get roomCorrectionTarget => 'ターゲットカーブ';

  @override
  String get roomCorrectionTargetFlat => 'フラット';

  @override
  String get roomCorrectionTargetHarman => 'Harman チルト';

  @override
  String get roomCorrectionTargetHint => '1kHz 以下で +1.3dB/oct、知覚される部屋のゲインを補正';

  @override
  String get roomCorrectionTaps => 'FIR 長';

  @override
  String get roomCorrectionTapsHint => '大きいほど低域の分解能が向上';

  @override
  String get roomCorrectionMaxCut => '最大カット (dB)';

  @override
  String get roomCorrectionNullLimit => 'ヌル補正の上限 (dB)';

  @override
  String get roomCorrectionNullLimitHint =>
      '部屋のヌルをブーストしても効果がなくリスクがあるため、既定上限は 3dB';

  @override
  String get roomCorrectionPsycho => '心理音響ウェイティング';

  @override
  String get roomCorrectionPsychoHint => '300Hz 以下はフル補正、高域に向けて徐々に減衰';

  @override
  String get roomCorrectionHeadroom => 'ヘッドルーム (dB)';

  @override
  String get roomCorrectionHeadroomHint => 'クリッピング防止のための IR ピーク正規化ヘッドルーム';

  @override
  String get roomCorrectionGenerate => '生成して適用';

  @override
  String get roomCorrectionGenerating => '生成中…';

  @override
  String get roomCorrectionClear => '補正をクリア';

  @override
  String get roomCorrectionResult => '補正を適用しました';

  @override
  String roomCorrectionGainHint(Object gain) {
    return '全体で ${gain}dB 減衰（音量を上げて補正してください）';
  }

  @override
  String roomCorrectionGainHintMerge(Object gain) {
    return '全体ゲイン ${gain}dB';
  }

  @override
  String roomCorrectionIrLength(Object taps) {
    return '$taps taps の FIR';
  }

  @override
  String roomCorrectionLoadError(Object error) {
    return '生成に失敗しました：$error';
  }

  @override
  String get roomCorrectionReadFileError => 'ファイルを読み取れません';

  @override
  String get roomCorrectionPreview => '測定された特性';

  @override
  String get roomCorrectionNoData => '先に REW の測定データを読み込んでください';

  @override
  String get autoEq => 'ヘッドホン補正 (AutoEQ)';

  @override
  String get autoEqOff => 'オフ';

  @override
  String get autoEqHint => 'oratory1990 の測定データでヘッドホンの周波数特性を補正';

  @override
  String get libSongs => '曲';

  @override
  String get libAlbums => 'アルバム';

  @override
  String get libArtists => 'アーティスト';

  @override
  String get libPlaylists => 'プレイリスト';

  @override
  String get noMusicHint => 'まだ音楽がインポートされていません\n上の「音楽をインポート」をタップして曲を追加してください';

  @override
  String importN(Object count) {
    return 'インポート ($count)';
  }

  @override
  String get importMusic => '音楽をインポート';

  @override
  String get import => 'インポート';

  @override
  String get noAlbumInfo => 'アルバム情報がありません';

  @override
  String get noArtistInfo => 'アーティスト情報がありません';

  @override
  String get newPlaylistFromQueue => '現在のキューから新しいプレイリストを作成';

  @override
  String get playlistNameHint => 'プレイリスト名';

  @override
  String get playlistNameExists => '同じ名前のプレイリストがすでに存在します';

  @override
  String get confirm => '確認';

  @override
  String get cancel => 'キャンセル';

  @override
  String get save => '保存';

  @override
  String get newPlaylist => '新しいプレイリスト';

  @override
  String get deleteFromLibrary => 'ライブラリから削除';

  @override
  String get deleteConfirmTitle => 'ライブラリから削除しますか？';

  @override
  String deleteConfirmBody(Object title) {
    return '「$title」がライブラリから削除されます。インポートしたコピーとダウンロード済みのキャッシュファイルも削除されます。';
  }

  @override
  String deletePlaylistBody(Object name) {
    return '「$name」がプレイリストから削除されます。曲自体には影響ありません。';
  }

  @override
  String get delete => '削除';

  @override
  String get noPlaylists => 'プレイリストがまだありません。ライブラリ > プレイリストで作成してください';

  @override
  String artistSongsAlbums(Object albums, Object songs) {
    return '$songs 曲 · $albums 枚のアルバム';
  }

  @override
  String get shuffleAll => 'すべてシャッフル再生';

  @override
  String albumArtistCount(Object artist, Object count) {
    return '$artist · $count 曲';
  }

  @override
  String get playAll => 'すべて再生';

  @override
  String get settingsAudio => 'オーディオ';

  @override
  String get dspPipeline => 'DSP パイプライン';

  @override
  String get dspCrossfeed => 'クロスフィード';

  @override
  String get replayGain => 'ReplayGain';

  @override
  String get bitPerfect => 'Bit-perfect（サンプルレート追従）';

  @override
  String get versionValue => 'v0.1.0';

  @override
  String get settingsAppearance => '外観';

  @override
  String get theme => 'テーマ';

  @override
  String get themeDark => 'ダーク';

  @override
  String get coverBlur => 'カバーぼかしの強さ';

  @override
  String get showSpectrum => 'スペクトラム表示';

  @override
  String get settingsLibrary => 'ライブラリ';

  @override
  String get scanDir => 'スキャン対象ディレクトリ';

  @override
  String get scanNoPermission => 'ミュージックライブラリへのアクセス許可が必要です';

  @override
  String get importSystemMusicHint => '端末のミュージックライブラリをスキャンして曲を取り込む';

  @override
  String get importPickerHint => '端末のストレージからオーディオファイルを選択';

  @override
  String get discoverSongs => '曲を探す';

  @override
  String get discoverSongsHint => '端末のミュージックライブラリをスキャン（メディアアクセスの許可が必要）';

  @override
  String get scanDone => 'スキャンが完了しました';

  @override
  String get scanSubsonic => 'ミュージックサーバー';

  @override
  String get importSubsonicHint => 'Navidrome / Jellyfin / Emby サーバーをスキャン';

  @override
  String get scanSmb => 'NAS SMB 共有';

  @override
  String get importSmbHint => 'SMB 共有を参照してファイルをインポート';

  @override
  String get nasSettings => 'NAS 設定';

  @override
  String get nasHost => 'NAS ホスト';

  @override
  String get nasShare => '共有パス';

  @override
  String get nasUsername => 'ユーザー名';

  @override
  String get nasPassword => 'パスワード';

  @override
  String get nasConnect => '接続';

  @override
  String get nasConnected => '接続済み';

  @override
  String get nasDisconnected => '未接続';

  @override
  String get nasTestConnection => '接続をテスト';

  @override
  String get nasSave => '保存';

  @override
  String get nasCancel => 'キャンセル';

  @override
  String get nasTitle => 'NAS (SMB)';

  @override
  String get nasEnable => 'NAS を有効化';

  @override
  String get nasEnterHost => 'ホストアドレスを入力してください';

  @override
  String get nasConnectionFailed => '接続に失敗しました';

  @override
  String get nasConnectionFailedTitle => 'NAS 接続に失敗しました';

  @override
  String get nasCheckHint => 'スマホと PC が同じ Wi-Fi に接続され、NAS アドレスが正しいことを確認してください。';

  @override
  String get nasCopy => 'コピー';

  @override
  String nasShares(Object shares) {
    return '共有：$shares';
  }

  @override
  String nasImportedSongs(Object count) {
    return 'NAS に接続 · $count 曲をインポートしました';
  }

  @override
  String get nasNoAudio => 'NAS に接続 · 新しいオーディオは見つかりませんでした';

  @override
  String get nasEmptyShare => 'NAS に接続 · 共有パスが空のため曲はインポートされませんでした';

  @override
  String get nasScanShare => '共有をスキャン';

  @override
  String get nasImport => 'NAS からインポート';

  @override
  String get smbOfflineCache => 'オフラインキャッシュ';

  @override
  String get smbOfflineCacheHint => 'NAS ライブラリ全体をこの端末にダウンロード';

  @override
  String get smbOfflineCacheTitle => 'オフラインキャッシュを有効にしますか？';

  @override
  String get smbOfflineCacheMessage =>
      'NAS のミュージックライブラリ全体がこの端末にダウンロードされ、大量のストレージを消費します。ダウンロードした曲は NAS が停止していても再生できます。オフにすると再生時のみストリーミングされます。';

  @override
  String get smbOfflineCacheConfirm => '有効にする';

  @override
  String get importExportPlaylist => 'プレイリストのインポート/エクスポート';

  @override
  String get settingsAbout => 'このアプリについて';

  @override
  String get version => 'バージョン';

  @override
  String get licenses => 'オープンソースライセンス';

  @override
  String get language => '言語';

  @override
  String get systemDefault => 'システムに従う';

  @override
  String get clear => 'クリア';

  @override
  String get noResults => '結果が見つかりません';

  @override
  String get searchLibrary => 'ライブラリを検索…';

  @override
  String get unknownArtist => '不明なアーティスト';

  @override
  String get importedMusic => 'インポートした音楽';

  @override
  String get prefsNotInit =>
      'PreferencesService が初期化されていません。最初に PreferencesService.init() を呼び出してください';

  @override
  String minuteFormat(Object m) {
    return '$m 分';
  }

  @override
  String get eqPresetFlat => 'フラット';

  @override
  String get eqPresetRock => 'ロック';

  @override
  String get eqPresetPop => 'ポップ';

  @override
  String get eqPresetDance => 'ダンス';

  @override
  String get eqPresetClassical => 'クラシック';

  @override
  String get eqPresetSoft => 'ソフト';

  @override
  String get eqPresetFullBass => '重低音';

  @override
  String get eqPresetFullTreble => '高音強調';

  @override
  String get eqPresetTechno => 'テクノ';

  @override
  String get eqPresetVocals => 'ボーカル';

  @override
  String get diagnosticTitle => '再生診断';

  @override
  String get diagnosticEntry => '診断とログ';

  @override
  String get audioDiagnostic => 'オーディオ診断';

  @override
  String get diagnosticTotalUnderrun => 'アンダーランの合計';

  @override
  String get diagnosticRecentUnderrun => '直近のアンダーラン';

  @override
  String get diagnosticHint =>
      'アンダーランが増え続ける場合は、バックグラウンドアプリを閉じるか出力デバイスを切り替えてください。';

  @override
  String get logSize => 'ログサイズ';

  @override
  String get logClearConfirm => 'この操作は取り消せません。ローカルログをすべて消去しますか？';

  @override
  String get pickFiles => 'ファイルを選択';

  @override
  String get pickFilesHint => '端末のストレージからオーディオファイル（FLAC、WAV、DSD、APE、CUE など）を選択';

  @override
  String get airDrop => 'AirDrop / 共有';

  @override
  String get airDropHint => '他のアプリから共有されたオーディオファイルを受信';

  @override
  String get webDav => 'WebDAV';

  @override
  String get webDavHint => 'WebDAV ネットワークストレージに接続';

  @override
  String get drawerSubtitle => '曲をライブラリに追加';

  @override
  String get sourcesSection => 'ソース';

  @override
  String get sourceAppleMusic => 'Apple Music';

  @override
  String get sourceAppleMusicHint => 'Apple Music ライブラリから同期';

  @override
  String get sourceDeviceLibrary => '端末のライブラリ';

  @override
  String get sourceDeviceLibraryHint => '端末のミュージックライブラリをスキャン';

  @override
  String get sourceFileImport => 'ファイルインポート';

  @override
  String get sourceFileImportHint => '端末のストレージからオーディオファイルを選択';

  @override
  String get sourceNas => 'NAS SMB';

  @override
  String get sourceNasHint => 'NAS 共有に接続';

  @override
  String get sourceNasConnected => '接続済み — タップして管理';

  @override
  String get sourceMusicServer => 'ミュージックサーバー';

  @override
  String get sourceMusicServerHint => 'Subsonic / Navidrome / Jellyfin を設定';

  @override
  String get sourceMusicServerReady => 'タップしてサーバーのライブラリをスキャン';

  @override
  String get sourceFound => '見つかった曲';

  @override
  String get sourceNotFound => '新しい曲は見つかりませんでした';

  @override
  String get subsonicTitle => 'ミュージックサーバー';

  @override
  String get subsonicUrl => 'サーバー URL';

  @override
  String get subsonicUsername => 'ユーザー名';

  @override
  String get subsonicPassword => 'パスワード';

  @override
  String get subsonicCompatible =>
      'Subsonic / Navidrome / Jellyfin / Emby に対応（OpenSubsonic API）';

  @override
  String get subsonicConnected => '接続済み';

  @override
  String get subsonicEnterUrl => 'サーバー URL とユーザー名を入力してください';

  @override
  String get subsonicFailed => '接続に失敗しました — URL / 認証情報を確認してください';

  @override
  String get webdavTitle => 'WebDAV';

  @override
  String get webdavUrl => 'サーバー URL';

  @override
  String get webdavPath => 'ディレクトリパス（任意）';

  @override
  String get webdavUsername => 'ユーザー名（任意）';

  @override
  String get webdavPassword => 'パスワード（任意）';

  @override
  String get webdavCompatible =>
      'Nextcloud / Seafile / Synology WebDAV / Aliyun Drive / rclone で動作';

  @override
  String get webdavEnterUrl => 'サーバー URL を入力してください';

  @override
  String get webdavInvalidUrl => 'http:// または https:// を含む完全な URL を入力してください';

  @override
  String get sourceWebdav => 'WebDAV';

  @override
  String get sourceWebdavHint => 'WebDAV ネットワークストレージに接続';

  @override
  String get sourceWebdavReady => 'タップしてサーバーのライブラリをスキャン';

  @override
  String get settingsMusicSources => '音楽ソース';

  @override
  String get supportedFormats =>
      'FLAC · WAV · AIFF · MP3 · AAC · OGG · OPUS · WAVPACK · DSF/DFF (DSD) · CUE · M3U/PLS';

  @override
  String get createPlaylistHint =>
      '空のプレイリストを作成します。曲メニュー →「プレイリストに追加」で曲を追加してください';
}
