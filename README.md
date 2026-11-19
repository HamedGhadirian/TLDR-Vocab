# TLDR Vocab

**Point at any English text on your screen - a game, a paused video, a web page - and get the meaning, the pronunciation and a translation.**

It reads the screen itself (Windows' own OCR), so it works on anything you can see, not only on text you
can select. Made for learning English while you use it. English → Persian by default, or 18 other
languages (Settings → Translation).

AutoHotkey v2 · Windows 10 and 11 · no account, no tracking

![A word looked up on a web page: meaning, pronunciation, the meaning that fits the sentence, and the translation](https://raw.githubusercontent.com/HamedGhadirian/TLDR-Vocab/main/docs/images/word.png)

## How to use it

| Keys | What it does |
|---|---|
| **Win + Click** | The word you click on: meaning, pronunciation, translation, and the meaning that fits its sentence. |
| **Shift + Win + middle-click** | **Translate** the sentences around the one you click, in plain English and in your language. |
| **Ctrl + Win + middle-click** | **Summary** of the whole block of text under the mouse, in both languages. |
| **Win + `** | Whatever text is selected (\` is the key left of 1). |
| **Ctrl + Win + `** | **Check my English** on something *you* wrote. |
| **Shift + Win + `** | Draw a box: the screen freezes, drag over the text. Good for tooltips that vanish. |
| **Win + F7** | Your saved word list. **Esc** or a click outside closes a card. |

Every key can be changed or switched off in Settings. **+ save** on a card keeps the word in your list;
the pin keeps a card on screen.

![The Translate card: the sentences taken, the same thing in simple English, and the translation](https://raw.githubusercontent.com/HamedGhadirian/TLDR-Vocab/main/docs/images/translate.png)

<details>
<summary><b>Check my English</b></summary>

Select something you wrote - a chat message, an email - and press **Ctrl + Win + `** (needs Gemini).
The card shows your text rewritten the way a native speaker would say it, the changed words in green,
and one short line for each change saying why. **NATURAL | FORMAL** at the top switches between
everyday and formal English. When a change teaches a phrase you can use again, **+ save** keeps it.
Your own text is never changed; **copy** puts the rewrite on the clipboard.

Select a single word to ask "is this word right here?".

</details>

<details>
<summary><b>Summary and the word list</b> (pictures)</summary>

![The Summary card: a paragraph in simple English, its translation, and what the screen reading actually read](https://raw.githubusercontent.com/HamedGhadirian/TLDR-Vocab/main/docs/images/summary.png)

![The word list: saved words with their translations, and everything kept for the one picked](https://raw.githubusercontent.com/HamedGhadirian/TLDR-Vocab/main/docs/images/wordlist.png)

</details>

## Download

From the [latest release](https://github.com/HamedGhadirian/TLDR-Vocab/releases/latest):

| File | For |
|---|---|
| `TLDR-Vocab-x.y.z-portable.zip` | **Most people.** Unzip anywhere, run `Start TLDR Vocab.bat`. Nothing to install. |
| `TLDR-Vocab-x.y.z.zip` | If you already have [AutoHotkey v2](https://www.autohotkey.com/download/): unzip, run `Vocab.ahk`. |

A dictionary icon shows up in the tray. Double-click it for your word list; right-click it for
**Settings**, **Start with Windows**, **Run as administrator**, **Look for updates now** and **Help**.

## Settings

Tray icon > **Settings**. Everything is saved the moment you change it and works at once.

- **General**: dark or light theme, Start with Windows, Run as administrator, the update check.
- **Keys**: click **change** next to one and press the keys you want.
- **Translation**: the language, and how much Translate takes.
- **AI** (optional, free): without a key, words, translations and pronunciation all work. With one
  you also get sentences explained, summaries, the meaning that fits the sentence and Check my English.
  One key is enough, either of these two; with both, each one stands in when the other is slow or blocked:
  - **Gemini**: click **get a free key**, sign in with Google, paste it, click **test**.
  - **Cloudflare** (works where Gemini is blocked): click **get a free token**, sign up, press
    **Create Token**, use the **Workers AI** template, paste it, click **test**. A token can have an
    end date; **test** shows it, and the cards remind you in its last two weeks.
  - **Ask first**: leave it on Automatic, or pick the model to ask first. The two **Then** lists take
    a second and a third ("Automatic from here" takes one away); after them comes the automatic order. The lists update themselves. Cloudflare
    models marked **not tested** may answer wrongly in some languages without any error, so check them.
  - **Try up to**: how many models one lookup asks before it gives up (3 unless you change it).

  Keys stay on your PC.
- **Network**: an HTTP proxy, if you need one. **Sound**: say each word out loud.

It's all in `Vocab.ini` beside the script too, if you'd rather edit a file.

![Settings: the language, the Gemini key, the proxy, and every key shown with a change button](https://raw.githubusercontent.com/HamedGhadirian/TLDR-Vocab/main/docs/images/settings.png)

## Good to know

- **Where the answers come from**: freedictionaryapi.com, Wiktionary and Datamuse for definitions;
  Google Translate's free web addresses (with Lingva and MyMemory as fallbacks) for translations and
  the spoken words; Gemini or Cloudflare Workers AI, with your key, for explanations. The Google addresses aren't an official
  service, so they could change one day - the fallbacks take over.
- **Updates**: once a day it asks GitHub whether there's a newer version. **Update now** swaps the files
  in about ten seconds and keeps your words and settings; the old version stays in `previous version\`.
  Nothing installs without your click. Updating with one click works from 1.2.0 on.
- **Your files** stay in its own folder: `words.json` (your words, plain JSON), daily copies in
  `backups\`, `Vocab.ini`, and a `cache\` that makes repeats instant. To remove it, untick Start with
  Windows, quit, delete the folder.
- **Run as administrator** is only needed for the selection key in programs that run as administrator.
- **Exclusive-fullscreen games** can't show the card - use borderless or windowed fullscreen.
- The screen reading is English only.

## The code

`Vocab.ahk` only starts things; the app is in `lib\` (`lib\All.ahk` lists what each file does). The
settings window, tray menu, keys, Start with Windows and updates come from `lib\Kit`, shared by a small
family of apps. Tests: `tests\run-tests.ps1`. Why things are the way they are: `docs\decisions.md`.

Design and direction: **HamedGhadirian**. Code written with Claude (Anthropic). Testing and feedback:
[life2088](https://github.com/life2088) - thank you. Icon: [Dictionary icons created by Magnific - Flaticon](https://www.flaticon.com/free-icons/dictionary).
The portable zip includes [AutoHotkey](https://github.com/AutoHotkey/AutoHotkey) 2.0 (GNU GPL v2, see
`AutoHotkey license.txt` in that zip).

MIT - see [LICENSE](LICENSE).
