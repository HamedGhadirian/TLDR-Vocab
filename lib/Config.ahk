;================================================================================
; Config.ahk - what is set in the script rather than in Settings
;================================================================================
; The name, the version, the keys, the settings window's own rows and the
; first Vocab.ini - everything the kit is handed in Vocab.ahk (Kit.Start) -
; and the rest that is set here in the code: the icon, the colours, the sizes.
;================================================================================
#Requires AutoHotkey v2.0

; The name it shows, and the version - for the tray tip, the settings window,
; the notices and the update check. The files keep the short name Vocab.
global AppName := "TLDR Vocab"
global RepoUrl := "https://github.com/HamedGhadirian/TLDR-Vocab"     ; the README and the releases
global VocabVersion := "1.4.0"   ; MAJOR.MINOR.PATCH - a dash makes it a test version

;--------------------------------------------------------------------------------
; The keys - the defaults. Every one can be changed in Settings > KEYS (the
; kit's Keys.ahk), which keeps the changed ones in Vocab.ini under [Keys].
; The default clicks swallow the click only while Win is held, so an ordinary
; click is never touched. Windows Terminal can claim Win+` for its drop-down
; window; whichever of the two sees the key first wins.
; id is the line's name in Vocab.ini [Keys]; short is for the tray tip.
;--------------------------------------------------------------------------------
VocabKeys() => [
    {id: "Word",      name: "Look up a word",          short: "word",      def: "#LButton",  fn: LookupUnderMouse},
    {id: "Translate", name: "Translate a passage",     short: "translate", def: "+#LButton", fn: LookupSentenceUnderMouse},
    {id: "Summary",   name: "Summarise a block",       short: "summary",   def: "^#LButton", fn: LookupParagraphUnderMouse},
    {id: "Selection", name: "Look up selected text",   short: "selection", def: "#vkC0",     fn: LookupSelection},
    {id: "Box",       name: "Draw a box to read",      short: "box",       def: "+#vkC0",    fn: LookupBox},
    {id: "Check",     name: "Check my English",        short: "check",     def: "^#vkC0",    fn: CheckSelection},
    {id: "WordList",  name: "Open the word list",      short: "words",     def: "#F7",       fn: (*) => Dict.Toggle()}
]

;--------------------------------------------------------------------------------
; The settings window's own parts, below the kit's GENERAL and KEYS (the
; kit's SettingsWin.ahk). Every one is kept in Vocab.ini and works the moment
; it changes: the key, the model and the proxy are read on every request, the
; language and the passage on every lookup, the sound by VocabApply (App.ahk).
;--------------------------------------------------------------------------------
VocabRows() {
    codes := [], names := []
    for l in Lang.List
        codes.Push(l.code), names.Push(l.name)
    return [{kind: "head", label: "TRANSLATION"}
        , {kind: "list", sect: "Translation", key: "Language", def: "fa", label: "Into"
            , choices: codes, names: names
            , hint: "What you read is always English. Words you saved keep the language they were saved in."
            , after: (v) => (Lang.Set(v), Dict.Refresh())}        ; the word list's column turns to match
        , {kind: "list", sect: "Translation", key: "Sentences", def: "10", label: "Passage"
            , choices: ["10", "1"], names: ["up to ten sentences", "only the one sentence"]
            , hint: "What Translate takes: the sentences around the one you click, or just that one, "
                . "up to its first stop."}
        , {kind: "head", label: "GEMINI"}
        , {kind: "note", label: "Explains sentences in plain English, writes the summaries, and picks the "
            . "meaning of a word that fits where you found it. Without a key, the dictionary, the "
            . "translation and the pronunciation all still work."}
        , {kind: "custom", add: (c, y) => GeminiRow.Add(c, y), sync: () => GeminiRow.Sync()}
        , {kind: "text", sect: "Gemini", key: "Model", def: "", label: "Model"
            , cue: "automatic - newest free Flash, the next when its quota runs out"}
        ; WinHTTP, which every request goes through, speaks to HTTP proxies
        ; only: a VPN app's HTTP port works, its SOCKS port does not
        , {kind: "head", label: "NETWORK"}
        , {kind: "text", sect: "Network", key: "Proxy", def: "auto", label: "Proxy", cue: "auto"
            , hint: "auto follows Windows (a VPN app's " Chr(0x201C) "system proxy" Chr(0x201D) "), none goes "
                . "direct, or an HTTP proxy like 127.0.0.1:10809. SOCKS proxies do not work."}
        , {kind: "head", label: "SOUND"}
        , {kind: "bool", sect: "Sound", key: "SayOnLookup", def: 0, label: "Say each word out loud as it is looked up"}]
}

;--------------------------------------------------------------------------------
; Vocab.ini as a new download starts it, written once when there is none.
; Plain ASCII, like every template (the kit's Ini.ahk says why).
;--------------------------------------------------------------------------------
VocabIniTemplate() {
    return "
    (
; TLDR Vocab's settings. Easiest from the tray menu: Settings - everything
; in this file is there.

[Gemini]
; Optional, free: Gemini explains sentences in plain English, writes the
; summaries, and picks the meaning of a word that fits the sentence. Without
; it the dictionary, the translation and the pronunciation all still work.
; Get a key at https://aistudio.google.com/apikey (sign in with Google,
; Create API key) and paste it after the = , or in Settings.
ApiKey=
; Leave empty to use the newest free Flash model automatically.
Model=

[Network]
; auto = follow the Windows proxy when one is switched on (a VPN app in
; "system proxy" mode, for example). Or name one: 127.0.0.1:10809
; none = always connect directly.
Proxy=auto

[Sound]
; 1 = say each word out loud as it is looked up
SayOnLookup=0

[Translation]
; the language translations go into: fa, ar, tr, es, de, ... (Settings has the list)
Language=fa
; what Translate takes: 10 = up to ten sentences, 1 = only the one clicked
Sentences=10

    )" "`n" Kit.IniGeneral("so the selection key can copy from programs that run as administrator")
}

;--------------------------------------------------------------------------------
; The rest, set here
;--------------------------------------------------------------------------------
; Icon for the tray AND the dictionary window's taskbar button. Leave it ""
; for AutoHotkey's own. This is the default: Vocab.ini's [Icons] Tray line
; names another without touching the code (blank there = this one).
;
; A plain file name means a file next to Vocab.ahk - the way to do it, so the
; icon travels with the folder. A full path only exists on the PC it was typed
; on (docs\decisions.md).
;     global IconFile := "dictionary.png"          next to Vocab.ahk
;     global IconFile := "C:\Windows\System32\imageres.dll"
;     global IconNum  := 100                        a Windows icon, by number
; A missing or unusable file is noted in errors.log - the script runs anyway.
global IconFile := "dictionary.png"
global IconNum  := 1

; The colours of every window and card: the kit's palette (Theme.ahk), dark or
; light as Settings > GENERAL says. Dark until VocabColours copies them in at
; start, and again when the theme changes.
global CBg := "181B24", CCard := "202430", CCardHi := "2A3040", CTrack := "2A2F40"
global CText := "EBEEF5", CMuted := "8C94AA", CDim := "5F677D"
global CGreen := "00E676", CAmber := "FFB300", CRed := "FF4D6D", CBlue := "3D9BE9"
global FontUI := "Segoe UI"
global FontFa := "Segoe UI"     ; has full Persian coverage; "Tahoma" also works

VocabColours() {
    global CBg := Theme.Bg, CCard := Theme.Card, CCardHi := Theme.CardHi, CTrack := Theme.Track
    global CText := Theme.Text, CMuted := Theme.Muted, CDim := Theme.Dim
    global CGreen := Theme.Green, CAmber := Theme.Amber, CRed := Theme.Red, CBlue := Theme.Blue
}

; the thin border round the popup and the word list: CTrack, in the
; blue-green-red order Windows wants it
BorderColour() {
    c := Integer("0x" CTrack)
    return ((c & 0xFF) << 16) | (c & 0xFF00) | ((c >> 16) & 0xFF)
}

; Hearing the word: the speaker on every card, and - when Settings > SOUND says
; so (kept in Vocab.ini) - each word said out loud as it is looked up. A
; recording from Google's free endpoint, kept in cache\audio-us afterwards, or
; the Windows voice offline - see the top of Speak.ahk. This is the default.
global SpeakAuto := 0           ; 1 = say every word as you look it up

global PopW    := 400           ; popup width
global PopWide := 520           ; and for a paragraph summary, which is wider
global PopMaxH := 560           ; the tallest the popup gets before it scrolls
