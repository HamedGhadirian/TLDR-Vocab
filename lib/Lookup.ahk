;================================================================================
; Lookup.ahk - where definitions and translations come from
;================================================================================
; Every lookup runs three tracks side by side. Each works down its own list of
; free sources and stops at the first one that answers:
;
;   definitions   freedictionaryapi.com -> Wiktionary -> Datamuse
;                 (+ Datamuse for an American pronunciation when none came)
;   translation   Google (dictionary client) -> Google (gtx) -> Lingva -> MyMemory,
;                 into the language chosen in Settings (see Language.ahk)
;   in context    Gemini and/or Cloudflare Workers AI, only when a key is set
;                 (see GeminiKey and CloudflareToken below)
;
; A timeout, an HTTP error, a garbled reply and "no such word" all mean the
; same thing: move on to the next source. Every one of those has been seen for
; real - Google's gtx client has refused requests as automated - which is why
; the lists are as long as they are (docs\decisions.md has the history).
;
; An inflected word ("running") that a dictionary only knows as "present
; participle of run" gets its lemma looked up too, and both are shown. If no
; source knows the word at all, plain de-inflections are tried (studies ->
; study, stopped -> stop) before giving up.
;
; The first two tracks are cached per word under cache\, so a word met twice
; costs nothing the second time and still resolves offline. Gemini's answer
; depends on the sentence, so it is never cached.
;
; Nothing blocks. Requests go out asynchronously and one 50 ms timer polls all
; of them, so the popup is on screen before the first answer arrives.
;================================================================================
#Requires AutoHotkey v2.0

; Vocab.ini beside Vocab.ahk - the kit knows its path (Kit.Start, Vocab.ahk)
VocabIni() => Kit.ini

; The key lives in Vocab.ini rather than in this file, so the script can be
; shared without it; the settings window writes it there. GEMINI_API_KEY in
; the environment works too. Both are read on every lookup, so a new key takes
; effect without a reload.
GeminiKey() {
    k := Trim(IniRead(VocabIni(), "Gemini", "ApiKey", ""))
    return (k != "") ? k : Trim(EnvGet("GEMINI_API_KEY"))
}
; The model Settings > Model picked to ask first, or "" for automatic. Only a
; real model name counts: anything else ("flash", typed by hand when this was
; a box) would be asked for first on every lookup and fail every time.
GeminiModel() {
    m := Trim(IniRead(VocabIni(), "Gemini", "Model", ""))
    return AiTrack.IsModelName(m) ? m : ""
}

; Every model picked in Settings, in order - Model, Model2, Model3 - real
; names only, each once. Either side's: the section is still called Gemini.
; They stop at the first one left on automatic: "Then" after "Automatic"
; would otherwise be asked first, which is not what the window says.
AiPicks() {
    out := []
    for k in AiPickKeys() {
        m := Trim(IniRead(VocabIni(), "Gemini", k, ""))
        if !AiTrack.IsModelName(m)
            break
        if !HasVal(out, m)
            out.Push(m)
    }
    return out
}
AiPickKeys() => ["Model", "Model2", "Model3"]

; How many models one lookup asks before it gives up (Settings > Try up to)
AiTries() {
    n := Trim(IniRead(VocabIni(), "Gemini", "Tries", 3))
    return IsInteger(n) ? Max(1, Min(6, Integer(n))) : 3
}

; Cloudflare Workers AI: the other way to the same answers (AiTrack). One token
; is all it takes - the account it belongs to is asked for once and kept.
CloudflareToken() => Trim(IniRead(VocabIni(), "Cloudflare", "Token", ""))

; Errors that would otherwise vanish inside a timer end up here - never in a
; dialog, which would steal focus from whatever you were reading.
VocabLog(msg) {
    try FileAppend(FormatTime(, "yyyy-MM-dd HH:mm:ss") "  " msg "`n", A_ScriptDir "\errors.log", "UTF-8")
}

; Run at start: past 200 KB, errors.log keeps only its newest 100 KB, from the
; start of a line. Nothing reads the log but people, and nobody reads that much.
TrimLog() {
    f := A_ScriptDir "\errors.log"
    try {
        if (FileGetSize(f) <= 200000)
            return
        t := SubStr(FileRead(f, "UTF-8"), -100000)
        WriteFileAtomic(f, SubStr(t, InStr(t, "`n") + 1))
    }
}

HasVal(arr, v) {
    for x in arr
        if (x = v)
            return true
    return false
}

Join(arr, sep, most := 0) {
    out := ""
    for i, x in arr {
        if (most && i > most)
            break
        out .= (i > 1 ? sep : "") x
    }
    return out
}

WriteFileAtomic(path, text) {
    tmp := path ".tmp"
    try FileDelete(tmp)
    FileAppend(text, tmp, "UTF-8-RAW")
    FileMove(tmp, path, 1)
}

;--------------------------------------------------------------------------------
; One asynchronous HTTP request: the kit's (lib\Kit\Http.ahk) - Poll() until
; it returns true; Ok, Why, text, raw, Abort(); the proxy from [Network] Proxy.
; What Vocab adds: the User-Agent its sources have always seen (Kit.Start
; hands it to the kit), and Enc, for words in a web address.
;--------------------------------------------------------------------------------
class Http extends KitHttp {
    static UA := "Mozilla/5.0 (Windows NT 10.0; Win64; x64) VocabLookup/1.0"

    static Enc(s) {
        buf := Buffer(StrPut(s, "UTF-8"))
        StrPut(s, buf, "UTF-8")
        out := ""
        loop buf.Size - 1 {
            b := NumGet(buf, A_Index - 1, "uchar")
            out .= ((b >= 0x30 && b <= 0x39) || (b >= 0x41 && b <= 0x5A) || (b >= 0x61 && b <= 0x7A)
                || b = 0x2D || b = 0x2E || b = 0x5F || b = 0x7E) ? Chr(b) : Format("%{:02X}", b)
        }
        return out
    }
}

;--------------------------------------------------------------------------------
; cache\<word>.json holds {"def": ..., "fa": ...} for that word
;--------------------------------------------------------------------------------
class Cache {
    static Dir := A_ScriptDir "\cache"

    static File(q) {
        if (q = "" || StrLen(q) > 60 || RegExMatch(q, "(\S+\s+){4}"))   ; sentences are not worth keeping
            return ""
        return Cache.Dir "\" RegExReplace(q, "[^a-z0-9' -]", "_") ".json"
    }

    static Get(q, kind) {
        f := Cache.File(q)
        if (f = "" || !FileExist(f))
            return ""
        try return Dig(KitJson.Parse(FileRead(f, "UTF-8")), kind)
        return ""
    }

    static Put(q, kind, data) {
        f := Cache.File(q)
        if (f = "")
            return
        m := ""
        try m := KitJson.Parse(FileRead(f, "UTF-8"))
        if !(m is Map)
            m := Map()
        m[kind] := data
        try {
            DirCreate(Cache.Dir)
            WriteFileAtomic(f, KitJson.Dump(m, " "))
        } catch as e
            VocabLog("cache write failed for " q ": " e.Message)
    }
}

;--------------------------------------------------------------------------------
; A lookup: one word, the sentence it came from, three tracks
;--------------------------------------------------------------------------------
class Lookup {
    static active := [], ticker := ""

    ; again: asked for by hand ("look up again"), so resting models get
    ; another chance (AiTrack.Forgive)
    __New(word, context, onUpdate, mode := "word", again := false) {
        this.word := word
        this.again := again
        this.query := Lookup.Norm(word)
        this.context := context
        this.mode := mode               ; "word", or "sentence" - see Sentence.ahk
        this.onUpdate := onUpdate
        this.cancelled := false
        this.fresh := true          ; one update on the first tick, for cached answers
        this.def := DefTrack(this)
        this.fa  := FaTrack(this)
        this.ai  := AiTrack(this)
        Lookup.active.Push(this)
        if !Lookup.ticker
            Lookup.ticker := ObjBindMethod(Lookup, "Tick")
        SetTimer(Lookup.ticker, 50)
    }

    Done => (this.def.done && this.fa.done && this.ai.done)
    Cancel() => this.cancelled := true

    static Norm(w) => Trim(RegExReplace(StrLower(StrReplace(w, Chr(0x2019), "'")), "\s+", " "))

    static Tick() {
        i := Lookup.active.Length
        while (i >= 1) {
            l := Lookup.active[i]
            if !l.cancelled {
                changed := l.def.Step() | l.fa.Step() | l.ai.Step()
                if (changed || l.fresh) {
                    l.fresh := false
                    try l.onUpdate.Call(l)
                    catch as e
                        VocabLog("update failed: " e.Message " (" e.What " line " e.Line ")")
                }
            }
            if (l.cancelled || l.Done)
                Lookup.active.RemoveAt(i)
            i--
        }
        if !Lookup.active.Length
            SetTimer(Lookup.ticker, 0)
    }
}

;--------------------------------------------------------------------------------
; A track works through a queue of steps, one request at a time. Each step is
; {name, url, parse, opts?, after?}; parse gets the finished Http and returns
; the answer, or "" for "this source had nothing".
;   after   A_TickCount before which the step is not sent - a short pause
;           before trying again
;--------------------------------------------------------------------------------
class Track {
    __New(lk) {
        this.lk := lk, this.done := false, this.data := "", this.source := ""
        this.tried := [], this.note := "", this.steps := [], this.req := "", this.cur := ""
        this.cached := false, this.cacheKind := "", this.enabled := true
        this.Start()
    }

    Start() {
    }

    FromCache(kind) {
        this.cacheKind := kind
        c := Cache.Get(this.lk.query, kind)
        if !(c is Map)
            return false
        this.data := c, this.source := Dig(c, "source"), this.cached := true, this.done := true
        return true
    }

    ; true when there is something new to draw
    Step() {
        if this.done
            return false
        if !this.req {
            if !this.steps.Length
                return this.Finish()
            if (IsObject(this.steps[1]) && this.steps[1].HasProp("after") && A_TickCount < this.steps[1].after)
                return false
            this.cur := this.steps.RemoveAt(1)
            ; Every step carries an address. One that somehow does not is
            ; logged - with what it did hold - and skipped, never a dialog
            ; (see "Open questions" in docs\decisions.md).
            if !(IsObject(this.cur) && this.cur.HasProp("url")) {
                held := []
                if IsObject(this.cur)
                    for k in this.cur.OwnProps()
                        held.Push(k)
                VocabLog(Type(this) " skipped a step with no address {" Join(held, ", ") "} ("
                    . Type(this.cur) (this.HasProp("phase") ? ", phase " this.phase : "") ") for " this.lk.query)
                this.cur := ""
                return false
            }
            this.req := Http(this.cur.url, this.cur.HasProp("opts") ? this.cur.opts : "")
        }
        if !this.req.Poll()
            return false
        r := this.req, s := this.cur
        this.req := ""
        result := ""
        if r.Ok {
            try result := s.parse.Call(r)
            catch as e
                r.err := "unreadable reply"
        }
        this.tried.Push(s.name (result ? "" : " - " ((r.Ok && r.err = "") ? "no entry" : r.Why)))
        return this.Got(s, r, result)
    }

    Got(s, r, result) {
        if !result
            return false
        this.Take(s, result)
        return this.Finish()
    }

    Take(s, result) {
        if (result is Map)
            result["source"] := s.name
        this.data := result, this.source := s.name, this.steps := []
    }

    Finish() {
        this.done := true
        if (this.data && !this.cached && this.cacheKind != "")
            Cache.Put(this.lk.query, this.cacheKind, this.data)
        return true
    }
}

;--------------------------------------------------------------------------------
; Definitions. Every source is reduced to the same shape:
;   {phonetic, lemma, groups: [{pos, of?, senses: [{d, ex, fa, low}]}]}
; One group per dictionary entry, not per part of speech: "bank" the money
; place and "bank" the river edge are separate entries, and keeping them apart
; is what lets the popup show one line of EACH instead of burying the river
; under nine financial senses.
;--------------------------------------------------------------------------------
class DefTrack extends Track {
    Start() {
        if (this.lk.mode != "word") {           ; a dictionary has no entry for a sentence
            this.enabled := false, this.done := true
            return
        }
        this.phase := "word"
        if this.FromCache("def") {
            if this.NeedsPron()             ; kept before pronunciations were filled in
                this.phase := "pron", this.steps := [DefTrack.PronStep(this.lk.query)]
                    , this.done := false, this.cached := false
            return
        }
        this.steps := DefTrack.Sources(this.lk.query)
    }

    ; No source gave a pronunciation: ask Datamuse before finishing. Asked once
    ; per word - the cache remembers - so a word it does not know costs nothing
    ; the next time.
    NeedsPron() => (this.phase != "pron" && this.data && Dig(this.data, "phonetic") = ""
        && !Dig(this.data, "pronTried") && DefTrack.PronStep(this.lk.query))

    Finish() {
        if this.NeedsPron() {
            this.phase := "pron", this.steps := [DefTrack.PronStep(this.lk.query)]
            return true                 ; draw the definitions while it loads
        }
        return super.Finish()
    }

    static Sources(q, shortList := false) {
        e := Http.Enc(q)
        list := [
            {name: "freedictionaryapi.com", url: "https://freedictionaryapi.com/api/v1/entries/en/" e "?translations=true"
                , parse: ObjBindMethod(DefTrack, "FreeDict", q)},
            {name: "Wiktionary", url: "https://en.wiktionary.org/api/rest_v1/page/definition/" StrReplace(e, "%20", "_")
                , parse: ObjBindMethod(DefTrack, "Wiktionary", q)},
            {name: "Datamuse", url: "https://api.datamuse.com/words?sp=" e "&md=dp&max=1"
                , parse: ObjBindMethod(DefTrack, "Datamuse", q)}
        ]
        return shortList ? [list[1], list[2]] : list
    }

    Got(s, r, result) {
        if (this.phase = "pron") {
            this.data["pronTried"] := 1
            if result
                this.data["phonetic"] := result
            this.steps := []
            return super.Finish()
        }
        if (this.phase = "lemma") {
            if (!result && this.steps.Length)
                return false
            if result
                this.MergeLemma(result)
            this.steps := []
            return this.Finish()
        }
        if !result {
            if (!this.steps.Length && this.phase = "word") {
                this.phase := "stem"
                for cand in DefTrack.Stems(this.lk.query)
                    for src in DefTrack.Sources(cand, true) {
                        src.cand := cand
                        this.steps.Push(src)
                    }
            }
            return false
        }
        if (this.phase = "stem")
            result["lemma"] := s.cand
        result["faLang"] := Lang.Code()     ; what the senses' translations are in
        this.Take(s, result)
        target := Dig(result, "lemmaOf")
        if (this.phase = "word" && target != "" && target != this.lk.query) {
            result["lemma"] := target
            this.phase := "lemma"
            this.steps := DefTrack.Sources(target, true)
            return true                 ; draw what we have while the lemma loads
        }
        return this.Finish()
    }

    ; The lemma's entries go straight after the "form of" line that pointed at
    ; them, so "running" reads: form of run -> what run means -> running's own
    ; adjective and noun senses.
    MergeLemma(res) {
        groups := this.data["groups"]
        at := 1
        for i, grp in groups
            for s in grp["senses"]
                if RegExMatch(s["d"], "i)\bof\s+\Q" this.data["lemma"] "\E\s*$") {
                    at := i
                    break 2
                }
        for n, grp in res["groups"] {
            if (n > 3)
                break
            grp["of"] := this.data["lemma"]
            groups.InsertAt(at + n, grp)
        }
        if (this.data["phonetic"] = "")
            this.data["phonetic"] := res["phonetic"]
    }

    static Stems(q) {
        out := []
        add(w) {
            if (w != q && StrLen(w) > 2 && !HasVal(out, w))
                out.Push(w)
        }
        if RegExMatch(q, "i)^[a-z]+$") {
            if RegExMatch(q, "ie[sd]$")
                add(SubStr(q, 1, -3) "y")
            if RegExMatch(q, "([b-df-hj-np-tv-z])\1(ed|ing)$", &m)
                add(SubStr(q, 1, -StrLen(m[2]) - 1))
            if RegExMatch(q, "(ches|shes|sses|xes|zes|oes)$")
                add(SubStr(q, 1, -2))
            if RegExMatch(q, "[^s]s$")
                add(SubStr(q, 1, -1))
            if RegExMatch(q, "ed$")
                add(SubStr(q, 1, -2)), add(SubStr(q, 1, -1))
            if RegExMatch(q, "ing$")
                add(SubStr(q, 1, -3)), add(SubStr(q, 1, -3) "e")
            if RegExMatch(q, "ly$")
                add(SubStr(q, 1, -2))
            if RegExMatch(q, "(er|est)$", &m)
                add(SubStr(q, 1, -StrLen(m[1])))
        }
        while (out.Length > 3)
            out.Pop()
        return out
    }

    static FreeDict(q, r) {
        d := KitJson.Parse(r.text)
        out := DefTrack.Blank()
        for e in (Dig(d, "entries") || []) {
            if (Dig(e, "language", "code") != "en")
                continue
            if (out["phonetic"] = "")
                for p in (Dig(e, "pronunciations") || [])
                    if (Dig(p, "type") = "ipa" && SubStr(Dig(p, "text"), 1, 1) = "/") {
                        out["phonetic"] := Dig(p, "text")
                        break
                    }
            senses := []
            for s in (Dig(e, "senses") || []) {
                txt := DefTrack.Tidy(Dig(s, "definition"))
                if (txt = "")
                    continue
                tags := Dig(s, "tags") || []
                if (out["lemmaOf"] = "" && HasVal(tags, "form of"))
                    out["lemmaOf"] := DefTrack.FormOf(txt)
                fa := []
                for tr in (Dig(s, "translations") || [])
                    if (Dig(tr, "language", "code") = Lang.Dict()) {
                        w := DefTrack.NoHarakat(Dig(tr, "word"))
                        if (w != "" && !HasVal(fa, w))
                            fa.Push(w)
                    }
                ex := ""
                for x in (Dig(s, "examples") || [])
                    if ((ex := DefTrack.Plain(x)) != "")
                        break
                senses.Push(Map("d", txt, "ex", ex, "fa", Join(fa, Lang.Sep(), 3), "low", DefTrack.IsLow(tags, txt)))
            }
            if senses.Length
                out["groups"].Push(Map("pos", StrLower(Dig(e, "partOfSpeech")), "senses", DefTrack.LowLast(senses)))
        }
        return DefTrack.Finalize(out)
    }

    static Wiktionary(q, r) {
        d := KitJson.Parse(r.text)
        out := DefTrack.Blank()
        for e in (Dig(d, "en") || []) {
            senses := []
            for s in (Dig(e, "definitions") || []) {
                html := Dig(s, "definition")
                if (p := RegExMatch(html, "<(ol|ul|dl)\b"))    ; nested sub-senses: keep the headline
                    html := SubStr(html, 1, p - 1)
                txt := DefTrack.Tidy(DefTrack.Plain(html))
                if (txt = "")
                    continue
                if (out["lemmaOf"] = "" && InStr(html, "form-of-definition"))
                    out["lemmaOf"] := DefTrack.FormOf(txt)
                ex := ""
                for x in (Dig(s, "examples") || [])
                    if ((ex := DefTrack.Plain(x)) != "")
                        break
                senses.Push(Map("d", txt, "ex", ex, "fa", "", "low", DefTrack.IsLow([], txt)))
            }
            if senses.Length
                out["groups"].Push(Map("pos", StrLower(Dig(e, "partOfSpeech")), "senses", DefTrack.LowLast(senses)))
        }
        return DefTrack.Finalize(out)
    }

    static Datamuse(q, r) {
        arr := KitJson.Parse(r.text)
        if !(arr is Array) || !arr.Length || StrLower(Dig(arr, 1, "word")) != q
            return ""
        names := Map("n", "noun", "v", "verb", "adj", "adjective", "adv", "adverb", "u", "")
        byPos := Map(), posOrder := []
        for entry in (Dig(arr, 1, "defs") || []) {
            parts := StrSplit(entry, "`t", , 2)
            pos := names.Has(parts[1]) ? names[parts[1]] : parts[1]
            txt := DefTrack.Tidy(parts.Length > 1 ? parts[2] : parts[1])
            if (txt = "")
                continue
            if !byPos.Has(pos)
                byPos[pos] := [], posOrder.Push(pos)
            byPos[pos].Push(Map("d", txt, "ex", "", "fa", "", "low", DefTrack.IsLow([], txt)))
        }
        out := DefTrack.Blank()
        for pos in posOrder
            out["groups"].Push(Map("pos", pos, "senses", DefTrack.LowLast(byPos[pos])))
        return DefTrack.Finalize(out)
    }

    ; Datamuse's pronunciations come from the CMU dictionary: American, written
    ; as phoneme codes (P ER0 T ER0 B EY1 SH AH0 N) that Ipa() turns into the
    ; usual symbols. Single words only: a phrase comes back as one run of sounds
    ; with no word breaks, and a hyphenated word comes back as a different word.
    static PronStep(q) {
        if !RegExMatch(q, "^[a-z][a-z']*$")
            return ""
        return {name: "Datamuse (pronunciation)", url: "https://api.datamuse.com/words?sp=" Http.Enc(q) "&md=r&max=1"
            , parse: ObjBindMethod(DefTrack, "DatamusePron", q), opts: {timeout: 5000}}
    }

    static DatamusePron(q, r) {
        arr := KitJson.Parse(r.text)
        if !(arr is Array) || !arr.Length || StrLower(Dig(arr, 1, "word")) != q
            return ""
        for tag in (Dig(arr, 1, "tags") || [])
            if (SubStr(tag, 1, 5) = "pron:")
                return DefTrack.Ipa(SubStr(tag, 6))
        return ""
    }

    ; The stress mark goes where dictionaries put it, at the start of the
    ; stressed syllable - before the consonants that open it, so in
    ; pertur-BA-tion it comes before the b, not after it. Those consonants are
    ; the longest run that can begin an English word (im-PLODE: "pl" can, "mpl"
    ; cannot). A word of one syllable gets no mark.
    static Ipa(arpa) {
        static sym := Map("AA", Chr(0x251), "AE", Chr(0xE6), "AH", Chr(0x28C), "AO", Chr(0x254)
            , "AW", "a" Chr(0x28A), "AY", "a" Chr(0x26A), "EH", Chr(0x25B), "ER", Chr(0x25D)
            , "EY", "e" Chr(0x26A), "IH", Chr(0x26A), "IY", "i", "OW", "o" Chr(0x28A)
            , "OY", Chr(0x254) Chr(0x26A), "UH", Chr(0x28A), "UW", "u"
            , "B", "b", "CH", "t" Chr(0x283), "D", "d", "DH", Chr(0xF0), "F", "f", "G", Chr(0x261)
            , "HH", "h", "JH", "d" Chr(0x292), "K", "k", "L", "l", "M", "m", "N", "n", "NG", Chr(0x14B)
            , "P", "p", "R", Chr(0x279), "S", "s", "SH", Chr(0x283), "T", "t", "TH", Chr(0x3B8)
            , "V", "v", "W", "w", "Y", "j", "Z", "z", "ZH", Chr(0x292))
        static onsets := "|P R|B R|T R|D R|K R|G R|F R|TH R|SH R|P L|B L|K L|G L|F L|S L|T W|D W|K W|G W|S W|TH W"
            . "|P Y|B Y|K Y|G Y|F Y|V Y|M Y|HH Y|S P|S T|S K|S M|S N|S F|S P R|S T R|S K R|S P L|S K W|S K Y|S P Y|"
        toks := StrSplit(Trim(arpa), " ")
        vowels := 0
        for t in toks
            vowels += RegExMatch(t, "\d$") ? 1 : 0
        out := [], codes := [], lastV := 0
        for t in toks {
            if !RegExMatch(t, "^([A-Z]+)(\d?)$", &m) || !sym.Has(m[1])
                return ""
            if (m[2] = "") {
                out.Push(sym[m[1]]), codes.Push(m[1])
                continue
            }
            if (vowels > 1 && m[2] != "0") {
                n := out.Length - lastV
                k := lastV ? Min(n, 3) : n
                while (lastV && k > 1) {
                    run := ""
                    loop k
                        run .= (A_Index > 1 ? " " : "") codes[out.Length - k + A_Index]
                    if InStr(onsets, "|" run "|")
                        break
                    k--
                }
                if (k = 1 && codes[out.Length] = "NG")
                    k := 0
                at := out.Length - k + 1
                out.InsertAt(at, Chr(m[2] = "1" ? 0x2C8 : 0x2CC)), codes.InsertAt(at, "")
            }
            v := (m[1] = "AH" && m[2] = "0") ? Chr(0x259) : (m[1] = "ER" && m[2] = "0") ? Chr(0x25A) : sym[m[1]]
            out.Push(v), codes.Push("")
            lastV := out.Length
        }
        return out.Length ? "/" Join(out, "") "/" : ""
    }

    static Blank() => Map("groups", [], "phonetic", "", "lemma", "", "lemmaOf", "")

    ; Entries made only of obsolete / archaic senses go last
    static Finalize(out) {
        if !out["groups"].Length
            return ""
        live := [], dead := []
        for grp in out["groups"] {
            allLow := true
            for s in grp["senses"]
                if !s["low"] {
                    allLow := false
                    break
                }
            (allLow ? dead : live).Push(grp)
        }
        for grp in dead
            live.Push(grp)
        out["groups"] := live
        return out
    }

    static LowLast(senses) {
        hi := [], lo := []
        for s in senses
            (s["low"] ? lo : hi).Push(s)
        for s in lo
            hi.Push(s)
        return hi
    }

    static IsLow(tags, txt) {
        hay := Join(tags, " ") " " SubStr(txt, 1, 60)
        return RegExMatch(hay, "i)\b(obsolete|archaic|rare|dated|dialect(al)?|historical|nonstandard|eye dialect)\b") ? 1 : 0
    }

    ; "present participle and gerund of run" -> "run"
    static FormOf(txt) {
        return RegExMatch(txt, "i)\bof\s+([a-z][a-z'\- ]*?)\s*[.;]?$", &m) ? StrLower(m[1]) : ""
    }

    ; Drops the grammar labels a learner does not need from the leading
    ; bracket - "(countable, slang)" becomes "(slang)", "(transitive)" goes.
    static Tidy(t) {
        t := Trim(RegExReplace(t, "\s+", " "))
        if RegExMatch(t, "^\(([^()]*)\)\s*(.*)$", &m) {
            keep := []
            for tag in StrSplit(m[1], ",", " ")
                if !RegExMatch(tag, "i)^(countable|uncountable|transitive|intransitive|ambitransitive|ergative|not comparable|comparable|usually plural|in the plural|plural only|singular only|reflexive|copulative|stative)$")
                    keep.Push(tag)
            t := (keep.Length ? "(" Join(keep, ", ") ") " : "") m[2]
        }
        return t
    }

    static Plain(h) {
        if (h is Map)
            h := Dig(h, "text")
        if (Type(h) != "String")
            return ""
        h := RegExReplace(h, "<[^>]*>")
        while RegExMatch(h, "&#(x?)([0-9a-fA-F]+);", &m)
            h := StrReplace(h, m[0], Chr(m[1] ? Integer("0x" m[2]) : Integer(m[2])))
        for pair in [["&lt;", "<"], ["&gt;", ">"], ["&quot;", '"'], ["&nbsp;", " "], ["&amp;", "&"]]
            h := StrReplace(h, pair[1], pair[2])
        return Trim(RegExReplace(h, "\s+", " "))
    }

    ; Wiktionary writes Persian with its vowel marks; everyday Persian does not
    static NoHarakat(w) => RegExReplace(w, "[\x{064B}-\x{065F}\x{0670}]")
}

;--------------------------------------------------------------------------------
; The translation: {main, groups: [{pos, terms: [...]}]}
; Google's dictionary block is the useful part for a word with several
; meanings - bank: noun -> bank / shore / edge / ... - and FaForPos() in
; Store.ahk uses it to pick the translation that matches the chosen sense.
;--------------------------------------------------------------------------------
class FaTrack extends Track {
    Start() {
        if IsCheck(this.lk.mode) {              ; English about English - see Check.ahk
            this.enabled := false, this.done := true
            return
        }
        if this.FromCache(Lang.CacheKind())
            return
        ; a word is looked up in lower case, but a sentence or a paragraph is
        ; translated as written - and only as much of it as a URL will carry
        q := (this.lk.mode = "word") ? this.lk.query : SubStr(this.lk.word, 1, 1200)
        e := Http.Enc(q)
        base := "https://translate.googleapis.com/translate_a/single?sl=en&tl=" Lang.Code() "&dt=t&dt=bd&q=" e "&client="
        this.steps := [
            {name: "Google", url: base "dict-chrome-ex", parse: ObjBindMethod(FaTrack, "Google", q)},
            {name: "Google (gtx)", url: base "gtx", parse: ObjBindMethod(FaTrack, "Google", q)},
            {name: "Lingva", url: "https://lingva.ml/api/v1/en/" Lang.Lingva() "/" e, parse: ObjBindMethod(FaTrack, "Lingva", q)},
            {name: "MyMemory", url: "https://api.mymemory.translated.net/get?langpair=en%7C" Lang.Code() "&q=" e
                , parse: ObjBindMethod(FaTrack, "MyMemory", q)}
        ]
    }

    static Google(q, r) {
        d := KitJson.Parse(r.text)            ; the "automated queries" page is HTML and throws here
        main := ""
        for seg in (Dig(d, 1) || [])
            main .= Dig(seg, 1)
        main := Trim(main)
        groups := []
        for grp in (Dig(d, 2) || []) {
            terms := []
            for t in (Dig(grp, 2) || [])
                if (terms.Length < 6)
                    terms.Push(t)
            if terms.Length
                groups.Push(Map("pos", Dig(grp, 1), "terms", terms))
        }
        if (!groups.Length && (main = "" || main = q))
            return ""
        return Map("main", main, "groups", groups)
    }

    static Lingva(q, r) {
        t := Trim(Dig(KitJson.Parse(r.text), "translation"))
        return (t = "" || t = q) ? "" : Map("main", t, "groups", [])
    }

    static MyMemory(q, r) {
        d := KitJson.Parse(r.text)
        t := Trim(Dig(d, "responseData", "translatedText"))
        if (Dig(d, "responseStatus") != 200 || t = "" || t = q || InStr(t, "MYMEMORY"))
            return ""
        return Map("main", RTrim(t, ". "), "groups", [])
    }
}

;--------------------------------------------------------------------------------
; Gemini: {lemma, pos, meaning, persian, note, example}, for THIS sentence -
; "persian" being the translation, in whichever language is chosen
;
; Model choice is automatic unless Vocab.ini names one: the first lookup asks
; the API which models the key can use and lines up the second-newest Flash,
; then the two newest Flash-Lite, then the other Flash - the newest last -
; then Google's flash-latest aliases as a last guess. The newest Flash is the
; busiest and the slowest, and has the fewest free requests; looking up a word
; does not need it. All of it follows the versions in Google's list - no
; version is named here. A lookup asks one Flash first: the first in that
; order that is not resting (Models), then Flash-Lite (NextModel).
; If the list cannot be fetched - no network for a moment - the guess serves
; that one lookup and the list is asked for again next time; kept, it would
; pin every later lookup to the guess until a restart.
;
; Thinking is kept, but low - enough to read the sentence right, not so much
; that a lookup waits on it. 2.5 models take thinkingBudget (512, the least
; Flash-Lite accepts), 3.x take thinkingLevel; if a model rejects either, the
; request is repeated without it.
;
; WAITING. Measured through a VPN (September 2026): reaching Google takes
; 0.3 s, sometimes 1.3; the rest is Gemini itself - 1.3 s for 3.5 Flash-Lite,
; 2.6 to 6.2 s for 3.8 Flash. In October 2026 the Flash models took 10 to 37 s
; for a one-word answer, or answered 503 ("high demand"); Flash-Lite 3 to 5 s.
; The app cannot tell a stalled connection from Gemini still thinking:
; Windows' HTTP object shows neither, both run out on the same "receive"
; timeout (tested), and even Gemini's streaming answer sends nothing until the
; answer is ready. So:
;   - each model gets Wait ms; with no answer by then, the next is asked.
;     A Flash that says no at once is followed by another Flash, if there
;     is time for it and for Flash-Lite after it.
;   - a request that could not connect at all is sent again once, a second
;     later, before the next model is tried
;   - a model that said no rests (RestUntil), and the next lookup does not
;     wait on it: out of its day's free quota until the quota day starts
;     again; busy (503, 504) or silent for the whole Wait, for SlowRest;
;     out of the minute's quota, for about a minute. Only an answer from
;     Google itself rests a model: a VPN or proxy that cannot get through
;     says 503 too, for every model within seconds (October 2026 - all of
;     them rested two hours). An answer from the network instead of Google
;     ends the lookup at once - every other model goes the same way. Resting
;     models are asked only when no other model is left, Flash-Lite first,
;     and one that then answers rests no more; one out of its day's quota
;     is not asked at all. The rests are
;     kept in cache\gemini.json, so a restart does not forget them.
;   - all of it, every model and every retry, stops at Budget ms, with a note
;     that says to look up again
;
; CLOUDFLARE. With a Cloudflare token too, its CfModel stands second in line:
; after the Flash that leads, before the rest of Gemini - so a slow or busy
; Gemini costs one wait, not two. Without a Gemini key it is the only one.
; Picked in Settings > Model, it goes first. A side that cannot be used for
; this lookup - its key turned down, blocked where you are, not reached
; through the VPN - hands the lookup to the other side instead of ending it.
; Tested 2026-11-16 on Vocab's own prompts (docs\decisions.md): GPT-OSS-120B
; was right on 13 of 13 in 1 to 3 s, with Persian as good as Gemini's;
; Llama 3.3 70B was faster but wrong on meanings and mixed in other languages.
; Its free plan counts "neurons", 10,000 a day - a few hundred lookups - and
; starts again at midnight UTC.
;--------------------------------------------------------------------------------
class AiTrack extends Track {
    static chain := "", keyBad := "", cfBad := ""
    static Api := "https://generativelanguage.googleapis.com/v1beta/"
    static CfApi := "https://api.cloudflare.com/client/v4/"
    static CfModel := "@cf/openai/gpt-oss-120b"
    static cfAccount := "", cfFor := ""        ; the account, and the end of the token it belongs to
    static cfEnds := ""                         ; when that token stops working - see CfWarm
    ; Cloudflare's free text models of the day, for the lists in Settings -
    ; see PickCfModels. Only CfModel is asked without being picked: the others
    ; are not tested by Vocab.
    static cfChain := "", cfListed := "", cfListing := false
    ; the -latest aliases follow whatever Flash is current, so they never go
    ; out of date the way named models do (docs\decisions.md)
    static Guess := ["gemini-flash-latest", "gemini-flash-lite-latest"]
    static Wait := 15000, Budget := 30000, SlowRest := 2 * 3600
    ; another Flash is asked in the same lookup only if Flash-Lite would
    ; still have this long after it; Flash-Lite answers in 3 to 5 s
    static Spare := 8000
    ; What is known about the models is kept in cache\gemini.json, so a
    ; restart neither asks for the list again the same day nor tries a model
    ; that is still out of quota:
    ;   {"models": [...], "listed": "YYYYMMDD", "order": n, "resting": {model: till}}
    ; till is UTC, YYYYMMDDHHMISS. order is Order below: a list saved by a
    ; version that lined the models up differently is not used.
    static Order := 2
    static resting := Map(), listed := "", loaded := false, listing := false
    static StateFile => Cache.Dir "\gemini.json"

    Start() {
        this.key := GeminiKey(), this.cfToken := CloudflareToken()
        this.noThink := false, this.t0 := A_TickCount, this.retried := Map(), this.asked := Map(), this.status := ""
        ; Try up to: how many models, and the time for them - as before for
        ; three, 15 s more for each one past that
        this.tries := AiTries(), this.capped := false
        this.budget := Max(AiTrack.Budget, (this.tries - 1) * AiTrack.Wait)
        this.gem := (this.key != "" && AiTrack.keyBad != this.key)
        this.cf := (this.cfToken != "" && AiTrack.cfBad != this.cfToken)
        if (this.key = "" && this.cfToken = "") {
            this.enabled := false, this.done := true, this.note := "no key"
            return
        }
        if (!this.gem && !this.cf) {
            this.done := true, this.note := "key rejected - check it in Settings"
            return
        }
        ; "look up again" / "check again" pressed by hand: the busy and slow
        ; rests are lifted, so those models get another chance. One that says
        ; no again rests again. Out of the day's quota stays: it is sure to say no.
        if (this.lk.HasProp("again") && this.lk.again && AiTrack.Forgive())
            this.status := "asking the resting models again"
        this.models := AiTrack.Models(this.gem, this.cf)
        this.steps := this.models.Length ? [this.GenStep(this.models[1])] : [this.ListStep()]
        if (this.models.Length > 1 && AiTrack.IsResting(this.models[this.models.Length])) {
            ; some are resting: say why a different model is asked - but not
            ; when the first is the one picked in Settings: it leads anyway,
            ; and the line would read as if it stood in for a resting one
            first := this.models[1], skipped := ""
            if HasVal(AiPicks(), first)
                first := ""
            for m in this.models
                if (AiTrack.IsResting(m) && m != first) {
                    skipped := m
                    break
                }
            if (first != "" && skipped != "" && !AiTrack.IsResting(first))
                this.status := AiTrack.Short(first) " - " AiTrack.Why(skipped)
        }
        if (this.gem && this.models.Length && AiTrack.listed != FormatTime(, "yyyyMMdd"))
            AiTrack.Warm()                  ; a new day: a fresh list for the next lookup
        if this.cf {
            AiTrack.CfWarm()                ; when the token ends, if not known yet (once per token)
            AiTrack.CfListWarm()            ; Cloudflare's free models, once a day, for Settings
        }
    }

    ; What the card shows while it waits. Normally just "asking Gemini...";
    ; when something is not normal, one more line says what - so a busy or
    ; used-up model does not look like a broken connection.
    Waiting => "asking " this.Who Chr(0x2026) ((this.status != "") ? "`n" this.status : "")

    ; which side is being asked - or, when it is over, was asked last
    Who {
        get {
            s := (!this.req && this.steps.Length) ? this.steps[1] : this.cur
            if (IsObject(s) && s.HasProp("model"))
                return AiTrack.IsCf(s.model) ? "Cloudflare" : "Gemini"
            return (this.HasProp("cf") && this.cf && !this.gem) ? "Cloudflare" : "Gemini"
        }
    }

    static IsCf(m) => (SubStr(m, 1, 4) = "@cf/")

    ; a name worth asking for: Gemini's own kind, or the Cloudflare model
    static IsModelName(m) => (RegExMatch(m, "^@cf/[a-z0-9][a-z0-9._-]*/[a-z0-9][a-z0-9._-]*$")
        || RegExMatch(m, "^gemini-[a-z0-9][a-z0-9.-]*$"))

    ; tested by Vocab: Google's own Flash models, and CfModel (docs\decisions.md)
    static Tested(m) => !AiTrack.IsCf(m) || m = AiTrack.CfModel

    ; "gemini-3.5-flash-lite" -> "3.5 Flash-Lite", "@cf/openai/gpt-oss-120b" -> "Cloudflare GPT-OSS-120B"
    static Short(m) {
        if AiTrack.IsCf(m) {
            m := RegExReplace(m, "^.*/")
            return "Cloudflare " (InStr(m, "gpt") = 1 ? StrUpper(m) : m)
        }
        m := RegExReplace(m, "^gemini-")
        m := RegExReplace(m, "^flash-lite-latest$", "Flash-Lite (latest)")
        m := RegExReplace(m, "^flash-latest$", "Flash (latest)")
        m := RegExReplace(m, "-flash-lite$", " Flash-Lite")
        return RegExReplace(m, "-flash$", " Flash")
    }

    ; why a model is resting, in a few words. Only the day's quota rests a
    ; model until the next quota day, so a rest ending exactly then is that.
    static Why(m) {
        if !AiTrack.IsResting(m)
            return ""
        till := AiTrack.resting[m]
        if (till = AiTrack.QuotaDay(m))
            return AiTrack.Short(m) " is out of today's free requests (until " AiTrack.LocalTime(till) ")"
        return (DateDiff(till, A_NowUTC, "Minutes") >= 10)
            ? AiTrack.Short(m) " is busy or slow (skipped until " AiTrack.LocalTime(till) ")"
            : AiTrack.Short(m) " is busy for a minute"
    }
    Left => (this.HasProp("budget") ? this.budget : AiTrack.Budget) - (A_TickCount - this.t0)

    ; The model list, once a day, in the background: at start (a few seconds
    ; in) unless today's is saved, and on the first lookup of a new day.
    ; Failing is fine; a lookup with no list at all asks for it itself.
    static Warm() {
        AiTrack.LoadState()
        key := GeminiKey()
        if (key = "" || AiTrack.listing || AiTrack.listed = FormatTime(, "yyyyMMdd"))
            return
        AiTrack.listing := true
        req := Http(AiTrack.Api "models?pageSize=1000", {timeout: 8000, headers: Map("x-goog-api-key", key)})
        poll() {
            if !req.Poll()
                return
            SetTimer(poll, 0)
            AiTrack.listing := false
            if req.Ok
                try AiTrack.KeepList(AiTrack.PickModels(req)), ModelRow.Fill()   ; Settings > Model, if it is open
        }
        SetTimer(poll, 200)
    }

    static KeepList(chain) {
        AiTrack.chain := chain, AiTrack.listed := FormatTime(, "yyyyMMdd")
        AiTrack.SaveState()
    }

    static LoadState() {
        if AiTrack.loaded
            return
        AiTrack.loaded := true
        try {
            s := KitJson.Parse(FileRead(AiTrack.StateFile, "UTF-8"))
            if (Dig(s, "listed") = FormatTime(, "yyyyMMdd") && Dig(s, "order") = AiTrack.Order
                && Dig(s, "models") is Array && s["models"].Length)
                AiTrack.chain := s["models"], AiTrack.listed := s["listed"]
            if (Dig(s, "resting") is Map)
                for m, till in s["resting"]
                    if AiTrack.IsResting(m, till)
                        AiTrack.resting[m] := till
            if (Dig(s, "cf", "account") != "")
                AiTrack.cfAccount := s["cf"]["account"], AiTrack.cfFor := Dig(s, "cf", "for")
                    , AiTrack.cfEnds := Dig(s, "cf", "ends")
            ; an older day's list still fills the menus until the new one is in
            if (Dig(s, "cf", "models") is Array && s["cf"]["models"].Length)
                AiTrack.cfChain := s["cf"]["models"], AiTrack.cfListed := Dig(s, "cf", "listed")
        }
    }

    ; the end of a token: enough to tell whose the kept account is, and the
    ; token itself never goes into a cache file
    static TokenEnd(t) => SubStr(t, -8)

    static SaveState() {
        for m, till in AiTrack.resting.Clone()     ; the rests that are over go
            if !AiTrack.IsResting(m)
                AiTrack.resting.Delete(m)
        try {
            DirCreate(Cache.Dir)
            WriteFileAtomic(AiTrack.StateFile, KitJson.Dump(Map("models", AiTrack.chain || []
                , "listed", AiTrack.listed, "order", AiTrack.Order, "resting", AiTrack.resting
                , "cf", Map("account", AiTrack.cfAccount, "for", AiTrack.cfFor, "ends", AiTrack.cfEnds
                    , "models", AiTrack.cfChain || [], "listed", AiTrack.cfListed)), " "))
        } catch as e
            VocabLog("saving gemini.json failed: " e.Message)
    }

    ; every rest lifted but the day's quota; true if there was one to lift
    static Forgive() {
        AiTrack.LoadState()
        lifted := false
        for m, till in AiTrack.resting.Clone()
            if (AiTrack.IsResting(m) && till != AiTrack.QuotaDay(m))
                AiTrack.resting.Delete(m), lifted := true
        if lifted
            AiTrack.SaveState()
        return lifted
    }

    static IsResting(m, till := "") {
        if (till = "")
            till := AiTrack.resting.Has(m) ? AiTrack.resting[m] : ""
        return till != "" && DateDiff(till, A_NowUTC, "Seconds") > 0
    }

    ; How long a model that said no rests (UTC, until when). 429 says which
    ; quota ran out: the day's - 20 requests for 3.8 Flash on a free key - is
    ; out until Google's quota day starts again, at midnight Pacific time;
    ; the minute's for as long as its retryDelay says. Anything else - busy,
    ; or no answer in time - SlowRest: Google calls the busy spells "usually
    ; temporary", but they last longer than a few lookups.
    static RestUntil(r) {
        if (r.status != 429)
            return DateAdd(A_NowUTC, AiTrack.SlowRest, "Seconds")
        wait := 60
        try {
            for det in (Dig(KitJson.Parse(r.text), "error", "details") || []) {
                for v in (Dig(det, "violations") || [])
                    if InStr(Dig(v, "quotaId"), "PerDay")
                        return AiTrack.NextQuotaDay()
                if (RegExMatch(Dig(det, "retryDelay"), "^([\d.]+)s$", &m) && m[1] > 0)
                    wait := Min(Max(Ceil(m[1]), 10), 300)
            }
        }
        return DateAdd(A_NowUTC, wait, "Seconds")
    }

    ; Cloudflare's 429: the day's neurons, until its day starts again; anything
    ; else for a minute. Busy or silent rests as Gemini's do.
    static CfRestUntil(r) {
        if (r.status != 429)
            return DateAdd(A_NowUTC, AiTrack.SlowRest, "Seconds")
        return RegExMatch(r.text, "i)neuron|daily") ? AiTrack.QuotaDay(AiTrack.CfModel)
            : DateAdd(A_NowUTC, 60, "Seconds")
    }

    ; when a model's free requests come back: Google's quota day, or
    ; Cloudflare's - midnight UTC
    static QuotaDay(m) => AiTrack.IsCf(m) ? SubStr(DateAdd(A_NowUTC, 1, "Days"), 1, 8) "000000" : AiTrack.NextQuotaDay()

    ; the next midnight in California, in UTC - when free quotas start again
    static NextQuotaDay(now := "") {
        now := (now = "") ? A_NowUTC : now
        midnight := DateAdd(SubStr(DateAdd(now, -AiTrack.Pacific(now), "Hours"), 1, 8), 1, "Days")
        ; the hours behind UTC at that midnight, not now: the night summer
        ; time ends, they differ
        summer := DateAdd(midnight, 7, "Hours")
        return (AiTrack.Pacific(summer) = 7) ? summer : DateAdd(midnight, 8, "Hours")
    }

    ; hours California is behind UTC at that moment: 7 in summer time - from
    ; the second Sunday of March, 2:00 there (10:00 UTC), to the first Sunday
    ; of November, 2:00 there (9:00 UTC) - 8 otherwise
    static Pacific(utc) {
        y := SubStr(utc, 1, 4)
        from := DateAdd(AiTrack.Sunday(y, 3, 2), 10, "Hours"), to := DateAdd(AiTrack.Sunday(y, 11, 1), 9, "Hours")
        return (DateDiff(utc, from, "Seconds") >= 0 && DateDiff(utc, to, "Seconds") < 0) ? 7 : 8
    }

    static Sunday(y, month, n) {                ; the nth Sunday of that month, YYYYMMDD
        first := y Format("{:02}", month) "01"
        return y Format("{:02}{:02}", month, 1 + Mod(8 - FormatTime(first, "WDay"), 7) + 7 * (n - 1))
    }

    ; "until 10:30", in this PC's own time
    static LocalTime(utc) => FormatTime(DateAdd(utc, DateDiff(A_Now, A_NowUTC, "Minutes"), "Minutes"), "HH:mm")

    ; a numbered Flash - not Flash-Lite, not an alias
    static IsFlash(m) => RegExMatch(m, "^gemini-\d+(\.\d+)?-flash$")

    ; gem, cf: which sides this lookup may ask
    static Models(gem := true, cf := false) {
        AiTrack.LoadState()
        chain := (gem && AiTrack.chain) ? AiTrack.chain.Clone() : []
        ; one Flash leads: the first in the list that is not resting. A
        ; resting Flash so hands its place to the next Flash, not to
        ; Flash-Lite - otherwise the other Flash would never be asked.
        for i, x in chain
            if (AiTrack.IsFlash(x) && !AiTrack.IsResting(x)) {
                chain.InsertAt(1, chain.RemoveAt(i))
                break
            }
        ; the ones picked in Settings lead, in their order - each only with
        ; its side's key
        picks := [], gemPick := false
        for p in AiPicks()
            if (AiTrack.IsCf(p) ? cf : gem)
                picks.Push(p), gemPick := gemPick || !AiTrack.IsCf(p)
        ; no list yet, and Cloudflare or a pick to fall back on: the guesses,
        ; rather than a wait for the list before anything is asked
        if (gem && !chain.Length && (cf || gemPick))
            chain := AiTrack.Guess.Clone()
        ; Cloudflare's tested model second - or first after the picks: it
        ; answers in seconds when Gemini is slow. Not when the day's list says
        ; it is gone, or paid now.
        if (cf && AiTrack.CfAuto())
            chain.InsertAt((picks.Length || !chain.Length) ? 1 : 2, AiTrack.CfModel)
        for i, p in picks
            chain.InsertAt(i, p)
        ; resting models last - asked only when no other is left, Flash-Lite
        ; first: it is the quickest to answer. Out of the day's quota last
        ; of all: it is sure to say no.
        out := [], lite := [], tired := [], spent := []
        for x in chain
            if !HasVal(out, x) && !HasVal(lite, x) && !HasVal(tired, x) && !HasVal(spent, x)
                (!AiTrack.IsResting(x) ? out : (AiTrack.resting[x] = AiTrack.QuotaDay(x)) ? spent
                    : InStr(x, "flash-lite") ? lite : tired).Push(x)
        for list in [lite, tired, spent]
            for x in list
                out.Push(x)
        return out
    }

    ListStep() {
        return {name: "Gemini models", kind: "list", url: AiTrack.Api "models?pageSize=1000"
            , opts: {timeout: 6000, headers: Map("x-goog-api-key", this.key)}
            , parse: ObjBindMethod(AiTrack, "PickModels")}
    }

    GenStep(model, after := 0) {
        if AiTrack.IsCf(model)
            return this.CfStep(model, after)
        think := ""
        if !this.noThink {
            if RegExMatch(model, "^gemini-2\.5-flash")
                think := Map("thinkingBudget", 512)
            else if RegExMatch(model, "^gemini-([3-9]|flash)")      ; flash-latest is a 3.x
                think := Map("thinkingLevel", "low")
        }
        cfg := Map("responseMimeType", "application/json", "temperature", 0.2)
        if IsObject(think)
            cfg["thinkingConfig"] := think
        body := KitJson.Dump(Map("contents", [Map("role", "user", "parts", [Map("text", AiTrack.Prompt(this.lk))])]
            , "generationConfig", cfg), "", true)
        return {name: "Gemini", kind: "gen", model: model, think: IsObject(think)
            , url: AiTrack.Api "models/" model ":generateContent", after: after
            , opts: {method: "POST", body: body, timeout: Max(3000, Min(AiTrack.Wait, this.Left))
                , headers: Map("x-goog-api-key", this.key, "Content-Type", "application/json")}
            , parse: ObjBindMethod(AiTrack, "Answer", this.lk.mode)}
    }

    ; Cloudflare: the same prompt, in OpenAI's shape. The first time a token is
    ; used, its account is asked for first (CfAccountOf) - the address needs it.
    CfStep(model, after := 0) {
        auth := Map("Authorization", "Bearer " this.cfToken, "Content-Type", "application/json")
        if (AiTrack.cfAccount = "" || AiTrack.cfFor != AiTrack.TokenEnd(this.cfToken))
            return {name: "Cloudflare account", kind: "cfacct", model: model, after: after
                , url: AiTrack.CfApi "accounts?per_page=5"
                , opts: {timeout: Max(3000, Min(8000, this.Left)), headers: auth}
                , parse: ObjBindMethod(AiTrack, "CfAccountOf")}
        req := Map("model", model, "temperature", 0.2, "max_tokens", 2000
            , "messages", [Map("role", "user", "content", AiTrack.Prompt(this.lk))])
        if InStr(model, "gpt-oss")                 ; it thinks before it answers; a little is enough
            req["reasoning_effort"] := "low"
        return {name: "Cloudflare", kind: "gen", model: model, think: false, after: after
            , url: AiTrack.CfApi "accounts/" AiTrack.cfAccount "/ai/v1/chat/completions"
            , opts: {method: "POST", body: KitJson.Dump(req, "", true), timeout: Max(3000, Min(AiTrack.Wait, this.Left))
                , headers: auth}
            , parse: ObjBindMethod(AiTrack, "Answer", this.lk.mode)}
    }

    static CfAccountOf(r) => Dig(KitJson.Parse(r.text), "result", 1, "id")

    ; The account a token reaches, kept with the token's end. A different
    ; token: its end date is not known yet.
    static CfKeep(acc, token) {
        if (AiTrack.cfFor != AiTrack.TokenEnd(token))
            AiTrack.cfEnds := ""
        AiTrack.cfAccount := acc, AiTrack.cfFor := AiTrack.TokenEnd(token), AiTrack.cfBad := ""
        AiTrack.SaveState()
    }

    ; WHEN THE TOKEN ENDS. A Cloudflare token can have an end date (the user's
    ; first was made for 90 days); after it, every request is turned down as if
    ; the token were wrong. So Vocab asks once per token, in the background,
    ; and the cards say so in the last two weeks (CfEndsNote). Two addresses:
    ; a token made under the account (the Workers AI template's, tested
    ; 2026-11-19) answers only at the account's; one made under the user, only
    ; at /user's. Each answers {"result": {"status", "expires_on"}}, with no
    ; expires_on when the token never ends. cfEnds: "" not known, "never", or
    ; the end in UTC, YYYYMMDDHHMISS.
    static CfVerifyUrls() => [AiTrack.CfApi "accounts/" AiTrack.cfAccount "/tokens/verify"
        , AiTrack.CfApi "user/tokens/verify"]

    static CfEndsOf(r) {
        if !r.Ok
            return ""
        try j := KitJson.Parse(r.text)
        catch
            return ""
        if !(Dig(j, "result") is Map)
            return ""
        e := Dig(j, "result", "expires_on")
        if (!(e is String) || e = "")                   ; left out, or null
            return "never"
        d := RegExReplace(e, "\D")                      ; 2027-02-14T20:29:59Z -> 20270214202959
        return (StrLen(d) >= 14 && IsTime(SubStr(d, 1, 14))) ? SubStr(d, 1, 14) : ""
    }

    ; once per token and run, in the background, when the account is known
    ; and the end is not
    static cfEndsAsking := false, cfEndsTried := ""
    static CfWarm() {
        AiTrack.LoadState()
        token := CloudflareToken()
        if (token = "" || AiTrack.cfEndsAsking || AiTrack.cfEnds != "" || AiTrack.cfAccount = ""
            || AiTrack.cfFor != AiTrack.TokenEnd(token) || AiTrack.cfEndsTried = AiTrack.TokenEnd(token))
            return
        AiTrack.cfEndsAsking := true, AiTrack.cfEndsTried := AiTrack.TokenEnd(token)
        opts := {timeout: 8000, headers: Map("Authorization", "Bearer " token)}
        q := {urls: AiTrack.CfVerifyUrls(), i: 1}         ; an object, so poll can move it on
        q.req := Http(q.urls[1], opts)
        poll() {
            if !q.req.Poll()
                return
            ends := AiTrack.CfEndsOf(q.req)
            if (ends = "" && q.i < q.urls.Length) {
                q.i += 1
                q.req := Http(q.urls[q.i], opts)
                return
            }
            SetTimer(poll, 0)
            AiTrack.CfWarmDone(ends, token)
        }
        SetTimer(poll, 200)
    }

    ; CLOUDFLARE'S MODELS. Its list says, for each model, whether it needs the
    ; paid plan (require_workers_paid) and when it is retired
    ; (planned_deprecation_date) - so the menus offer only free ones that are
    ; staying, without asking each. Of 41 text models on 2026-11-19, 9 were
    ; paid-only and 13 were retired the next day. Dropped too: add-on
    ; versions (lora), betas and alphas, the safety checker (guard) and the
    ; coding ones. 18 were left.
    ; The tested one first, then the newest. For people with other languages
    ; and other needs: Vocab tested only GPT-OSS-120B, for Persian.
    static PickCfModels(r) {
        soon := FormatTime(DateAdd(A_NowUTC, 7, "Days"), "yyyy-MM-dd")
        found := []
        for m in (Dig(KitJson.Parse(r.text), "result") || []) {
            name := Dig(m, "name")
            if (!AiTrack.IsModelName(name) || !AiTrack.IsCf(name) || RegExMatch(name, "i)lora|guard|coder|alpha"))
                continue
            if (Dig(m, "task", "name") != "" && Dig(m, "task", "name") != "Text Generation")
                continue
            p := Map()
            for prop in (Dig(m, "properties") || [])
                p[Dig(prop, "property_id")] := Dig(prop, "value")
            if (AiTrack.Yes(Dig(p, "require_workers_paid")) || AiTrack.Yes(Dig(p, "beta")))
                continue
            gone := Dig(p, "planned_deprecation_date")
            if (gone is String && gone != "" && StrCompare(gone, soon) <= 0)
                continue
            found.Push([String(Dig(m, "created_at")), name])
        }
        out := []
        for x in found
            if (x[2] = AiTrack.CfModel)
                out.Push(x[2])
        loop found.Length {                      ; newest first
            best := 0
            for i, x in found
                if (x[2] != AiTrack.CfModel && (!best || StrCompare(x[1], found[best][1]) > 0))
                    best := i
            if !best
                break
            out.Push(found.RemoveAt(best)[2])
        }
        return out
    }

    static Yes(v) => (v = "true" || v == 1)     ; a string in Cloudflare's list, or a JSON true

    ; Cloudflare's tested model in the automatic order - unless the day's
    ; list no longer has it (retired, or paid now)
    static CfAuto() => !(AiTrack.cfChain is Array && AiTrack.cfChain.Length && AiTrack.cfListed = FormatTime(A_NowUTC, "yyyyMMdd")
        && !HasVal(AiTrack.cfChain, AiTrack.CfModel))

    ; once a day, in the background, when the account is known
    static CfListWarm() {
        AiTrack.LoadState()
        token := CloudflareToken()
        if (token = "" || AiTrack.cfListing || AiTrack.cfListed = FormatTime(A_NowUTC, "yyyyMMdd")
            || AiTrack.cfAccount = "" || AiTrack.cfFor != AiTrack.TokenEnd(token))
            return
        AiTrack.cfListing := true
        req := Http(AiTrack.CfApi "accounts/" AiTrack.cfAccount "/ai/models/search?task=Text%20Generation&per_page=200"
            , {timeout: 10000, headers: Map("Authorization", "Bearer " token)})
        poll() {
            if !req.Poll()
                return
            SetTimer(poll, 0)
            AiTrack.cfListing := false
            if req.Ok
                try AiTrack.KeepCfList(AiTrack.PickCfModels(req))
        }
        SetTimer(poll, 200)
    }

    static KeepCfList(list) {
        if !list.Length                         ; an empty list is a fault, not news
            return
        AiTrack.cfChain := list, AiTrack.cfListed := FormatTime(A_NowUTC, "yyyyMMdd")
        AiTrack.SaveState()
        try ModelRow.Fill()                     ; Settings > Model, if it is open
    }

    ; what the background question found: kept, if it is still the same token
    static CfWarmDone(ends, token) {
        AiTrack.cfEndsAsking := false
        if (ends != "" && AiTrack.cfFor = AiTrack.TokenEnd(token)) {
            AiTrack.cfEnds := ends
            AiTrack.SaveState()
        }
    }

    ; "" - or, in the last two weeks of the token in Settings and after it,
    ; one line saying so, for the cards
    static CfEndsNote(token := "") {
        static SoonDays := 14
        AiTrack.LoadState()
        if (token = "")
            token := CloudflareToken()
        ends := AiTrack.cfEnds
        if (token = "" || !IsTime(ends) || AiTrack.cfFor != AiTrack.TokenEnd(token))
            return ""
        left := DateDiff(ends, A_NowUTC, "Seconds")
        if (left <= 0)
            return "Your Cloudflare token ended on " AiTrack.LocalDate(ends) " - click to make a new one"
        if (left <= SoonDays * 86400)
            return "Your Cloudflare token ends on " AiTrack.LocalDate(ends) " - click to make a new one"
        return ""
    }

    ; UTC YYYYMMDDHHMISS -> "14 Feb 2027", your own day. The month in English
    ; whatever Windows' language is.
    static LocalDate(utc) {
        static Months := ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
        t := DateAdd(utc, DateDiff(A_Now, A_NowUTC, "Minutes"), "Minutes")
        return Integer(SubStr(t, 7, 2)) " " Months[Integer(SubStr(t, 5, 2))] " " SubStr(t, 1, 4)
    }

    ; Did Cloudflare itself say no? Its refusals are JSON with a list of errors.
    static FromCf(r) {
        if r.Ok
            return true
        try {
            j := KitJson.Parse(r.text)
            return (j is Map) && (j.Has("errors") || j.Has("error"))
        }
        return false
    }

    ; a token Cloudflare does not know, or one without Workers AI on it
    static CfKeyError(r) => ((r.status = 401 || r.status = 403) && AiTrack.FromCf(r)
        && RegExMatch(r.text, "i)authenticat|unauthori|invalid api token|not entitled"))

    ; a model of Cloudflare's that the free plan does not cover
    static NotFree(r) => (r.status = 403 && InStr(r.text, "Workers Free plan"))

    ; the next request, unless the time for all of them is up
    ; what a model's answer meant, for the waiting line
    static Said(m, r) {
        if (r.status = 429 || r.status = 503 || r.status = 504)
            return AiTrack.Why(m)
        return AiTrack.Short(m) (r.Ok ? " gave no usable answer"
            : AiTrack.NotFree(r) ? " is not free any more"
            : (r.status = 404) ? " is no longer offered"
            : (r.err = "timed out") ? " did not answer in time"
            : (r.err != "") ? ": no connection"
            : " failed (" r.Why ")")
    }

    Next(step, status := "") {
        if (this.Left < 3000) {
            this.note := "no answer in " this.budget // 1000 " s - look up again"
            return this.Finish()
        }
        this.steps := [step]
        if (status != "")
            this.status := status
        return (status != "")                  ; true: the card redraws its waiting line
    }

    ; Which model after one that said no: the first in the list not asked yet
    ; and not resting - resting ones are only asked when nothing else is
    ; left, in the order Models put them, and never one out of its day's
    ; quota: that one is sure to say no again. Flash-Lite stands before the other
    ; Flash in the list, so a slow Flash is followed by Flash-Lite. But a
    ; Flash that said no at once (a reply, not a wait) leaves time for one
    ; more Flash, when Flash-Lite would still have Spare ms after its Wait.
    ; With Cloudflare still to ask, it comes before a second Flash: it answers
    ; in seconds.
    NextModel(s := "", r := "") {
        if (this.asked.Count >= this.tries) {    ; Settings > Try up to
            this.capped := true
            return ""
        }
        cfLeft := false
        for m in this.models
            if (AiTrack.IsCf(m) && !this.asked.Has(m) && !AiTrack.IsResting(m))
                cfLeft := true
        if (IsObject(r) && r.status && !cfLeft && AiTrack.IsFlash(s.model) && this.Left >= AiTrack.Wait + AiTrack.Spare)
            for m in this.models
                if (AiTrack.IsFlash(m) && !this.asked.Has(m) && !AiTrack.IsResting(m))
                    return m
        for m in this.models
            if (!this.asked.Has(m) && !AiTrack.IsResting(m))
                return m
        for m in this.models
            if (!this.asked.Has(m) && AiTrack.resting.Has(m) && AiTrack.resting[m] != AiTrack.QuotaDay(m))
                return m
        return ""
    }

    ; One side cannot be used for this lookup - its key turned down, not
    ; offered where you are, not reached: the other side is asked, if there
    ; is one; otherwise why goes on the card.
    Elsewhere(cf, why) {
        keep := []
        for m in this.models
            if (AiTrack.IsCf(m) != cf)
                keep.Push(m)
        this.models := keep
        if ((m := this.NextModel()) != "")
            return this.Next(this.GenStep(m), why ", trying " AiTrack.Short(m))
        this.note := why
        return this.Finish()
    }

    Got(s, r, result) {
        cf := s.HasProp("model") && AiTrack.IsCf(s.model)
        msg := r.Ok ? "" : AiTrack.ErrMsg(r)
        if (cf ? AiTrack.CfKeyError(r) : AiTrack.IsKeyError(r, msg)) {
            if cf
                AiTrack.cfBad := this.cfToken, this.cf := false
            else
                AiTrack.keyBad := this.key, this.gem := false
            return this.Elsewhere(cf, (this.gem || this.cf)
                ? (cf ? "Cloudflare" : "Gemini") " key rejected" : "key rejected - check it in Settings")
        }
        if (!cf && InStr(msg, "location is not supported"))
            return this.Elsewhere(cf, "Gemini is not offered in your region")
        if (s.kind = "list") {
            if result
                AiTrack.KeepList(result)
            this.models := AiTrack.Models()
            if !this.models.Length
                this.models := AiTrack.Guess.Clone()
            this.steps := [this.GenStep(this.models[1])]
            return false
        }
        if (s.kind = "cfacct" && result) {     ; the token's account: now the question itself
            AiTrack.CfKeep(result, this.cfToken)
            AiTrack.CfWarm()                    ; and, beside it, when the token ends
            AiTrack.CfListWarm()                ; and its free models, for Settings
            this.steps := [this.GenStep(s.model)]
            return false
        }
        this.asked[s.model] := true
        if result {
            if AiTrack.resting.Has(s.model) {   ; asked as the last one left, and it answered
                AiTrack.resting.Delete(s.model)
                AiTrack.SaveState()
            }
            this.Take(s, result)
            this.source := cf ? "Cloudflare " RegExReplace(s.model, "^.*/") : "Gemini " RegExReplace(s.model, "^gemini-")
            return this.Finish()
        }
        ; the VPN or proxy, or Google's block page where Gemini is not
        ; offered: no model of that side is reached that way, so none rests
        ; and only the other side, if there is one, is tried
        if (r.status && !(cf ? AiTrack.FromCf(r) : AiTrack.FromGoogle(r)))
            return this.Elsewhere(cf, (cf ? "Cloudflare" : "Gemini") " not reached (HTTP " r.status " from the network) - check the VPN or proxy")
        if (r.status = 400 && s.think && !this.noThink) {
            this.noThink := true
            return this.Next(this.GenStep(s.model))
        }
        ; no connection at all (not a timeout, not an answer): once more, the
        ; same model, a second later - the first try is what some networks drop
        if (r.err != "" && r.err != "timed out" && !r.status && !this.retried.Has(s.model)) {
            this.retried[s.model] := true
            return this.Next(this.GenStep(s.model, A_TickCount + 1000), "could not connect, asked again")
        }
        ; Silent for the whole Wait rests it too - but not when the time left
        ; for the lookup cut its wait short: it never had a fair chance.
        if (r.status = 429 || r.status = 503 || r.status = 504
            || (r.err = "timed out" && s.opts.timeout >= AiTrack.Wait)) {
            AiTrack.resting[s.model] := cf ? AiTrack.CfRestUntil(r) : AiTrack.RestUntil(r)
            ; Cloudflare's day is one allowance for all its models: used up,
            ; every one picked would only say no again, a try each
            if (cf && AiTrack.resting[s.model] = AiTrack.QuotaDay(s.model))
                for m in this.models
                    if AiTrack.IsCf(m)
                        AiTrack.resting[m] := AiTrack.resting[s.model]
            AiTrack.SaveState()
        }
        ; paid only now (the day's list had it free): not again today
        if (cf && AiTrack.NotFree(r)) {
            AiTrack.resting[s.model] := AiTrack.QuotaDay(s.model)
            AiTrack.SaveState()
        }
        ; a model Google retired: a new list next time. Not one picked in
        ; Settings - the list does not hold it - and not Cloudflare's.
        if (r.status = 404 && !cf && !HasVal(AiPicks(), s.model)) {
            AiTrack.chain := "", AiTrack.listed := ""
            AiTrack.SaveState()
        }
        ; Cloudflare's answer unusable: Gemini may still have one
        if (r.status = 429 || r.status = 404 || r.status = 403 || r.status >= 500 || r.err != "" || (cf && r.Ok))
            if ((m := this.NextModel(s, r)) != "")
                return this.Next(this.GenStep(m), AiTrack.Said(s.model, r) ", trying " AiTrack.Short(m))
        this.note := (r.status = 429) ? AiTrack.QuotaNote()
                   : (r.status = 503 || r.status = 504 || r.err = "timed out") ? AiTrack.Said(s.model, r)
                   : r.Ok ? "no usable answer"
                   : (msg != "") ? Http.Short(msg) : r.Why
        if this.capped                          ; it stopped because of Try up to, not for want of models
            this.note .= " - " this.asked.Count " models asked, none answered"
        return this.Finish()
    }

    ; out of free quota everywhere: until when, if it is more than a moment
    static QuotaNote() {
        soonest := ""
        for m, till in AiTrack.resting
            if (AiTrack.IsResting(m) && (soonest = "" || DateDiff(till, soonest, "Seconds") < 0))
                soonest := till
        return (soonest != "" && DateDiff(soonest, A_NowUTC, "Minutes") >= 10)
            ? "free quota used up until " AiTrack.LocalTime(soonest) : "free quota used up for now"
    }

    ; A whole sentence, for someone reading a game or a blog: what it says in
    ; plain English, and a translation that reads naturally rather than
    ; word by word.
    static SentencePrompt(lk) {
        return "You help a native " Lang.PromptName() " speaker who is learning English.`n`n"
            . "This text - one sentence, or a few short ones that belong together, like a line"
            . " of dialogue - was read off their screen, so it may contain small recognition"
            . " errors or be cut short at either end:`n"
            . Chr(34) lk.word Chr(34) "`n`n"
            . "Reply with JSON only, with exactly these keys:`n"
            . '{"fixed": "", "simple": "", "translation": "", "note": ""}' "`n`n"
            . "fixed: the text with obvious recognition errors repaired; empty if it"
            . " already reads correctly`n"
            . "simple: what it means, in simple English, one or two short sentences`n"
            . "translation: a natural " Lang.PromptName() " translation - how a native speaker would say it,"
            . " not word for word`n"
            . "note: an idiom, a joke, slang or a reference worth a few words of explanation;"
            . " otherwise empty"
            . "`n`n" AiTrack.Likeliest
    }

    ; Small models pick the harmless reading of a dark line ("Why Are We So
    ; Bad at Executing People?" came back as carrying out plans) even when
    ; their own note names the real one. Tested on 40 saved words and
    ; sentences: no answer got worse for it (docs\decisions.md).
    static Likeliest := "Give the most likely meaning, even when the topic is dark or violent; do not soften it."
        . " If it could mean two things, give the likelier one and mention the other in the note."

    ; A note, a blog paragraph, a page of patch notes: what does it actually
    ; say. Short, and in both languages - a little longer for a long text.
    ; The second language explains rather than translates: asked for "the
    ; same summary in natural Persian", Gemini wrote formal Persian and
    ; turned names into Persian words, which hides what the text is about.
    static ParagraphPrompt(lk) {
        size := (StrLen(lk.word) > SummaryLongChars())
            ? "five or six short sentences, so its main points are all there"
            : "two or three short sentences"
        return "You help a native " Lang.PromptName() " speaker who is learning English.`n`n"
            . "This text was read off their screen, so it may contain recognition errors, and"
            . " lines belonging to other things on screen may have crept in:`n"
            . Chr(34) lk.word Chr(34) "`n`n"
            . "Reply with JSON only, with exactly these keys:`n"
            . '{"summary": "", "translation": "", "note": ""}' "`n`n"
            . "summary: what this text says, in simple English, " size "."
            . " Ignore anything that clearly belongs to something else on the screen`n"
            . "translation: the same summary in everyday " Lang.PromptName() ", the way a "
            . Lang.PromptName() " speaker would explain it to a friend - not formal or literary."
            . " Keep names of people, places, games, products and companies, and technical terms,"
            . " in English as written; do not translate them`n"
            . "note: a name, a term or a reference worth a few words; otherwise empty"
    }

    static IsKeyError(r, msg) {
        return (r.status = 400 || r.status = 401 || r.status = 403)
            && (InStr(msg, "API key") || InStr(msg, "API_KEY"))
    }

    ; the reason in a refusal: Google's {"error": {"message"}}, or
    ; Cloudflare's {"errors": [{"message"}]}
    static ErrMsg(r) {
        try {
            j := KitJson.Parse(r.text)
            m := Dig(j, "error", "message")
            return (m != "") ? m : Dig(j, "errors", 1, "message")
        }
        return ""
    }

    ; Did Gemini itself say this? Its refusals are JSON that repeat the
    ; status: {"error": {"code": 503, ...}}. A VPN or proxy that cannot get
    ; through answers 502/503/504 of its own, and Google's front door in a
    ; blocked country 403 - as a web page.
    static FromGoogle(r) {
        if r.Ok
            return true
        try return Dig(KitJson.Parse(r.text), "error", "code") = r.status
        return false
    }

    static PickModels(r) {
        flash := [], lite := []
        for m in (Dig(KitJson.Parse(r.text), "models") || []) {
            name := StrReplace(Dig(m, "name"), "models/")
            if !HasVal(Dig(m, "supportedGenerationMethods") || [], "generateContent")
                continue
            if RegExMatch(name, "^gemini-(\d+(?:\.\d+)?)-flash$", &v)
                AiTrack.Insert(flash, Float(v[1]), name)
            else if RegExMatch(name, "^gemini-(\d+(?:\.\d+)?)-flash-lite$", &v)
                AiTrack.Insert(lite, Float(v[1]), name)
        }
        ; second-newest Flash, two Flash-Lite, then the third Flash and the
        ; newest - which leads only when it is the one Flash there is
        chain := []
        if flash.Length
            chain.Push(flash[Min(2, flash.Length)][2])
        for i, x in lite
            if (i <= 2)
                chain.Push(x[2])
        for i in [3, 1]
            if (i <= flash.Length && !HasVal(chain, flash[i][2]))
                chain.Push(flash[i][2])
        for x in AiTrack.Guess
            if !HasVal(chain, x)
                chain.Push(x)
        return chain
    }

    static Insert(list, ver, name) {         ; newest first
        for i, x in list
            if (ver > x[1]) {
                list.InsertAt(i, [ver, name])
                return
            }
        list.Push([ver, name])
    }

    static Answer(mode, r) {
        d := KitJson.Parse(r.text)
        txt := Dig(d, "choices", 1, "message", "content")      ; Cloudflare (OpenAI's shape)
        if IsObject(txt)
            txt := ""
        for p in (Dig(d, "candidates", 1, "content", "parts") || [])     ; Gemini
            if !Dig(p, "thought")
                txt .= Dig(p, "text")
        a := InStr(txt, "{"), b := InStr(txt, "}", , -1)
        if (!a || b < a)
            return ""
        j := KitJson.Parse(SubStr(txt, a, b - a + 1))
        if !(j is Map)
            return ""
        if IsCheck(mode)
            return AiTrack.CheckAnswer(j)
        out := Map()
        keys := (mode = "sentence") ? ["fixed", "simple", "translation", "note"]
             : (mode = "paragraph") ? ["summary", "translation", "note"]
             : ["lemma", "pos", "meaning", "translation", "note", "example", "corrected"]
        for k in keys {
            v := Dig(j, k)
            out[k] := Trim((v is Array) ? Join(v, Lang.Sep()) : IsObject(v) ? "" : String(v))
        }
        out["persian"] := Lang.Mend(out.Delete("translation"))     ; its name everywhere else - see Language.ahk
        if (mode = "sentence")
            return (out["simple"] = "" && out["persian"] = "") ? "" : out
        if (mode = "paragraph")
            return (out["summary"] = "" && out["persian"] = "") ? "" : out
        return (out["meaning"] = "") ? "" : out
    }

    ; Check my English (Check.ahk): every key always there, points a list
    static CheckAnswer(j) {
        out := Map()
        for k in ["better", "reader", "pattern", "pattern_use", "pattern_example"] {
            v := Dig(j, k)
            out[k] := Trim(IsObject(v) ? "" : String(v))
        }
        pts := []
        for p in ((Dig(j, "points") is Array) ? j["points"] : [])
            if (!IsObject(p) && Trim(p) != "")
                pts.Push(Trim(p))
        out["points"] := pts
        return (out["better"] = "" && !pts.Length) ? "" : out
    }

    ; Rewrite first, teach after: Gemini rewrites the text the way it thinks
    ; is right - natural (lk.mode "check") or formal ("formal") - and then
    ; explains each change. Nothing tells it what not to change: the old
    ; prompt's limits made it invent mistakes and patterns (docs\decisions.md).
    static CheckPrompt(lk) {
        word := (lk.context != "" || CountWords(lk.word) = 1)
        q := Chr(34)
        how := (lk.mode = "formal")
            ? "formal: the way a native speaker would write it in a formal or professional setting, like an email to a manager, a client or a teacher"
            : "natural: the way a native speaker would naturally say it in everyday conversation or chat - colloquial, not formal"
        p := "You help a native " Lang.PromptName() " speaker who writes in English as a second language.`n`n"
        if !word
            p .= "Rewrite their text so it is correct and " how ". Fix grammar, word choice and idioms - change"
                . " whatever you think should change. Keep what they mean and their line breaks.`n`n"
                . "Their text:`n" q lk.word q "`n`n"
        else if (lk.context != "")
            p .= "They are unsure about the word " q lk.word q " in this sentence they wrote. Rewrite the sentence"
                . " so it is correct and " how ", and say whether that word was right.`n`n"
                . "Their sentence:`n" q lk.context q "`n`n"
        else
            p .= "They are unsure about the word " q lk.word q "; the sentence around it is not available. Say"
                . " whether it is a real, correctly spelled word, and give the right one if not.`n`n"
        return p . "Then teach them: they will compare your version with theirs and want to learn why yours is better.`n`n"
            . "Reply with JSON only, with exactly these keys:`n"
            . '{"better": "", "points": [], "reader": "", "pattern": "", "pattern_use": "", "pattern_example": ""}' "`n`n"
            . "better: your version. If nothing should change, their " (word ? "sentence" : "text") " exactly as it was`n"
            . "points: one short string for each change worth learning, " q "what they wrote -> what you wrote: why" q ","
            . " in simple English. Put spelling, capital letters and punctuation together in one point. Empty when nothing changed`n"
            . "reader: only if their original could be misunderstood, what a reader would think it means, in one sentence;"
            . " otherwise empty`n"
            . "pattern: the most useful phrase or sentence pattern in your version to learn and reuse, with the"
            . " changing part in brackets (for example " q "I can't tell whether [X] or [Y]" q ") - only if one of your"
            . " changes really teaches one; otherwise empty`n"
            . "pattern_use: when to use it, in a few words`n"
            . "pattern_example: one short new example sentence using it, correct and " ((lk.mode = "formal") ? "formal" : "natural")
    }

    static Prompt(lk) {
        if IsCheck(lk.mode)
            return AiTrack.CheckPrompt(lk)
        if (lk.mode = "sentence")
            return AiTrack.SentencePrompt(lk)
        if (lk.mode = "paragraph")
            return AiTrack.ParagraphPrompt(lk)
        ctx := Trim(lk.context)
        p := "You help a native " Lang.PromptName() " speaker who is learning English understand words they meet on screen.`n`n"
        p .= 'Word or phrase: "' lk.word '"`n'
        if (ctx != "")
            p .= 'Where they saw it (screen text read by OCR, may contain recognition errors): "' ctx '"`n'
        else
            p .= "No sentence is available, so explain its most common meaning.`n"
        p .= "`nReply with JSON only, with exactly these keys:`n"
            . '{"corrected": "", "lemma": "", "pos": "", "meaning": "", "translation": "", "note": "", "example": ""}' "`n`n"
            . "corrected: the word itself is read off the screen and can come back damaged - a"
            . " letter lost to a highlight box, or two words run together. If it is clearly a"
            . " misreading of a word in the sentence, put the correct word here and answer"
            . " about THAT word; otherwise leave it empty`n"
            . "lemma: the dictionary form of the word, or the phrasal verb or idiom it belongs to here`n"
            . "pos: its part of speech here`n"
            . "meaning: the meaning" ((ctx != "") ? " used in THIS sentence" : "") ", in simple English, at most 20 words`n"
            . "translation: the natural " Lang.PromptName() " equivalent of that meaning, 1 to 4 words, written in " Lang.Cur().name "`n"
            . "note: if it is part of an idiom, a phrasal verb or slang here, say so in a few words; otherwise empty`n"
            . "example: " ((ctx != "") ? "the sentence with obvious OCR errors fixed, or empty if it is not a real sentence"
                                       : "one short natural example sentence")
            . "`n`n" AiTrack.Likeliest
        return p
    }
}
