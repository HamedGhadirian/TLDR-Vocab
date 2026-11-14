;================================================================================
; Updater.ahk - a bridge for copies older than 1.4.0. Nothing runs it.
;================================================================================
; The helper that swaps the files during an update is the kit's now:
; lib\Kit\Updater.ahk. This file stays only because TLDR Vocab 1.2 to 1.3
; check that a new version has lib\Updater.ahk and lib\Swap.ahk before they
; update to it - without both, "Update now" would refuse 1.4 and send them
; to the download page. Those copies run their own helper, from their own
; folder; they only look for this name. Keep it (and lib\Swap.ahk) in every
; release; tests\Logic.test.ahk checks that they are there.
;
; All.ahk does not include it.
;================================================================================
#Requires AutoHotkey v2.0
