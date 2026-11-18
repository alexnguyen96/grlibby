# Goodreads → Libby (KOReader plugin)

See which of your Libby libraries have the books on your Goodreads shelves, then borrow or place a hold right from KOReader. Borrowed books arrive on the device ready to read: the plugin downloads the `.acsm`, the [ACSM plugin](https://github.com/kaikozlov/acsm.koplugin) turns it into an EPUB, and the `.acsm` is deleted.

If Libby refuses this client the `.acsm` download (it sometimes does — see [below](#when-libby-wont-hand-over-the-acsm)), the plugin falls back to **building the EPUB on the device itself**, using the same browser-free read path the Libby web reader uses — no `.acsm`, no Adobe, no ACSM plugin needed.

## Install

1. Copy `goodreadslibby.koplugin` into KOReader's `plugins` folder:
   - Kindle: `/mnt/us/koreader/plugins/`
   - Kobo: `.adds/koreader/plugins/`
   - Android: `/sdcard/koreader/plugins/`
2. Recommended: install [acsm.koplugin](https://github.com/kaikozlov/acsm.koplugin) too. You can do this from the device later: **Settings → ACSM plugin → Install ACSM plugin from GitHub**.
3. Restart KOReader. You'll find the plugin under **Tools → Goodreads → Libby**.

## Setup

**Goodreads.** Before you copy the plugin to the device, open `goodreadslibby.koplugin/goodreads.txt` on your computer. Put one shelf per line, as **`nickname = shelf RSS link`**:

```
Want to Read = https://www.goodreads.com/review/list_rss/12345678?key=AbCd123&shelf=to-read
Reading now  = https://www.goodreads.com/review/list_rss/12345678?key=AbCd123&shelf=currently-reading
Book club    = book-club
Otis's picks = https://www.goodreads.com/review/list_rss/1?shelf=to-read
```

- The nickname is whatever you want to see in KOReader.
- To get a shelf's RSS link: on goodreads.com, open **My Books**, click the shelf, then copy the **RSS** link at the bottom of the page. Private profiles need these links, because they contain `key=`.
- Someone else's shelf works the same way, as long as their profile is public.
- Instead of a link you can write just a shelf name, like `book-club`. It then uses your profile. Your profile comes from `profile = …` or `user id = …`. Both are optional; without them, your shelf links already identify you.
- Lines starting with `#` are ignored. A line the plugin can't read is skipped and listed at the top of the plugin's menu.

The plugin reads this file automatically, so you can edit it later over USB. Shelves you add, rename, reorder or remove in KOReader (**Manage shelves**) are written back into it. You don't need a Goodreads password: the plugin only reads RSS feeds.

**Libby.** Go to **Settings → Libby → Link with setup code**. On your phone, open Libby → Menu → **Copy To Another Device**, then type the 8-digit code into KOReader within a minute. The plugin picks up all of the library cards in your Libby app.

**Shelves.** You start with Want to Read, Currently Reading and Read. In **Manage shelves** (in the main menu, in Settings, and in each shelf's ☰ menu) you can:
- add another of your shelves: a preset, **All my books**, or one of your custom shelves;
- add **someone else's shelf** from their profile link, RSS link or user ID. Their profile must be public, or use an RSS link with `key=`.
- **rename** any shelf to whatever nickname you like. Nicknames are only stored on this device.
- change which Goodreads shelf an entry points to, move shelves up or down, or remove them.

**Extra libraries** (optional). You can check libraries you don't have a card for. These show availability only. Use the library's key, which is the part after `libbyapp.com/library/`.

## Use

- **Open a shelf** from the main menu. Opening a shelf only lists its books; it never checks availability.
  - The first time, the shelf loads from Goodreads. After that the saved copy opens instantly.
  - To update it, tap **Refresh from Goodreads** in the ☰ menu, or turn on **Auto-refresh when opening**. With auto-refresh on, the shelf reloads whenever you open it while online.
- **Tap a book** to check it at your libraries. Results are remembered for 6 hours; you can change that in Settings. The book's popup lists every library:
  - libraries you can borrow from come first, with the most available copies at the top;
  - then holds, shortest wait first;
  - then libraries that don't have it.

  **Check again / Close** stay pinned at the top, so they're always reachable, even with 15 libraries.
- The **☰ menu** in a shelf has:
  - Refresh from Goodreads
  - Shelf: switch to another shelf
  - Sort: shelf order (the default), reverse shelf order, title A–Z or Z–A, author first name, author last name, highest Goodreads rating, or availability
  - Auto-refresh when opening
  - Precheck availability for all books…
  - Manage shelves, My Libby loans, Settings and Close
- **Precheck** checks every book on the shelf ahead of time. It first warns you that this can take a long time and uses Wi-Fi and battery, and that you run it at your own risk. It runs in a background process, and a **Stop** button stays on screen the whole time. Stop ends the work immediately, and results found so far are kept.
- **My Libby loans** shows each loan's due date and whether it's on this device ("on device", or "ACSM saved" if it hasn't been converted yet). Tapping a loan gives you:
  - Open book
  - Download (again)
  - Return early
  - Return and delete the file

  A loan locked to another format (for example after "Read with Kindle" in Libby) is marked as such and can't be downloaded as EPUB. The ⚙ button opens the settings.
- **Settings** can also be opened from inside the lists: the ☰ menu in a shelf, and the ⚙ button in My Libby loans.
- **Recheck availability after** can be 1 hour, 6 hours, 1 day, 1 week, or **Never** (only when you tap Check again).

Every screen has **Close**, **Cancel**, **Stop** or **Back**, and lists have the ✕ in the corner.

## ACSM plugin: install, update, convert

The plugin works with [acsm.koplugin](https://github.com/kaikozlov/acsm.koplugin) and manages it for you from **Settings → ACSM plugin**:

- **Install ACSM plugin from GitHub**: downloads the latest release into KOReader's `plugins` folder, next to this plugin. Restart KOReader afterwards. If you borrow a book before the ACSM plugin is installed, you're offered to install it right then.
- **Check for ACSM plugin update**: compares your installed version with the latest GitHub release and offers to update.
- **Check for updates automatically**: checks once a day, and only when the device is already online, so it never turns on Wi-Fi.
- **Install updates automatically**: installs new releases without asking first; KOReader then asks to restart.

Before installing or updating, the plugin looks for an existing ACSM plugin in every plugins folder KOReader uses. It recognises it by the name in its `_meta.lua`, so it finds it even if you installed it by hand, under a different folder name, or have it disabled.
- An existing install is updated in place, keeping its folder name. A second copy is never created, and it's only replaced when GitHub has a newer version.
- A git checkout is never touched; update it with `git pull`.
- An install whose version can't be read is never replaced automatically. A manual check asks first.
- A folder named `acsm.koplugin` that isn't the ACSM plugin is left alone.

An update swaps in the new plugin folder in one step. If anything fails, the installed version is left as it was. The ACSM plugin keeps its settings and Adobe activation outside its folder, so updates keep them.

When the ACSM plugin is running, each borrowed `.acsm` is passed to it, and it gets the EPUB (or PDF) from Adobe. The book is then moved to your **book folder**. Once that succeeds, the `.acsm` is deleted and you're offered to open the book.

Two folder settings control where files go:
- **Folder for .acsm files**: where `.acsm` files are saved.
- **Folder for books (EPUB/PDF)**: where finished books and DRM-free downloads go. It defaults to the `.acsm` folder. If the conversion fails, the `.acsm` is kept so you can tap it in the file browser later. Two switches control this:
- **Turn ACSM into EPUB automatically**
- **Delete the .acsm after converting**

The ACSM plugin creates an anonymous Adobe activation the first time it's used.

## Keeping this plugin up to date

The plugin can update **itself** from this repository's GitHub releases, the same way it manages the ACSM plugin. In **Settings → Plugin updates**:

- **Check for plugin update now**: looks up the latest release and offers to install it. The update swaps in the new plugin folder in one step and keeps your `goodreads.txt` and log; your settings live outside the plugin folder and are untouched. KOReader then asks to restart.
- **Check for updates automatically**: checks once a day, and only when the device is already online, so it never turns on Wi-Fi.
- **Install updates automatically**: installs new releases without asking first (KOReader still asks to restart).
- **Update source**: the GitHub repository (`owner/name`) to fetch releases from. Change it only if you use a fork; "Use default" restores it.

A release is picked up when it has a `.zip` asset containing the plugin folder (or, failing that, GitHub's own source zip). A git checkout is never touched — update that with `git pull`. The version shown is the one in `_meta.lua`.

**Cutting a release (maintainer).** Bump `version` in `goodreadslibby.koplugin/_meta.lua`, commit, then tag and publish a GitHub **Release** for that version. Run `tools/build-zip.sh` and attach the resulting `goodreadslibby.koplugin.zip` as a release asset (devices then download the small asset rather than the whole source zip). Devices with auto-check on pick it up within a day; others see it on the next manual check.

## Troubleshooting

**Settings → Troubleshooting** has:
- **Test Libby connection**: shows your Libby token's device, card count and expiry, and checks that Libby answers.
- **Log file**: `goodreadslibby.log` in the plugin folder. It records every request to Libby's account API (including redirects, whether the token was sent, status codes and Libby's replies), every failed request, borrow and download results, ACSM conversions, and crashes. Your Libby token, Goodreads RSS keys and Libby setup codes are replaced with `<hidden>`, so the file is safe to share. Copy it off the device over USB.
- **Clear the log**
- **Check goodreads.txt**: lists any lines the plugin couldn't read.

Libby tokens expire after about a week, so the plugin renews yours a few days before it expires. Renewing keeps the same linked device. Renewal works the way [jordkh/odmpy](https://github.com/jordkh/odmpy) does it, naming the Libby app version, which gives a token of type `v`. The older `?client=dewey` renewal gives type `l`, which Libby's download link may refuse. An older token is upgraded once automatically. The log shows each token's type.

## When Libby won't hand over the ACSM

Libby's download link can refuse this plugin with `missing_chip (HTTP 403)`, even though the same login works for syncing and borrowing. When that happens, the plugin **builds the EPUB on the device itself** instead, and from then on it skips the dead download step after borrowing (a repeat call risks a rate-limit).

**Build EPUB on device (automatic).** This reproduces, entirely on the device, the browser-free read path that the Libby web reader uses: it opens the loan for reading (a different endpoint, which isn't refused), decodes the reader page, fetches and decodes each page and its images, and assembles an EPUB straight into your **book folder**. A **Stop** button stays on screen the whole time, and progress ("Decoding page 12 of 240", "Fetching image 3 of 18") is shown. The result is a normal, DRM-free EPUB — no `.acsm`, no Adobe activation, and the ACSM plugin isn't needed. You can also trigger it yourself from **My Libby loans → the loan → Build EPUB on device**.

- It saves a copy of a book already borrowed on your own card, for your own offline reading. It doesn't get around lending limits.
- It relies on OverDrive's current page format; if that changes, the build fails with a message naming the step that broke (never a half-written book), and you can fall back to the manual route below.
- Audiobooks aren't built this way (ebooks and magazines only).

**Manual route (fallback).** If the on-device build can't run (for example the loan won't open), the plugin shows how to get the file by hand:

1. In the Libby app (or libbyapp.com), go to **Shelf → the loan → Manage Loan → Download EPUB** (with DRM). That gives you the `.acsm` file.
2. Copy the `.acsm` onto the device, into the plugin's **.acsm folder** (Settings).
3. In KOReader, open **Goodreads → Libby → Convert .acsm files**. The main menu shows how many files are waiting. The ACSM plugin turns each file into an EPUB and moves it to your **book folder**. The `.acsm` is then deleted, and **My Libby loans** marks the loan "on device".

If a direct `.acsm` download works again later (try **Download** on a loan), the plugin goes back to downloading by itself.

**"Invalid Library Card … PatronCardFailedAuthentication"** means the library refused the card linked in your Libby app; the plugin isn't the problem. Open that library's card in the Libby app and sign in again, or renew the card. Then run **Settings → Libby → Refresh library cards**.

## How matching works

The plugin searches OverDrive's catalog (the same API the Libby userscript uses) with the main title, without the series or subtitle, plus the author's surname. It limits results to ebooks, then only accepts a result that matches the Goodreads book:

- an identical ISBN, **or**
- a similar title **and** the same author surname.

If the first search finds nothing, it searches again by ISBN. When several editions match, it picks the one you can get soonest.

## Notes

- Without the ACSM plugin, an `.acsm` is only a license file. You'd need Adobe Digital Editions or a similar tool to get the book — or let the plugin [build the EPUB on the device](#when-libby-wont-hand-over-the-acsm), which needs neither.
- Goodreads, Libby and OverDrive have no official public API for this. The plugin uses the same web endpoints as the Libby web app, odmpy and the Calibre Libby plugin, and these could change.
- The on-device EPUB build (the ACSM fallback) is a Lua port of the browser-free read/decode path worked out by [libby-archiver](https://github.com/JavaGT/libby-archiver) and the [LibbyRip](https://github.com/PsychedelicPalimpsest/LibbyRip) userscript it builds on. The reader page is decoded structurally and never executed as code.
- Borrowing, holds, downloads and loans use Libby's account API at `sentry.libbyapp.com`. Its responses state that it is a private API for the Libby app, and that OverDrive's Terms and Conditions prohibit other clients from using it. Use those features at your own risk. Checking availability uses OverDrive's public catalog API and isn't affected.
- Tests: `pip install lupa`, then `python3 tests/harness.py` (unit tests plus live API checks), `python3 tests/smoke_main.py` (UI flow with stubbed KOReader), and `python3 tests/decode_test.py` (the on-device decode/EPUB pipeline, round-tripped against OverDrive's wire formats). `tests/libby_dev.py` drives the real Libby code against your own account from a computer; it gained a `decode "<title>"` command that runs the on-device EPUB build end-to-end (read-only — it never borrows or returns).
