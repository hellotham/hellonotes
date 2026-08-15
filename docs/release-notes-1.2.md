A collection points at a folder HelloNotes does not control. This release is
about what happens when that folder is large, slow, in the cloud, inside a Git
repository, or simply not there any more — and about the app saying so instead
of guessing.

## Cloud folders

- **Use the folder you already have.** If Box, Dropbox, OneDrive or Google Drive is installed on your Mac, **File ▸ Open Cloud Folder…** opens its folder directly — no sign-in, no token, no second copy of your files. Connecting over a provider's API moved to **File ▸ Connect Over the Web**, for accounts whose app you don't have.
- **Cloud collections open immediately.** The folder's structure appears straight away and each file's contents arrive the first time you open it. Every file comes across, not just Markdown — PDFs, images and documents preview as usual.
- **They come back when you reopen the app**, from what is already on disk, then check the provider for changes.
- **Refresh** asks the provider what has changed rather than re-reading the whole folder.
- **Edited in two places at once?** Both versions are kept — decided by the provider's own record of the file, not by comparing two devices' clocks.
- **Add as Collection now works on iPhone and iPad.**

## Large folders

- **Adding a big folder tells you it is big**, and offers to open a subfolder instead. Adding it anyway is always allowed.
- **Scanning shows progress and can be stopped.** What has been found is kept, and scanning resumes where it stopped — after a cancel, a quit, or iOS suspending the app.
- **Notes appear as they are found**, rather than all at once at the end.
- **Non-note files can be hidden** per collection, and the status bar says how many are hidden.

## Folders that move, vanish, or change behind your back

- **A folder that can't be read now says so** — moved, renamed, deleted, or on a disconnected disk — and keeps showing its notes as they were, rather than appearing empty. **Try Again** picks it back up; a folder that has moved is followed.
- **Editing continues while a folder is away.** Saving is refused rather than written into nowhere, and your changes are held until it returns.
- **Changes made by other apps are noticed more reliably**, and search says when its results may be incomplete.
- **iPad and iPhone notice changes at all now.**
- **Search says when it can't see everything**, and offers to download what it is skipping.

## Git

- **A folder inside a repository is recognised as one.** Opening `~/project/docs` as a collection now has the full Git panel, and everything it does covers only that folder. Nothing outside your collection is ever committed.
- **The branch and change count keep up with the terminal** after a `git pull` or branch switch.

## Fixed

- "Add as Collection" appeared to do nothing — failures were discarded silently.
- A cloud browser opened with a saved sign-in showed an empty account.
- An expired cloud sign-in now offers to sign in again.
- Cancelling a scan no longer discards what it found.
- A collection whose saved permission had aged out silently disappeared on the next launch.
- Large attachments upload to OneDrive instead of failing past 4 MB.
