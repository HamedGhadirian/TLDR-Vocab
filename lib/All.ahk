;================================================================================
; All.ahk - every part of Vocab, in the order they load
;================================================================================
; Vocab.ahk includes this, and so do the tests in tests\ - one list, so the
; two can never disagree about what the app is made of.
;
;   Kit        what every script of the family shares, a copy of the master
;              (lib\Kit\Kit.ahk lists its parts): the settings window, the
;              keys, the tray menu, Start with Windows, administrator, the
;              theme, updates, JSON, web requests
;   Config     what is set in the script: version, keys, settings rows, the
;              first Vocab.ini, icon, colours, sizes
;   Language   the language translations go into
;   Lookup     the sources: dictionaries, translators, Gemini, and the cache
;   OcrWindows Windows' own OCR - the engine Ocr uses
;   Ocr        reading a piece of the screen, whichever engine reads it
;   Lines      turning OCR output into lines of text on a page
;   Speak      hearing the word
;   App        starting up, the tray items, the icon, starting a lookup
;   Word       the word under the mouse, and the selected text
;   Store      your dictionary, words.json
;   Cards      drawing a lookup or a saved word
;   Popup      the lookup popup
;   WordList   the dictionary window
;   Sentence   the Translate card
;   Paragraph  the Summary card
;   Box        drawing a box to read
;   Check      Check my English: your own text, checked
;   Settings   Vocab's own part of the settings window: the Gemini key
;
; Not included: lib\Kit\Updater.ahk, the helper an update starts to swap the
; files while the app is closed - a script of its own.
;================================================================================
#Requires AutoHotkey v2.0
#Include %A_LineFile%\..\Kit\Kit.ahk
#Include %A_LineFile%\..\Config.ahk
#Include %A_LineFile%\..\Language.ahk
#Include %A_LineFile%\..\Lookup.ahk
#Include %A_LineFile%\..\OcrWindows.ahk
#Include %A_LineFile%\..\Ocr.ahk
#Include %A_LineFile%\..\Lines.ahk
#Include %A_LineFile%\..\Speak.ahk
#Include %A_LineFile%\..\App.ahk
#Include %A_LineFile%\..\Word.ahk
#Include %A_LineFile%\..\Store.ahk
#Include %A_LineFile%\..\Cards.ahk
#Include %A_LineFile%\..\Popup.ahk
#Include %A_LineFile%\..\WordList.ahk
#Include %A_LineFile%\..\Sentence.ahk
#Include %A_LineFile%\..\Paragraph.ahk
#Include %A_LineFile%\..\Box.ahk
#Include %A_LineFile%\..\Check.ahk
#Include %A_LineFile%\..\Settings.ahk
