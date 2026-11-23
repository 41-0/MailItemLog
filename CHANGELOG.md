# Changelog

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
