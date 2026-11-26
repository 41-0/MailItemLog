# Changelog

## 0.7.10

- Moved the Return RTS button up by 7 UI units.

## 0.7.9

- Moved the Return RTS button down by one button height.

## 0.7.8

- Added mailbox-open and manual-button startup timings to `/milrtstime`.

## 0.7.7

- Keep the fast RTS interval when the inbox confirms a return despite a mail failure notification. Use backoff when a return remains unconfirmed and needs a retry.

## 0.7.6

- Skip unrelated attachment reads and defer saved inbox display updates during RTS batches.
- Added optional batch timing via `/milrtstime`.

## 0.7.5

- Send the next RTS return as soon as the previous one is confirmed and the short minimum interval has elapsed. Use the longer interval for the rest of the batch if a mail failure is reported.

## 0.7.4

- Verify the inbox after a mail failure event before stopping an RTS batch. Retry an explicitly failed return once if the same mail is still eligible.
- Leave a longer interval between RTS requests.

## 0.7.3

- Request one mailbox refresh if a return has yet to appear in the cached inbox.
- Allow batch confirmation when an unrelated RTS message has uncached details, and report why a batch stops.

## 0.7.2

- Continue RTS batches after each returned message is confirmed, even if an inbox update event is missing or another RTS message arrives in the meantime.

## 0.7.1

- Stop a failing mailbox scan and report the original error once in chat. Reopening the mailbox allows another scan.
- Guard the frame update against missing elapsed time.

## 0.7.0

- Split the GUI and each mail feature into separate Lua files.
- Coalesced mailbox updates and spread inbox reads and RTS history checks across frames.
- Revalidated RTS return candidates before use and canceled pending scans when the mailbox closes.

## 0.6.3

- Added a Clear All button for saved inbox lists.

## 0.6.2

- Added item icons and quality-colored names to all four tabs.
- Added optional item appearance data to inbox sharing, with support for older clients of the addon.

## 0.6.1

- Added a short RTS usage guide beside the settings.

## 0.6.0

- Added the RTS tab with sent RTS history and mailbox-observed return status.
- Moved the auto-return control into the RTS tab and added a separate Sent Items logging toggle.

## 0.5.2

- Added sent-mail matching as a fallback when the client does not identify returned RTS mail.
- Restored the standard minimap button parent and hit rectangle.

## 0.5.1

- Removed batch sending and moved the automatic RTS return setting to the main window.
- Accepted RTS subjects with suffixes such as `RTS [1/3]`.
- Moved Return RTS below the inbox title and adjusted the minimap button hit area.

## 0.5.0

- Added the RTS Mail tab for sending selected bag stacks in a batch.
- Added optional automatic RTS returns, enabled by default, and a manual Return RTS button on the mailbox inbox.

## 0.4.4

- Added a saved opening-tab setting with a choice of any tab or the last used tab.

## 0.4.3

- Moved the approval prompt inward from the lower-right corner of the screen.
- Made the approval prompt draggable and saved its position across sessions.

## 0.4.2

- Narrowed the approval prompt to reduce empty space to the right.

## 0.4.1

- Made the approval prompt height adapt to the message and moved the buttons directly below it.

## 0.4.0

- Added acknowledgments and retries for shared inbox transfers. Both players must use the updated sharing protocol.
- Added a mailbox owner heading and status messages for empty, filtered, and incomplete shared inboxes.
- Added a title to the approval prompt, removed the trailing question from its message, and enlarged the main window.

## 0.3.0

- Enabled column sorting on all three tabs.
- Added separate item, sender, and recipient filters for each tab.
- Displayed the mailbox owner in the recipient column on inbox tabs.

## 0.2.0

- Added a draggable minimap button with a saved position.
- Added the Shared Inbox tab with a scrollable online friends list, request confirmation, and recipient approval.

## 0.1.0

- Added sent attachment logging and per-character inbox snapshots.
- Added paginated lists, sortable sent history, and automatic 30-day retention.
