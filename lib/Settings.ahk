;================================================================================
; Settings.ahk - Vocab's own part of the settings window: the AI keys and model
;================================================================================
; The window is the kit's (lib\Kit\SettingsWin.ahk): tray menu > Settings, or
; the gear in the word list. GENERAL and KEYS come first, as in every script;
; Vocab's rows follow (VocabRows, in Config.ahk). The AI part is drawn here,
; because it is more than boxes, and kept short - two lines a key:
;
;   Gemini key      [.........]  show  test
;                   get a free key   sign in with Google, ...
;   Cloudflare      [.........]  show  test
;                   get a free token   Create Token, ...
;   Ask first       [Automatic          v]
;   Then, Then      two more, "Automatic from here" until picked
;   Try up to       [3]  models in one lookup, then it gives up
;   one line for what "test" found
;
; Either key is enough; with both, one stands in for the other (AiTrack in
; Lookup.ahk). "test" proves a key and the connection without spending any
; of the free requests lookups use: Gemini's asks for one row of the model
; list, Cloudflare's for the token's account and one row of its models.
;
; The models are lists, not boxes to type in: automatic, then the models the
; keys can use - Gemini's from Google's own list of the day, Cloudflare's
; free ones from its list of the day. A name typed by hand that Google did
; not know failed on every lookup. See ModelRow.
;
; With no key set, the app says so where it matters, and every one of those
; places opens the window at the Gemini key box (GeminiKeyBox): a tray notice
; at start (click it), and a line on the Translate, Summary and word cards.
;================================================================================
#Requires AutoHotkey v2.0

; the [Sound] section: read at start, and again after Settings changed it
LoadSoundSettings() {
    global SpeakAuto
    try SpeakAuto := Integer(IniRead(VocabIni(), "Sound", "SayOnLookup", SpeakAuto))
}

GeminiKeyUrl() => "https://aistudio.google.com/apikey"
CloudflareTokenUrl() => "https://dash.cloudflare.com/profile/api-tokens"

; At start, when there is no key: a tray notice, and clicking it opens the key box
NoKeyNotice() {
    if (GeminiKey() != "" || CloudflareToken() != "")
        return
    Kit.Notice("Word lookups work without it. For plain-English explanations and summaries, "
        . "add a free AI key - click here, or tray icon > Settings.", AppName ": no AI key"
        , () => GeminiKeyBox())
}

; The line a card shows where the AI's part would be, when there is no key or
; the key was turned down - a link straight to the key box.
NoKeyLine(f, lk) {
    txt := (lk && lk.ai.enabled)
        ? lk.ai.Who " turned down the key - click to check it in Settings"
        : "This part needs a free AI key - click to add one"
    return Link(f.Text(txt, CAmber, "s8 Norm"), (*) => GeminiKeyBox())
}

KeyTrouble(lk) => (lk && (!lk.ai.enabled || InStr(lk.ai.note, "key rejected")))

; In the last two weeks of the Cloudflare token, and after it: one line on
; the card once the AI part is done, a link to the token box. Nothing else -
; no notice, no window (AiTrack.CfEndsNote).
CfEndsLine(f, lk) {
    if (!lk || !lk.ai.done || (txt := AiTrack.CfEndsNote()) = "")
        return
    Link(f.Text(txt, CAmber, "s8 Norm"), (*) => CloudflareKeyBox())
}

; the settings window, scrolled to the Cloudflare token box
CloudflareKeyBox() {
    KitSettings.Show()
    KitSettings.Reveal(CloudflareRow.key)
}

; the settings window, scrolled to the key box, with the focus in it
GeminiKeyBox() {
    KitSettings.Show()
    KitSettings.Reveal(GeminiRow.key)
    try {
        if (Trim(GeminiRow.key.Value) = "" && Trim(CloudflareRow.key.Value) = "")
            GeminiRow.Note("Either key is enough. " Chr(0x201C) "get a free key" Chr(0x201D) " takes about two minutes.")
    }
}

;================================================================================
; A key row: label, the hidden key, show, test - and under it the link to get
; one. Kit rows of kind "custom" (Add draws one, Sync fills it). GeminiRow and
; CloudflareRow are the two; each says where its key lives and how to test it.
;================================================================================
class KeyRow {
    static key := "", showLink := "", shown := false
    static saver := "", tester := "", req := ""

    ; the row's controls on c from y down; returns the y below them
    static Add(c, y) {
        this.shown := false, this.req := ""
        if !this.saver {
            this.saver := ObjBindMethod(this, "Save")
            this.tester := ObjBindMethod(this, "TestPoll")
        }
        KitSettings.Label(c, y, this.Label, 126)
        this.key := KitSettings.Edit(c, KitS(150), y, KitS(300), "Password")
        this.key.OnEvent("Change", (*) => KitSettings.loading ? 0 : SetTimer(this.saver, -500))
        this.key.OnEvent("LoseFocus", (*) => this.Save())
        KitSettings.savers.Push(() => this.Save())          ; a key typed a moment ago, when it closes
        c.SetFont("s9 Norm c" Theme.Blue, Theme.Font)
        this.showLink := Link(c.Add("Text", "x" KitS(466) " y" (y + KitS(4)) " w" KitS(44) " BackgroundTrans +0x80", "show")
            , (*) => this.ToggleShow())
        Link(c.Add("Text", "x" KitS(518) " y" (y + KitS(4)) " w" KitS(60) " BackgroundTrans +0x80", "test")
            , (*) => this.Test())
        y += KitS(32)
        get := Link(c.Add("Text", "x" KitS(150) " y" y " BackgroundTrans +0x80", this.GetText), (*) => Run(this.GetUrl))
        get.GetPos(&gx, , &gw)
        c.SetFont("s9 Norm c" Theme.Dim, Theme.Font)
        c.Add("Text", "x" (gx + gw + KitS(10)) " y" y " w" (KitS(578) - gx - gw - KitS(10)) " BackgroundTrans +0x80", this.How)
        return y + KitS(32)
    }

    static Sync() {
        this.key.Value := this.Saved()
        this.Note("")
    }

    static Saved() => Trim(IniRead(VocabIni(), this.Sect, this.IniKey, ""))

    static Save(*) {
        SetTimer(this.saver, 0)
        try {
            k := Trim(this.key.Value)
            if (k != this.Saved()) {
                IniWrite(k, VocabIni(), this.Sect, this.IniKey)
                ModelRow.Fill()                 ; what the model list can offer changed
            }
        }
    }

    ; what "test" found, on the line under the model - shared by both keys
    static Note(msg, color := "") => ModelRow.Note(msg, color)

    static ToggleShow() {
        this.shown := !this.shown
        SendMessage(0xCC, this.shown ? 0 : 0x25CF, 0, this.key)        ; EM_SETPASSWORDCHAR
        this.key.Redraw()
        this.showLink.Text := this.shown ? "hide" : "show"
    }

    static Test() {
        k := Trim(this.key.Value)
        if (k = "") {
            this.Note("Paste a key first - " Chr(0x201C) this.GetText Chr(0x201D) " opens the page.", Theme.Amber)
            return
        }
        if this.req                             ; one test at a time
            return
        this.Save()
        this.Note("asking " this.Who Chr(0x2026), Theme.Muted)
        this.req := this.FirstRequest(k)
        SetTimer(this.tester, 100)
    }

    static TestPoll() {
        if !this.req.Poll()
            return
        SetTimer(this.tester, 0)
        r := this.req, this.req := ""
        if IsObject(next := this.Answered(r)) {     ; a second question
            this.req := next
            SetTimer(this.tester, 100)
        }
    }
}

;--------------------------------------------------------------------------------
; Gemini: "test" asks for one row of the model list
;--------------------------------------------------------------------------------
class GeminiRow extends KeyRow {
    static Label := "Gemini key", Sect := "Gemini", IniKey := "ApiKey", Who := "Google"
    static GetText := "get a free key", How := "sign in with Google, Create API key, paste it"
    static GetUrl => GeminiKeyUrl()

    static FirstRequest(k) => Http(AiTrack.Api "models?pageSize=1", {timeout: 8000, headers: Map("x-goog-api-key", k)})

    static Answered(r) {
        msg := r.Ok ? "" : AiTrack.ErrMsg(r)
        if r.Ok {
            AiTrack.keyBad := ""
            this.Note("The Gemini key works.", Theme.Green)
        } else if AiTrack.IsKeyError(r, msg)
            this.Note("Google says this key is not valid. Copy it again from the page - all of it.", Theme.Red)
        else if (r.status = 429)
            this.Note("The key is fine, but its free quota is used up for now. It comes back by itself.", Theme.Amber)
        else if InStr(msg, "location is not supported")
            this.Note("Gemini is not offered in your region. A VPN gets around it - or use Cloudflare.", Theme.Red)
        else if (r.err != "")
            this.Note("Could not reach Google (" r.err "). Check the internet, or the proxy below.", Theme.Red)
        else
            this.Note("Google answered: " ((msg != "") ? Http.Short(msg) : r.Why), Theme.Red)
    }
}

;--------------------------------------------------------------------------------
; Cloudflare: "test" asks which account the token is for - kept, so a lookup
; need not ask - then for one row of its AI models, which needs Workers AI on
; the token
;--------------------------------------------------------------------------------
class CloudflareRow extends KeyRow {
    static Label := "Cloudflare token", Sect := "Cloudflare", IniKey := "Token", Who := "Cloudflare"
    static GetText := "get a free token", How := "Create Token, Workers AI template, paste it"
    static GetUrl => CloudflareTokenUrl()
    static stage := "", verify := []

    ; the end of "The Cloudflare token works"
    static EndsText(ends) => (ends = "never") ? ", and it never ends."
        : IsTime(ends) ? " - until " AiTrack.LocalDate(ends) "." : "."

    static Auth(k) => Map("Authorization", "Bearer " k)

    static FirstRequest(k) {
        this.stage := "account"
        return Http(AiTrack.CfApi "accounts?per_page=5", {timeout: 8000, headers: this.Auth(k)})
    }

    static Answered(r) {
        k := Trim(this.key.Value)
        if (this.stage = "account" && r.Ok) {
            acc := ""
            try acc := AiTrack.CfAccountOf(r)
            if (acc = "") {
                this.Note("The token works, but it reaches no account. Make it from the Workers AI template.", Theme.Red)
                return
            }
            AiTrack.CfKeep(acc, k)
            AiTrack.CfListWarm()                ; its free models, for the lists below
            this.stage := "models"
            return Http(AiTrack.CfApi "accounts/" acc "/ai/models/search?per_page=1", {timeout: 8000, headers: this.Auth(k)})
        }
        ; it works - and when does it stop? Asked at both addresses, the
        ; account's first (AiTrack.CfWarm); not knowing is no failure
        if (r.Ok && this.stage = "models") {
            this.stage := "ends", this.verify := AiTrack.CfVerifyUrls()
            return Http(this.verify.RemoveAt(1), {timeout: 8000, headers: this.Auth(k)})
        }
        if (this.stage = "ends") {
            if ((ends := AiTrack.CfEndsOf(r)) = "" && this.verify.Length)
                return Http(this.verify.RemoveAt(1), {timeout: 8000, headers: this.Auth(k)})
            if (ends != "") {
                AiTrack.cfEnds := ends
                AiTrack.SaveState()
            }
            this.Note("The Cloudflare token works" this.EndsText(ends), Theme.Green)
            return
        }
        if r.Ok
            this.Note("The Cloudflare token works.", Theme.Green)
        else if AiTrack.CfKeyError(r)
            this.Note((this.stage = "models")
                ? "The token is real, but Workers AI is not on it. Make a new one from the Workers AI template."
                : (AiTrack.CfEndsNote(k) ~= "ended")
                ? "This token has ended (" AiTrack.LocalDate(AiTrack.cfEnds) "). Make a new one - " Chr(0x201C) this.GetText Chr(0x201D) "."
                : "Cloudflare says this token is not valid. Copy it again - all of it.", Theme.Red)
        else if (r.err != "")
            this.Note("Could not reach Cloudflare (" r.err "). Check the internet, or the proxy below.", Theme.Red)
        else if !AiTrack.FromCf(r)
            this.Note("Cloudflare not reached (HTTP " r.status " from the network) - check the VPN or proxy.", Theme.Red)
        else
            this.Note("Cloudflare answered: " Http.Short(AiTrack.ErrMsg(r) || r.Why), Theme.Red)
    }
}

;================================================================================
; Model: which to ask first, and how many to ask
;================================================================================
;   Ask first   [Automatic                    v]
;   Then        [Automatic from here           v]
;   Then        [Automatic from here           v]
;   Try up to   [3]  models in one lookup, then it gives up
;
; Each list: both sides' models, each with its key - Gemini's from Google's
; list of the day, Cloudflare's free ones from Cloudflare's (PickCfModels).
; After the picks comes the automatic order, so one pick is enough. A
; Cloudflare model Vocab has not tested says so beside it: its answers may be
; wrong in some languages without any error. All three lists are always
; there - "Automatic from here" takes a pick away; a list under one left on
; automatic goes grey (AiPicks). An "+ add another" link was tried first, but
; nothing took a list away again (the user, 2026-11-19).
;================================================================================
class ModelRow {
    static box := "", values := []              ; the first list, and what it offers
    static boxes := [], tags := [], vals := [], noteBox := "", tries := ""

    static Labels := ["Ask first", "Then", "Then"]

    static Add(c, y) {
        this.boxes := [], this.tags := [], this.vals := []
        loop AiPickKeys().Length {
            i := A_Index
            KitSettings.Label(c, y, this.Labels[i], 126)
            c.SetFont("s10 Norm c" Theme.Text, Theme.Font)
            b := c.Add("DropDownList", "x" KitS(150) " y" y " w" KitS(300) " r14", ["Automatic"])
            Theme.Skin(b)
            b.OnEvent("Change", ObjBindMethod(ModelRow, "Pick", i))
            c.SetFont("s8 Norm c" Theme.Amber, Theme.Font)
            this.tags.Push(c.Add("Text", "x" KitS(462) " y" (y + KitS(5)) " w" KitS(116) " BackgroundTrans +0x80", ""))
            this.boxes.Push(b), this.vals.Push([])
            y += KitS(36)
        }
        this.box := this.boxes[1]
        KitSettings.Label(c, y, "Try up to", 126)
        this.tries := KitSettings.Edit(c, KitS(150), y, KitS(44), "Number Limit1")
        this.tries.OnEvent("Change", (*) => KitSettings.loading ? 0 : ModelRow.SaveTries())
        c.SetFont("s9 Norm c" Theme.Muted, Theme.Font)
        c.Add("Text", "x" KitS(204) " y" (y + KitS(4)) " w" KitS(374) " BackgroundTrans +0x80"
            , "models in one lookup (1 to 6), then it gives up")
        y += KitS(36)
        c.SetFont("s9 Norm c" Theme.Muted, Theme.Font)
        this.noteBox := c.Add("Text", "x" KitS(22) " y" y " w" KitS(556) " h" KitS(34) " BackgroundTrans +0x80", "")
        return y + KitS(40)
    }

    static Sync() {
        this.Fill()
        try this.tries.Value := AiTries()
    }

    static Note(msg, color := "") {
        try {
            this.noteBox.SetFont("c" (color != "" ? color : Theme.Muted))
            this.noteBox.Text := msg
        }
    }

    static SaveTries() {
        v := Trim(this.tries.Value)
        if IsInteger(v)
            try IniWrite(Max(1, Min(6, Integer(v))), VocabIni(), "Gemini", "Tries")
    }

    ; The list for menu i: automatic (or, after the first, "nothing more"),
    ; then Gemini's models (today's list, newest first; the -latest guesses
    ; before there is one), then Cloudflare's - each side only with its key. A
    ; model picked earlier stays in the list even when the day's list no
    ; longer has it.
    static Choices(i := 1) {
        gem := (GeminiKey() != ""), cf := (CloudflareToken() != "")
        vals := [""]
        names := [(i > 1) ? "Automatic from here" : (gem && cf) ? "Automatic (Gemini, then Cloudflare)" : "Automatic"]
        AiTrack.LoadState()
        if gem {
            if (AiTrack.listed != FormatTime(, "yyyyMMdd"))
                AiTrack.Warm()                  ; the day's list, for the next time it opens
            for m in ModelRow.Newest(AiTrack.chain || AiTrack.Guess)
                vals.Push(m), names.Push(ModelRow.Name(m))
        }
        if cf {
            AiTrack.CfListWarm()                ; Cloudflare's, once a day
            for m in ((AiTrack.cfChain is Array && AiTrack.cfChain.Length) ? AiTrack.cfChain : [AiTrack.CfModel])
                if !HasVal(vals, m)
                    vals.Push(m), names.Push(ModelRow.Name(m))
        }
        cur := Trim(IniRead(VocabIni(), "Gemini", AiPickKeys()[i], ""))
        cur := AiTrack.IsModelName(cur) ? cur : ""
        if (cur != "" && !HasVal(vals, cur))
            vals.Push(cur), names.Push(ModelRow.Name(cur))
        return {vals: vals, names: names, cur: cur}
    }

    static Name(m) => AiTrack.IsCf(m) ? AiTrack.Short(m) ((m = AiTrack.CfModel) ? "  (tested)" : "")
        : "Gemini " AiTrack.Short(m)

    ; Flash newest first, then Flash-Lite, then the -latest names
    static Newest(list) {
        rank(m) => (RegExMatch(m, "^gemini-(\d+(?:\.\d+)?)", &v) ? (InStr(m, "lite") ? 1000 : 0) - v[1] * 10 : 5000)
        out := []
        for m in list {
            i := 1
            while (i <= out.Length && rank(out[i]) <= rank(m))
                i++
            out.InsertAt(i, m)
        }
        return out
    }

    static Fill() {
        if !this.boxes.Length
            return
        was := KitSettings.loading
        KitSettings.loading := true
        for i, b in this.boxes {
            try {
                ch := this.Choices(i)
                this.vals[i] := ch.vals
                b.Delete()
                b.Add(ch.names)
                pick := 1
                for j, v in ch.vals
                    if (v = ch.cur)
                        pick := j
                b.Value := pick
                this.Tag(i, ch.cur)
                ; used only after a pick above it - see AiPicks
                b.Enabled := (i = 1 || (this.boxes[i - 1].Enabled && this.boxes[i - 1].Value > 1))
            }
        }
        this.values := this.vals[1]
        KitSettings.loading := was
    }

    static Tag(i, m) {
        try this.tags[i].Text := (m != "" && !AiTrack.Tested(m)) ? "not tested" : ""
    }

    static Pick(i := 1, *) {
        b := this.boxes[i], vals := this.vals[i]
        if (KitSettings.loading || b.Value < 1 || b.Value > vals.Length)
            return
        m := vals[b.Value]
        try IniWrite(m, VocabIni(), "Gemini", AiPickKeys()[i])
        this.Tag(i, m)
        if (m != "" && !AiTrack.Tested(m))
            this.Note("Vocab has not tested " AiTrack.Short(m) " - check its answers in your language. "
                . "If it is wrong or slow, pick another.", Theme.Amber)
        else
            this.Note("")
        if (i < this.boxes.Length)
            this.Fill()                         ; the lists under it come on or go grey
    }
}
