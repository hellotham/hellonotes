A bug-fix release, and the bug was worth the release on its own: on a large vault kept in iCloud Drive, the editor froze. Typing a title could lock the window for thirteen seconds, a save could set the whole folder re-reading, and a note being edited could vanish from the sidebar.

## The editor is never blocked

The cause was not where two previous attempts looked. Work that the code carefully sent to a background thread was running on the main one anyway — a project setting made every unannotated type main-actor, so `Task.detached` detached the work's priority and cancellation but not its *thread*. On a local folder that only wastes effort. On a folder managed by iCloud it meant every directory listing became a blocking call to the sync daemon, on the thread drawing your window, which is why this only ever happened on a real vault.

Measured on a 2,000-note vault, before and after:

| | before | after |
|---|---|---|
| Naming a new note | 13.4 s | 0.003 s |
| Scanning the folder | 0.24 s of blocked editor | 0.002 s |
| Worst freeze | 5.9 s | none above 0.5 s |

- **Naming a note is instant.** Renaming rewrote `[[links]]` in every note in the vault before it would return, and a new note opens with its title focused — so that was the price of typing a name. It now updates only the notes that actually link to it, and does it after the rename, not before.
- **Saving never re-reads the folder.** A save whose note had briefly left the list would trigger a full rescan, which is what made notes leave the list: the failure fed itself.
- **Opening a note doesn't wait for a scan**, and creating, appending to, or deleting one changes one entry rather than asking the whole folder again.
- **Transclusions, previews and the file viewer** read off the main thread. A `![[note]]` embed used to be read while the editor laid out the page.
- **Quitting can't hang.** If the sync daemon stops answering, the app now gives the final save five seconds and exits, instead of waiting forever and being force-quit — which would have discarded the edits that wait exists to protect.

Nothing in the editor's behaviour changed, only what it waits for.

## Notes stay put

- **A partial scan can no longer remove notes.** A scan that resumes mid-folder reports success having seen only the rest of the tree; publishing that as the truth replaced the note list with its tail. Only a pass that starts at the top may remove anything now.
- **A scan that is cancelled leaves the collection alone** rather than emptying it.
- **Unsaved edits survive a refresh.** Closing an editor in the background didn't save it first, so a note that briefly left the list took your pending keystrokes with it.
- **Clicking a note in the sidebar always opens it.** If it couldn't be found the click did nothing at all — no error, no sign anything had happened.
- On iPhone and iPad, switching collections no longer closes the note you have open, and a selection that resolves to nothing leaves the editor alone.

## Blockquotes in the editor

- **Markdown reveals per line, not per block.** A blockquote is one block however many lines it spans, so putting the cursor in one used to show the raw `>` on *every* line of it and drop every vertical bar. Now the line you are on shows its markers and the rest keep their formatting — the same as Bear and Obsidian. This applies to headings and emphasis too.
- **A paragraph you turn into a blockquote gets its bar straight away**, instead of when the line next happened to be redrawn.

## Under the hood

The rule that the editor is never blocked is now checked rather than remembered: work that must stay off the main thread goes through a helper that makes it a *compile error* to touch main-thread state, and a test fails the build if the folder scanner ever regains it. The app can also now catch a freeze while it is happening and record what was responsible, which is how this one was finally found — after five earlier attempts measured the wrong thing.
