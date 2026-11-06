# Compatibility

Which apps NextTyped works in, which need a setting, which do not work, and which nobody has measured. The same facts appear in Settings → Setup under "Where it works" (`SupportListSection`, backed by `AppCoverageLimits` in Core). This file also ships inside the app and opens from Settings → About → Help.

NextTyped reads text through the macOS Accessibility API. It works in an app only as far as that app shares its text and the caret position through that API. Every row below names its coverage mode and the evidence with a date. An app with no evidence is under "Untested", never under "Works". Accepted limits are disclosed, not hidden.

## Coverage modes

| Mode | What you see |
| --- | --- |
| Inline | The ghost text sits at the caret in the host's own font and size. |
| Sized from the line | The host reports no font, so the ghost size comes from the height of the line. |
| Bubble | When the completion would cover text or wrap, the ghost shows in a bubble below the line. |
| No text | The host shares no text through Accessibility, so no completion runs. |

## Works

| App and field | Mode | Evidence |
| --- | --- | --- |
| TextEdit | Inline | Automated end-to-end scenarios (accept one word, accept all with ⌥Tab, spelling fix, emoji after a colon) run in TextEdit. 61 of 63 scenarios passed on 2026-10-28; the two failures were not about TextEdit coverage. |
| Safari, multi-line form fields (`<textarea>`) | Inline | Checked by hand on 2026-07-03. No automated scenario. |

## Sized from the line, or bubble

| App and field | Mode | Reason | Evidence |
| --- | --- | --- | --- |
| Apple Notes | Sized from the line | Notes shares value and caret position but no per-character font. | Checked by hand on 2026-06-20 and 2026-07-03. The end-of-field overlap check passed on 2026-08-28. No automated scenario. |
| claude.ai in Safari | Sized from the line | The page shares no per-character font. | Checked by hand on 2026-07-10, with reply context. The end-of-field overlap check passed on 2026-08-28. No automated scenario. |
| Claude Desktop (Electron) | Sized from the line, bubble on wrap | The app returns a constant, empty caret rectangle for the usual range query. NextTyped switches on the app's accessibility tree and reads the caret from the WebKit text markers instead. The marker line carries no font. | Five automated scenarios (bubble on wrap, ⌘-arrow clears the ghost, mid-text bubble, split inline overflow, Tab accept) passed in late August 2026. Reply context in Claude Desktop is not covered by an automated run. |

## Needs a setting

| App | Setting | Evidence |
| --- | --- | --- |
| Terminals (Terminal, iTerm2, Warp, Alacritty, kitty) | Off by default, because the shell uses `Tab` for its own completion. Switch it on per app: Settings → Apps, find the terminal, set "Completions in <app>" to "On". | The default and the per-app switch are in `AppCoverageLimits` and the Apps pane. An automated scenario checks the switch in TextEdit. Nobody has run a completion in a terminal, so what you get there is untested. |

## Does not work

| App and field | Reason | Evidence |
| --- | --- | --- |
| Mail, compose body | The compose body is a web area that shares no text through Accessibility (`valueLen=0`, no caret range). Reading it through text markers is not built. | Checked by hand. Confirmed gap, not fixed. |
| Electron apps with little text: VS Code, Slack, Notion, Discord | These apps are listed as exposing little usable text through Accessibility. | Listed in `AppCoverageLimits`. The claim has not been measured yet, so treat it as a known risk, not a result. |
| Right-to-left text (Hebrew, Arabic and similar) | In a paragraph that contains such text the app shows no suggestion and no correction. | An automated scenario checks it. |
| Search bars, address bars and one-line form fields | Only spelling fixes run. Word completions are off in single-line fields. | Setup support list, `FieldSizeGate`. |
| Password and other secure fields | Never read, by design. | `SecureInputPolicy` in Core. |

## Untested

Nobody has measured these. Do not read their absence from the lists above as a failure or a pass.

- Google Chrome. It needs an accessibility flag, and the flag path has not been run.
- Dia and other Chromium-based browsers.
- Microsoft Word and the rest of Office.
- Every app not named on this page.

A host moves out of "Untested" only after a run on this build.
