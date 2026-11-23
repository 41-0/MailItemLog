# Mail Item Log

Mail Item Log is a World of Warcraft 1.12 addon that records sent mail attachments, tracks inbox items across your characters, and shares saved inbox lists with friends after approval.

## Installation

1. Extract the release ZIP. If you downloaded the repository as a ZIP instead, rename the extracted folder to `MailItemLog`.
2. Place that folder in `Interface/AddOns`. The game should find `Interface/AddOns/MailItemLog/MailItemLog.toc`.
3. Enable **Mail Item Log** on the character selection screen, then log in.
4. Click the minimap icon or enter `/maillog` to open the window. Drag the minimap icon to move it.

The addon targets WoW 1.12 clients (`Interface: 11200`). Compatibility with third-party bulk-mail addons may vary.

## Tabs

Use **Open on** to choose which tab appears each time you open the window. Choose **Last used tab** (the default), **Sent Items**, **Inbox Items**, **Shared Inbox**, or **RTS**. The setting and last used tab are saved across sessions.

| Tab | What it shows |
| --- | --- |
| **Sent Items** | Attachments from successful sends recorded since installation, with timestamp, quantity, sender, and recipient. |
| **Inbox Items** | The latest saved attachment list for each character on the same account. Open a mailbox to refresh that character's list. Individual messages can stay unopened. |
| **Shared Inbox** | A friend's saved inbox attachment list after they approve your request. The tab shows whose inbox you are viewing and when it was last checked. |
| **RTS** | Return settings and the current character's sent RTS history. |

The lists display 12 entries per page. Click a column heading to sort, or click it again to reverse the order. **Item**, **From**, and **To** accept case-insensitive partial matches. Enter values in multiple fields to combine filters, or click **Clear filters** to reset the current tab. On the inbox tabs, **To** is the mailbox owner.

## Sharing an inbox

1. Both players must be online, have each other on their friends lists, and run Mail Item Log with the same sharing protocol. Versions 0.4.0 through 0.6.0 use the same protocol.
2. In **Shared Inbox**, click a friend and select **Yes** at the **Send Request?** prompt.
3. Your friend can select **Approve** or **Decline** in a small notification. They can drag that notification to reposition it for future requests.
4. After approval, the addon sends the friend's last saved attachment list through in-game whispers. If they have no saved inbox, they need to open a mailbox before you request it again.

## RTS mail

Use a subject starting with `RTS` for mail that should be returned. Suffixes such as `RTS [1/3]` are supported.

**Auto-return RTS** in the **RTS** tab is on by default. When the inbox loads, the addon returns eligible RTS mail to its sender without reading its body. Already-returned and C.O.D. mail are skipped. If the client omits the returned flag, the addon also skips exact matches to RTS mail it recorded you sending in the last 30 days. This check uses the other character, full subject, attachment name and quantity, and attached money. To return matching mail on demand, click **Return RTS** below the Inbox title, including when auto-return is off.

The **RTS** tab lists RTS mail sent by the current character over the last 30 days. **Returned** means a matching message was observed after opening the mailbox. **Not seen yet** means the addon has not observed a match. Mail with identical details can only be matched by count. When upgrading, each unique RTS send remembered by v0.5.2 is imported once.

**Record in Sent Items** is on by default. Turn it off to omit future RTS sends from the general attachment log. The RTS history and return tracking still run.

## Data retention

The addon removes sent records 30 days after sending and saved inbox snapshots 30 days after their last refresh. This cleanup affects only the addon's records. The game's mail and attachments remain in the mailbox according to the game's own expiration rules.

See [CHANGELOG.md](CHANGELOG.md) for release history and [LICENSE](LICENSE) for the MIT license.
