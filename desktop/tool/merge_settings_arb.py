#!/usr/bin/env python3
"""一次性脚本：settings 页 l10n key 合并进 4 个 arb。用完即删。"""
import json, collections, sys

# (key, zh, en, ja, de, placeholders)
# placeholders: None 或 {name: type}
T = [
    # ── 分区框架 ──
    ("settingsSectionGeneral", "通用", "General", "一般", "Allgemein", None),
    ("settingsSectionGeneralSub", "语言与数据管理", "Language & data management", "言語とデータ管理", "Sprache & Datenverwaltung", None),
    ("settingsSectionAudio", "音频输出", "Audio Output", "オーディオ出力", "Audioausgabe", None),
    ("settingsSectionAudioSub", "设备选择与采样率", "Device & sample rate", "デバイスとサンプルレート", "Gerät & Abtastrate", None),
    ("settingsSectionDsp", "DSP 效果", "DSP Effects", "DSP エフェクト", "DSP-Effekte", None),
    ("settingsSectionDspSub", "实时音频处理链", "Realtime audio processing chain", "リアルタイム音声処理チェーン", "Echtzeit-Audiosignalverarbeitung", None),
    ("settingsSectionDiag", "诊断", "Diagnostics", "診断", "Diagnose", None),
    ("settingsSectionDiagSub", "引擎运行指标", "Engine runtime metrics", "エンジン実行指標", "Engine-Laufzeitmetriken", None),
    ("settingsBrandSubtitle", "设置 SETTINGS", "SETTINGS", "設定 SETTINGS", "EINSTELLUNGEN", None),
    ("settingsEngineReady", "引擎就绪", "Engine ready", "エンジン準備完了", "Engine bereit", None),
    ("settingsEngineNotReady", "引擎未加载", "Engine not loaded", "エンジン未読み込み", "Engine nicht geladen", None),
    ("settingsEngineNullBanner", "音频引擎未加载（缺少动态库），DSP / 设备设置不可用。",
     "Audio engine not loaded (missing dynamic library); DSP and device settings are unavailable.",
     "オーディオエンジンが未読み込みです（ダイナミックライブラリ不足）。DSP・デバイス設定は利用できません。",
     "Audio-Engine nicht geladen (dynamische Bibliothek fehlt); DSP- und Geräteeinstellungen sind nicht verfügbar.", None),
    # ── 通用：语言 ──
    ("settingsGroupLanguage", "界面语言", "Interface Language", "インターフェース言語", "Oberflächensprache", None),
    ("settingsGroupLanguageDesc", "选择应用界面的显示语言", "Choose the interface display language", "表示言語を選択", "Anzeigesprache der Oberfläche wählen", None),
    ("settingsDisplayLanguage", "显示语言", "Display language", "表示言語", "Anzeigesprache", None),
    ("settingsDisplayLanguageDesc", "更改后立即生效", "Takes effect immediately", "変更は即時反映", "Wird sofort wirksam", None),
    # ── 通用：数据 ──
    ("settingsGroupData", "数据管理", "Data management", "データ管理", "Datenverwaltung", None),
    ("settingsGroupDataDesc", "管理本地曲库与缓存数据", "Manage local library and cache data", "ローカルライブラリとキャッシュを管理", "Lokale Mediathek und Cache verwalten", None),
    ("settingsClearAll", "清空所有数据", "Clear all data", "すべてのデータを消去", "Alle Daten löschen", None),
    ("settingsClearAllDesc", "删除全部曲库、收藏与播放列表（不可恢复）", "Delete all tracks, favorites and playlists (irreversible)",
     "すべての曲・お気に入り・プレイリストを削除（元に戻せません）", "Alle Titel, Favoriten und Playlists löschen (unwiderruflich)", None),
    # ── 音频输出 ──
    ("settingsGroupOutputDevice", "输出设备", "Output device", "出力デバイス", "Ausgabegerät", None),
    ("settingsGroupOutputDeviceDesc", "选择音频输出设备与独占模式", "Choose audio output device and exclusive mode", "出力デバイスと排他モードを選択", "Ausgabegerät und Exklusivmodus wählen", None),
    ("settingsDevice", "设备", "Device", "デバイス", "Gerät", None),
    ("settingsSystemDefaultOutput", "系统默认输出", "System default output", "システム標準出力", "Systemstandard-Ausgabe", None),
    ("settingsSystemDefault", "系统默认", "System default", "システム標準", "Systemstandard", None),
    ("settingsCurrentStatus", "当前状态", "Current status", "現在の状態", "Aktueller Status", None),
    ("settingsMode", "模式", "Mode", "モード", "Modus", None),
    ("settingsModeExclusive", "独占", "Exclusive", "排他", "Exklusiv", None),
    ("settingsModeShared", "共享", "Shared", "共有", "Geteilt", None),
    ("settingsSampleRate", "采样率", "Sample rate", "サンプルレート", "Abtastrate", None),
    ("settingsExclusiveWasapi", "WASAPI 独占模式", "WASAPI exclusive mode", "WASAPI 排他モード", "WASAPI-Exklusivmodus", None),
    ("settingsExclusiveHog", "Hog Mode 独占模式", "Hog Mode exclusive mode", "Hog Mode 排他モード", "Hog-Mode-Exklusivmodus", None),
    ("settingsExclusiveDesc", "独占音频设备，切换将重启引擎", "Take exclusive control of the audio device; switching restarts the engine",
     "オーディオデバイスを排他制御します。切り替えでエンジンを再起動", "Exklusive Kontrolle des Audiogeräts; Wechsel startet die Engine neu", None),
    ("settingsExclusiveFailed", "独占模式切换失败：{err}", "Failed to switch exclusive mode: {err}", "排他モードの切り替えに失敗：{err}", "Wechsel des Exklusivmodus fehlgeschlagen: {err}", {"err": "String"}),
    ("settingsGroupSampleRateDesc", "设置输出采样率（下次播放生效）", "Set output sample rate (effective on next playback)", "出力サンプルレートを設定（次回再生から有効）", "Ausgabe-Abtastrate festlegen (wirksam bei nächster Wiedergabe)", None),
    ("settingsOutputSampleRate", "输出采样率 (Hz)", "Output sample rate (Hz)", "出力サンプルレート (Hz)", "Ausgabe-Abtastrate (Hz)", None),
    ("settingsSrHint", "常用值：44100（CD）、48000、96000、192000", "Common: 44100 (CD), 48000, 96000, 192000", "一般値：44100（CD）、48000、96000、192000", "Üblich: 44100 (CD), 48000, 96000, 192000", None),
    ("settingsApply", "应用", "Apply", "適用", "Übernehmen", None),
    # ── 高级 ──
    ("settingsGroupAdvanced", "高级", "Advanced", "詳細設定", "Erweitert", None),
    ("settingsGroupAdvancedDesc", "Bit-Perfect、自动采样率与无缝切换", "Bit-perfect, auto sample rate and gapless switching", "Bit-Perfect、自動サンプルレート、シームレス切替", "Bit-perfect, automatische Abtastrate und übergangsloser Wechsel", None),
    ("settingsBitPerfect", "Bit-Perfect 直通", "Bit-perfect passthrough", "Bit-Perfect パススルー", "Bit-perfect-Durchleitung", None),
    ("settingsBitPerfectDesc", "绕过采样率转换与 DSP，原始信号直出；切换将重启引擎", "Bypass sample-rate conversion and DSP; switching restarts the engine",
     "サンプルレート変換とDSPをバイパスし、元信号をそのまま出力。切り替えでエンジンを再起動", "Umgeht Abtastratenwandlung und DSP; Wechsel startet die Engine neu", None),
    ("settingsBitPerfectFailed", "Bit-Perfect 切换失败：{err}", "Failed to switch bit-perfect: {err}", "Bit-Perfect の切り替えに失敗：{err}", "Wechsel zu Bit-perfect fehlgeschlagen: {err}", {"err": "String"}),
    ("settingsAutoSr", "自动采样率", "Auto sample rate", "自動サンプルレート", "Automatische Abtastrate", None),
    ("settingsAutoSrDesc", "按源文件采样率自动切换输出；切换将重启引擎", "Switch output to match the source file's sample rate; switching restarts the engine",
     "ソースファイルのサンプルレートに合わせて出力を切替。切り替えでエンジンを再起動", "Ausgabe an Abtastrate der Quelldatei anpassen; Wechsel startet die Engine neu", None),
    ("settingsAutoSrFailed", "自动采样率切换失败：{err}", "Failed to switch auto sample rate: {err}", "自動サンプルレートの切り替えに失敗：{err}", "Wechsel der automatischen Abtastrate fehlgeschlagen: {err}", {"err": "String"}),
    ("settingsCrossfade", "曲间无缝 Crossfade", "Gapless crossfade", "曲間シームレス Crossfade", "Übergangsloser Crossfade", None),
    ("settingsCrossfadeDesc", "下一首启动生效", "Effective from the next track", "次の曲から有効", "Wirkt ab dem nächsten Titel", None),
    ("settingsOff", "关闭", "Off", "オフ", "Aus", None),
    # ── DSP：空间效果 ──
    ("settingsGroupSpatial", "空间效果", "Spatial effects", "空間効果", "Räumliche Effekte", None),
    ("settingsGroupSpatialDesc", "立体声展宽与跨馈处理", "Stereo widening and crossfeed", "ステレオ幅拡張とクロスフィード", "Stereoverbreiterung und Crossfeed", None),
    ("settingsStereoWiden", "立体声展宽", "Stereo widening", "ステレオ幅拡張", "Stereoverbreiterung", None),
    ("settingsStereoWidenDesc", "扩展立体声声场宽度", "Widen the stereo soundstage", "ステレオの音場を拡張", "Stereoklangbild verbreitern", None),
    ("settingsWidenWidth", "展宽宽度", "Widening amount", "拡張幅", "Verbreiterung", None),
    ("settingsCrossfeed", "跨馈 (Crossfeed)", "Crossfeed", "クロスフィード (Crossfeed)", "Crossfeed", None),
    ("settingsCrossfeedDesc", "耳机听感模拟音箱串扰，减少疲劳", "Simulate speaker crosstalk for headphones to reduce fatigue",
     "ヘッドホンでスピーカーのクロストークを模擬し、疲労を軽減", "Lautsprecher-Übersprechen für Kopfhörer simulieren, ermüdungsarm", None),
    # ── DSP：动态处理 ──
    ("settingsGroupDynamics", "动态处理", "Dynamic processing", "ダイナミック処理", "Dynamikverarbeitung", None),
    ("settingsGroupDynamicsDesc", "限幅、抖动与噪声整形", "Limiter, dither and noise shaping", "リミッター、ディザー、ノイズシェイピング", "Limiter, Dither und Noise Shaping", None),
    ("settingsLimiter", "真峰值限幅 (Limiter)", "True-peak limiter", "真ピークリミッター (Limiter)", "True-Peak-Limiter", None),
    ("settingsLimiterDesc", "防止削波失真", "Prevent clipping distortion", "クリッピング歪みを防止", "Verzerrung durch Clipping verhindern", None),
    ("settingsDither", "抖动 (Dither)", "Dither", "ディザー (Dither)", "Dither", None),
    ("settingsDitherDesc", "低位深输出时降低量化噪声", "Reduce quantization noise at low bit depth", "低ビット深度出力時に量子化ノイズを低減", "Quantisierungsrauschen bei geringer Bittiefe reduzieren", None),
    ("settingsNoiseShaping", "噪声整形 (Noise Shaping)", "Noise shaping", "ノイズシェイピング (Noise Shaping)", "Noise Shaping", None),
    ("settingsNoiseShapingDesc", "将量化噪声推向高频不可闻区", "Push quantization noise into inaudible high frequencies", "量子化ノイズを可聴域外の高域へ移動", "Quantisierungsrauschen in unhörbare Höhen verschieben", None),
    # ── DSP：增益与速度 ──
    ("settingsGroupGainSpeed", "增益与速度", "Gain & speed", "ゲインと速度", "Pegel & Geschwindigkeit", None),
    ("settingsGroupGainSpeedDesc", "ReplayGain 增益补偿与播放速度", "ReplayGain compensation and playback speed", "ReplayGain ゲイン補正と再生速度", "ReplayGain-Kompensation und Wiedergabegeschwindigkeit", None),
    ("settingsReplayGain", "ReplayGain 增益", "ReplayGain gain", "ReplayGain ゲイン", "ReplayGain-Pegel", None),
    ("settingsReplayGainDesc", "音量标准化补偿", "Volume normalization compensation", "音量正規化の補正", "Lautstärke-Normalisierung", None),
    ("settingsPlaybackSpeed", "播放速度", "Playback speed", "再生速度", "Wiedergabegeschwindigkeit", None),
    ("settingsPlaybackSpeedDesc", "变速播放（不改音高）", "Time-stretch playback (pitch preserved)", "ピッチを保ったまま速度変更", "Tempo ändern (Tonhöhe bleibt)", None),
    # ── EQ ──
    ("settingsGroupEq", "均衡器", "Equalizer", "イコライザー", "Equalizer", None),
    ("settingsGroupEqDesc", "EQ 预设与 AutoEQ 耳机校正", "EQ presets and AutoEQ headphone correction", "EQ プリセットと AutoEQ 補正", "EQ-Voreinstellungen und AutoEQ-Korrektur", None),
    ("settingsEqPreset", "EQ 预设", "EQ preset", "EQ プリセット", "EQ-Voreinstellung", None),
    ("settingsEqPresetDesc", "选择预设均衡器曲线", "Choose a preset EQ curve", "プリセット EQ カーブを選択", "Voreingestellte EQ-Kurve wählen", None),
    ("settingsAutoEqModel", "AutoEQ 耳机型号", "AutoEQ headphone model", "AutoEQ ヘッドホン型番", "AutoEQ-Kopfhörermodell", None),
    ("settingsAutoEqDisabled", "未启用 AutoEQ 校正", "AutoEQ correction off", "AutoEQ 補正は無効", "AutoEQ-Korrektur aus", None),
    ("settingsPick", "选择", "Select", "選択", "Auswählen", None),
    ("settingsAutoEqOff", "关闭 AutoEQ", "Turn off AutoEQ", "AutoEQ をオフ", "AutoEQ aus", None),
    ("settingsAutoEqApplied", "已应用 AutoEQ：{model}", "Applied AutoEQ: {model}", "AutoEQ を適用：{model}", "AutoEQ angewendet: {model}", {"model": "String"}),
    # ── 房间校正 ──
    ("settingsGroupRoom", "房间校正", "Room correction", "ルーム補正", "Raumkorrektur", None),
    ("settingsGroupRoomDesc", "载入 FIR 脉冲响应或从 REW 测量生成", "Load a FIR impulse response or generate one from REW measurements", "FIR インパルス応答をロード、または REW 測定から生成", "FIR-Impulsantwort laden oder aus REW-Messung erzeugen", None),
    ("settingsFirIr", "FIR 脉冲响应 (.wav)", "FIR impulse response (.wav)", "FIR インパルス応答 (.wav)", "FIR-Impulsantwort (.wav)", None),
    ("settingsNotLoaded", "未载入", "Not loaded", "未ロード", "Nicht geladen", None),
    ("settingsLoad", "载入", "Load", "ロード", "Laden", None),
    ("settingsClear", "清除", "Clear", "クリア", "Löschen", None),
    ("settingsRewGenerate", "从 REW 生成校正 IR", "Generate correction IR from REW", "REW から補正 IR を生成", "Korrektur-IR aus REW erzeugen", None),
    ("settingsRewGenerateDesc", "导入 REW 频响测量文本 (.txt) 自动生成", "Import a REW frequency-response measurement (.txt) to generate automatically", "REW 周波数応答テキスト (.txt) を読み込んで自動生成", "REW-Frequenzgangmessung (.txt) importieren und automatisch erzeugen", None),
    ("settingsGenerate", "生成", "Generate", "生成", "Erzeugen", None),
    ("settingsRewFile", "REW 测量", "REW measurement", "REW 測定", "REW-Messung", None),
    ("settingsRewNoPoints", "REW 文件解析失败：无有效测量点", "Failed to parse REW file: no valid measurement points", "REW ファイル解析失敗：有効な測定点なし", "REW-Datei konnte nicht gelesen werden: keine gültigen Messpunkte", None),
    ("settingsRewGenerated", "已生成校正 IR（{points} 点测量，{gain} dB）", "Correction IR generated ({points} points, {gain} dB)", "補正 IR を生成（{points} 点、{gain} dB）", "Korrektur-IR erzeugt ({points} Punkte, {gain} dB)", {"points": "int", "gain": "String"}),
    ("settingsGenerateFailed", "生成失败：{e}", "Generation failed: {e}", "生成に失敗：{e}", "Erzeugung fehlgeschlagen: {e}", {"e": "String"}),
    # ── 诊断 ──
    ("settingsEngineStatus", "引擎状态", "Engine status", "エンジン状態", "Engine-Status", None),
    ("settingsReady", "就绪", "Ready", "準備完了", "Bereit", None),
    ("settingsNotLoaded", "未加载", "Not loaded", "未読み込み", "Nicht geladen", None),
    ("settingsGroupRuntime", "运行详情", "Runtime details", "実行詳細", "Laufzeitdetails", None),
    ("settingsGroupRuntimeDesc", "当前播放路径与最后错误信息", "Current playback path and last error", "現在の再生パスと最後のエラー", "Aktueller Wiedergabepfad und letzter Fehler", None),
    ("settingsCurrentTrack", "当前曲目", "Current track", "現在の曲", "Aktueller Titel", None),
    ("settingsLastError", "最后错误", "Last error", "最後のエラー", "Letzter Fehler", None),
    ("settingsNone", "无", "None", "なし", "Keine", None),
    ("settingsAutoRefresh", "自动刷新", "Auto refresh", "自動更新", "Automatische Aktualisierung", None),
    ("settingsAutoRefreshDesc", "每 2 秒自动更新诊断数据", "Diagnostic data updates every 2 seconds", "診断データを 2 秒ごとに更新", "Diagnosedaten werden alle 2 Sekunden aktualisiert", None),
    ("settingsRefreshNow", "立即刷新", "Refresh now", "今すぐ更新", "Jetzt aktualisieren", None),
    # ── EQ 预设名（借 mobile）──
    ("eqPresetFlat", "平坦", "Flat", "フラット", "Flach", None),
    ("eqPresetRock", "摇滚", "Rock", "ロック", "Rock", None),
    ("eqPresetPop", "流行", "Pop", "ポップ", "Pop", None),
    ("eqPresetDance", "舞曲", "Dance", "ダンス", "Dance", None),
    ("eqPresetClassical", "古典", "Classical", "クラシック", "Klassik", None),
    ("eqPresetSoft", "柔和", "Soft", "ソフト", "Sanft", None),
    ("eqPresetFullBass", "重低音", "Full Bass", "重低音", "Voller Bass", None),
    ("eqPresetFullTreble", "重高音", "Full Treble", "高音強調", "Volle Höhen", None),
    ("eqPresetTechno", "电子", "Techno", "テクノ", "Techno", None),
    ("eqPresetVocals", "人声", "Vocals", "ボーカル", "Gesang", None),
]

# ja/de 欠的 14 个 artist/album key（en/zh 已有）
MISSING = [
    ("sidebarArtists", "艺术家", "Artists", "アーティスト", "Künstler"),
    ("sidebarAlbums", "专辑", "Albums", "アルバム", "Alben"),
    ("viewArtists", "艺术家", "Artists", "アーティスト", "Künstler"),
    ("viewAlbums", "专辑", "Albums", "アルバム", "Alben"),
    ("artistUnknown", "未知艺术家", "Unknown artist", "不明なアーティスト", "Unbekannter Künstler"),
    ("albumUnknown", "未知专辑", "Unknown album", "不明なアルバム", "Unbekanntes Album"),
    ("sortByName", "按名称", "By name", "名前順", "Nach Name"),
    ("sortByCount", "按数量", "By count", "数量順", "Nach Anzahl"),
    ("allTracks", "全部曲目", "All tracks", "すべての曲", "Alle Titel"),
    ("noArtists", "没有匹配的艺术家", "No matching artists", "一致するアーティストなし", "Keine passenden Künstler"),
    ("noAlbums", "没有匹配的专辑", "No matching albums", "一致するアルバムなし", "Keine passenden Alben"),
    ("playAlbum", "播放专辑", "Play album", "アルバムを再生", "Album abspielen"),
    ("artistCount", "{count} 位艺术家", "{count} artists", "アーティスト {count} 組", "{count} Künstler"),
    ("albumCount", "{count} 张专辑", "{count} albums", "アルバム {count} 枚", "{count} Alben"),
]

LOCS = {"zh": 1, "en": 2, "ja": 3, "de": 4}

for loc, col in LOCS.items():
    path = f"lib/l10n/app_{loc}.arb"
    data = json.load(open(path), object_pairs_hook=collections.OrderedDict)
    added = 0
    for row in T + MISSING:
        key = row[0]
        if key in data and not (loc in ("ja", "de") and key in {r[0] for r in MISSING}):
            if loc == "zh" and key not in data:
                pass
            else:
                continue
        if key in data:
            continue
        data[key] = row[col]
        if loc == "zh" and row[5]:
            ph = collections.OrderedDict()
            for name, typ in row[5].items():
                ph[name] = collections.OrderedDict([("type", typ)])
            data["@" + key] = collections.OrderedDict([("placeholders", ph)])
        added += 1
    with open(path, "w") as f:
        json.dump(data, f, ensure_ascii=False, indent=2)
        f.write("\n")
    print(loc, "added", added, "-> total keys:", sum(1 for k in data if not k.startswith("@")))
