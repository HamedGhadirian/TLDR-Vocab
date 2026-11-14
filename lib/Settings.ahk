;================================================================================
; Settings.ahk - Vocab's own part of the settings window: the Gemini key
;================================================================================
; The window is the kit's (lib\Kit\SettingsWin.ahk): tray menu > Settings, or
; the gear in the word list. GENERAL and KEYS come first, as in every script;
; Vocab's rows follow (VocabRows, in Config.ahk). One of them is drawn here,
; because it is more than a box: the key (hidden unless "show" is clicked), a
; "test" that asks Google whether the key is good, and the link to get a free
; one.
;
; "test" asks for the list of models, one row of it. That proves the key and
; the connection without spending any of the free quota lookups use.
;
; With no key set, the app says so where it matters, and every one of those
; places opens the window at the key box (GeminiKeyBox): a tray notice at
; start (click it), and a line on the Translate, Summary and word cards.
;================================================================================
#Requires AutoHotkey v2.0

; the [Sound] section: read at start, and again after Settings changed it
LoadSoundSettings() {
    global SpeakAuto
    try SpeakAuto := Integer(IniRead(VocabIni(), "Sound", "SayOnLookup", SpeakAuto))
}

GeminiKeyUrl() => "https://aistudio.google.com/apikey"

; At start, when there is no key: a tray notice, and clicking it opens the key box
NoKeyNotice() {
    if (GeminiKey() != "")
        return
    Kit.Notice("Word lookups work without it. For plain-English explanations and summaries, "
        . "add a free Gemini key - click here, or tray icon > Settings.", AppName ": no Gemini key"
        , () => GeminiKeyBox())
}

; The line a card shows where Gemini's part would be, when there is no key or
; Google turned it down - a link straight to the key box.
NoKeyLine(f, lk) {
    txt := (lk && lk.ai.enabled)
        ? "Google turned down the Gemini key - click to check it in Settings"
        : "This part needs a free Gemini key - click to add one"
    return Link(f.Text(txt, CAmber, "s8 Norm"), (*) => GeminiKeyBox())
}

KeyTrouble(lk) => (lk && (!lk.ai.enabled || InStr(lk.ai.note, "key rejected")))

; the settings window, scrolled to the key box, with the focus in it
GeminiKeyBox() {
    KitSettings.Show()
    KitSettings.Reveal(GeminiRow.key)
    try {
        if (Trim(GeminiRow.key.Value) = "")
            GeminiRow.Note("Click " Chr(0x201C) "get a free key" Chr(0x201D) " - it takes about two minutes.")
    }
}

;================================================================================
; The key row: a kit row of kind "custom" (Add draws it, Sync fills it)
;================================================================================
class GeminiRow {
    static key := "", showLink := "", noteBox := "", shown := false
    static saver := "", tester := "", req := ""

    ; the row's controls on c from y down; returns the y below them
    static Add(c, y) {
        this.shown := false
        if !this.saver {
            this.saver := ObjBindMethod(GeminiRow, "Save")
            this.tester := ObjBindMethod(GeminiRow, "TestPoll")
        }
        KitSettings.Label(c, y - KitS(3), "Key", 556)
        y += KitS(24)
        this.key := KitSettings.Edit(c, KitS(22), y, KitS(430), "Password")
        this.key.OnEvent("Change", (*) => KitSettings.loading ? 0 : SetTimer(GeminiRow.saver, -500))
        this.key.OnEvent("LoseFocus", (*) => GeminiRow.Save())
        KitSettings.savers.Push(() => GeminiRow.Save())        ; a key typed a moment ago, when it closes
        c.SetFont("s9 Norm c" Theme.Blue, Theme.Font)
        this.showLink := Link(c.Add("Text", "x" KitS(466) " y" (y + KitS(4)) " w" KitS(44) " BackgroundTrans +0x80", "show")
            , (*) => GeminiRow.ToggleShow())
        Link(c.Add("Text", "x" KitS(518) " y" (y + KitS(4)) " w" KitS(60) " BackgroundTrans +0x80", "test")
            , (*) => GeminiRow.Test())
        y += KitS(34)
        get := Link(c.Add("Text", "x" KitS(22) " y" y " BackgroundTrans +0x80", "get a free key"), (*) => Run(GeminiKeyUrl()))
        get.GetPos(&gx, , &gw)
        c.SetFont("s9 Norm c" Theme.Dim, Theme.Font)
        c.Add("Text", "x" (gx + gw + KitS(10)) " y" y " w" (KitS(578) - gx - gw - KitS(10)) " BackgroundTrans +0x80"
            , "sign in with Google, press Create API key, copy it, paste it above")
        y += KitS(22)
        c.SetFont("s9 Norm c" Theme.Muted, Theme.Font)
        this.noteBox := c.Add("Text", "x" KitS(22) " y" y " w" KitS(556) " h" KitS(34) " BackgroundTrans +0x80", "")
        return y + KitS(40)
    }

    static Sync() {
        this.key.Value := Trim(IniRead(VocabIni(), "Gemini", "ApiKey", ""))
        this.Note("")
    }

    static Save(*) {
        SetTimer(this.saver, 0)
        try {
            k := Trim(this.key.Value)
            if (k != Trim(IniRead(VocabIni(), "Gemini", "ApiKey", "")))
                IniWrite(k, VocabIni(), "Gemini", "ApiKey")
        }
    }

    static Note(msg, color := "") {
        try {
            this.noteBox.SetFont("c" (color != "" ? color : Theme.Muted))
            this.noteBox.Text := msg
        }
    }

    static ToggleShow() {
        this.shown := !this.shown
        SendMessage(0xCC, this.shown ? 0 : 0x25CF, 0, this.key)        ; EM_SETPASSWORDCHAR
        this.key.Redraw()
        this.showLink.Text := this.shown ? "hide" : "show"
    }

    ;----------------------------------------------------------------------------
    ; "test": one small request that needs the key, and no quota
    ;----------------------------------------------------------------------------
    static Test() {
        k := Trim(this.key.Value)
        if (k = "") {
            this.Note("Paste a key first - " Chr(0x201C) "get a free key" Chr(0x201D) " opens the page.", Theme.Amber)
            return
        }
        if this.req                             ; one test at a time
            return
        this.Save()
        this.Note("asking Google" Chr(0x2026), Theme.Muted)
        this.req := Http(AiTrack.Api "models?pageSize=1"
            , {timeout: 8000, headers: Map("x-goog-api-key", k)})
        SetTimer(this.tester, 100)
    }

    static TestPoll() {
        if !this.req.Poll()
            return
        SetTimer(this.tester, 0)
        r := this.req, this.req := ""
        msg := r.Ok ? "" : AiTrack.ErrMsg(r)
        if r.Ok {
            AiTrack.keyBad := ""
            this.Note("The key works.", Theme.Green)
        } else if AiTrack.IsKeyError(r, msg)
            this.Note("Google says this key is not valid. Copy it again from the page - all of it.", Theme.Red)
        else if (r.status = 429)
            this.Note("The key is fine, but its free quota is used up for now. It comes back by itself.", Theme.Amber)
        else if InStr(msg, "location is not supported")
            this.Note("Gemini is not offered in your region. A VPN, with the proxy below, gets around it.", Theme.Red)
        else if (r.err != "")
            this.Note("Could not reach Google (" r.err "). Check the internet, or the proxy below.", Theme.Red)
        else
            this.Note("Google answered: " ((msg != "") ? Http.Short(msg) : r.Why), Theme.Red)
    }
}
