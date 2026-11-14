;================================================================================
; App.ahk - starting up, the tray items, the icon, and starting a lookup
;================================================================================
; Vocab.ahk hands these to the kit (Kit.Start): VocabStart runs once the
; settings file is there and administrator is settled, before the keys are
; switched on; VocabApply after a setting changed; VocabTheme after the
; theme did; VocabTray adds Vocab's own items to the top of the tray menu.
;================================================================================
#Requires AutoHotkey v2.0

VocabStart() {
    VocabColours()
    TrimLog()
    LoadSoundSettings()
    Store.Load()
    SetTimer(() => PronFill.Start(), -5000)
    SetTimer(() => AiTrack.Warm(), -3000)   ; Gemini's model list, before the first lookup needs it
    OnMessage(0x83, DictNcCalc)             ; WM_NCCALCSIZE
    OnMessage(0x84, DictHitTest)            ; WM_NCHITTEST
    OnMessage(0x86, DictNcActivate)         ; WM_NCACTIVATE
    OnMessage(0x201, DictMouseDown)         ; WM_LBUTTONDOWN - the divider
    OnMessage(0x201, ObjBindMethod(PopupCard, "DragPinned"))   ; - and moving a pinned popup
    OnMessage(0x20A, PaneWheel)             ; WM_MOUSEWHEEL
    OnMessage(0x20, OnSetCursor)            ; WM_SETCURSOR
    OnMessage(0x232, DictMoved)             ; WM_EXITSIZEMOVE
    OnExit((*) => Dict.SavePos())
    NoKeyNotice()
}

; a setting changed in the settings window: what is not read afresh anyway
VocabApply() {
    LoadSoundSettings()
}

; dark or light: the colours, then the windows that are up drawn again
VocabTheme() {
    VocabColours()
    Dict.Retheme()
    PopupCard.Retheme()
}

VocabTray(m) {
    m.Add("Open dictionary", (*) => Dict.Toggle())
    m.Add("Open the " AppName " folder", (*) => Run('explorer.exe "' A_ScriptDir '"'))
}

; The icon as a full path: the .ini's [Icons] Tray line (the kit's - blank
; means IconFile next to this script), else IconFile itself: a bare name, or
; anything not starting at a drive letter or a network share, sits next to
; this script.
IconPath() {
    if ((p := KitIcons.Path()) != "")
        return p
    if (IconFile = "")
        return ""
    return RegExMatch(IconFile, "^([A-Za-z]:|\\\\)") ? IconFile : A_ScriptDir "\" IconFile
}

; A window's taskbar button: Vocab's own (the kit's KitTaskbar, with the app
; id Vocab.ahk names, so a pinned button keeps working), with its icon - which
; the taskbar takes from the window, not from the tray. Only real icons
; (image type 1) are handed over. Before the window's first Show, which is
; when the button is made.
SetWindowIcon(hwnd) {
    KitTaskbar.Id(hwnd)
    path := IconPath()
    if (path = "" || !FileExist(path))
        return
    try {
        small := LoadPicture(path, "Icon" IconNum " w16 h16", &t1)
        big   := LoadPicture(path, "Icon" IconNum " w32 h32", &t2)
        if (t1 = 1)
            SendMessage(0x80, 0, small, , hwnd)         ; WM_SETICON, ICON_SMALL
        if (t2 = 1)
            SendMessage(0x80, 1, big, , hwnd)           ; ICON_BIG
    }
}

; A view is Popup or Dict: Begin() draws the word at once, Update() redraws as
; each track answers. ocr says the word was read off the screen rather than
; typed or copied, which is the only case where Gemini is allowed to overrule
; it - see Popup.Update().
; reuse = the Translate | Summary switch: a finished lookup of the same text in
; that mode is shown again instead of asked for again (see ModeMemo).
; again = "look up again" pressed by hand: resting models are asked too.
StartLookup(word, context, view, anchor := "", ocr := false, mode := "word", reuse := false, again := false) {
    if (SpeakAuto && mode = "word" && StrLen(word) <= 40)
        Speak.Say(word)
    view.Begin(word, context, anchor, ocr, mode)
    lk := reuse ? ModeMemo.Get(word, mode) : ""
    if (lk && lk.Done) {
        view.Attach(lk)
        view.Update(lk)
        return
    }
    lk := Lookup(word, context, ObjBindMethod(view, "Update"), mode, again)
    if (mode != "word")
        ModeMemo.Put(lk)
    view.Attach(lk)
}

; A correction is only taken if it looks like a word and is not what we already
; have - Gemini echoing the word back, or answering with a sentence, changes
; nothing.
UsableFix(fix, word) {
    fix := Trim(fix)
    return (fix != "" && Lookup.Norm(fix) != Lookup.Norm(word)
        && RegExMatch(fix, "^[A-Za-z][A-Za-z'\- ]{1,40}$") && StrSplit(fix, " ").Length <= 3)
}
