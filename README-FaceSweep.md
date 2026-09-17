# Face Sweep

Find every photo and video of one specific person, then move, hide or delete those files — after you review the list and confirm.

Everything runs on your own device inside the browser. Your files are never uploaded.

There are two versions:

| | Desktop (`public/face-sweep.html`) | Phone (`public/face-sweep-phone/`) |
| --- | --- | --- |
| Where it looks | Whole folders on your computer, sub-folders included | A batch of photos you pick from your phone's library |
| Finds the person | Yes | Yes |
| Moves / hides / deletes the files | Yes, itself, after confirmation | No. Phones don't let a web page touch the photo library, so it tells you exactly which photos and walks you through doing it in your Photos app |
| Browser | Chrome, Edge, Brave, Opera or Arc on Windows, macOS, Linux, ChromeOS | Safari on iPhone, Chrome on Android; installable to the home screen |

- **Local:** `npm start` then open <http://localhost:3000/face-sweep> or <http://localhost:3000/face-sweep-phone/>
- **Hosted:** once merged to `main`, GitHub Pages serves them at `https://jamstand.github.io/just-be-making-stuff/face-sweep.html` and `https://jamstand.github.io/just-be-making-stuff/face-sweep-phone/`

## Desktop: how to use it

1. **Choose folder.** Pick the folder that holds your photos and videos (your Pictures folder, or your whole user folder). Sub-folders are included. Your browser asks for read access once.
2. **Add the person.** Type a name, then drop in a few clear photos of them. If a reference photo has several faces, you're asked which one is them. You can also scan first and pick the person from the **People found** tab, which groups every face the scan saw.
3. **Scan.** Every photo is checked for faces; videos are checked by sampling frames across the clip. Results are cached, so re-scanning only looks at new or changed files, and switching person or strictness is instant.
4. **Review.** Matches show the file, the face that matched, and a confidence chip (Strong / Likely / Possible). Untick anything you want to keep. Use **Not them** on a wrong match so it never comes back, and **Add as reference** on a correct one to improve recall. The **Strictness** slider tightens or loosens matching without a re-scan.
5. **Act.** Choose **Move to folder**, **Hide** or **Delete**. A confirmation screen lists exactly which files will change and what will happen. Nothing touches disk until you confirm, and your browser asks once more for permission to change files in that folder.

### What each action does

| Action | What happens | Reversible? |
| --- | --- | --- |
| Move to folder | Files move (not copy) into `Face Sweep/<Name>/` inside your library, or into any folder you pick. | Yes — **History → Restore** |
| Hide | Files move into `.facesweep-hidden/` at the top of your library, keeping their sub-folder layout. Dot-folders are invisible to photo apps, Finder and Explorer (with hidden files off). | Yes — **History → Restore** |
| Delete | Files are erased from disk. They do **not** go to the Recycle Bin or Trash. The confirmation needs an extra "I understand" tick. | **No** |

Windows tip: Explorer shows dot-folders by default. Right-click `.facesweep-hidden` → Properties → tick Hidden if you want it out of sight there too.

## Phone: how to use it

Open the phone page in Safari (iPhone) or Chrome (Android) and add it to your home screen if you like (iPhone: Share → Add to Home Screen; Android: ⋮ → Install and create shortcut, or Add to Home screen on older Chrome). On iPhone the installed app keeps its own separate memory, so add the person again there.

**The fast way is built into your phone.** The Photos app already groups faces, sees your whole library, and can delete, hide or make an album in a few taps with its own confirmations. The phone page opens with those exact steps for your phone:

- **iPhone:** Photos → People & Pets (Collections tab on iOS 26+, swipe up on iOS 18, Albums tab on iOS 17) → the person → Select → Select All (or drag across photos) → trash icon, or **…** → Hide, or **…** → Add to Album (Share → Add to Album on iOS 26). Deleted photos wait 30 days in Recently Deleted.
- **Android, Google Photos:** Collections → People & pets → the face → touch-and-hold and drag to select → Trash, or ⋮ → Archive (still in albums), or Add to → Move to Locked Folder (hidden everywhere; move them out again before deleting), or Add to album. Trash keeps items 30 days. Any album can also auto-collect a person: open the album → ⋮ → Options → Add → pick the face.
- **Samsung Gallery:** Collections → People and pets → the person → touch-and-hold to select → Delete / ⋮ → Move to Secure Folder / Create album.

**Face Sweep for phones** is the second opinion, or the tool for someone your Photos app hasn't grouped:

1. Add the person and a few clear photos of them.
2. **Choose photos** from your library in batches (an album, a trip, a month). On Android the picker allows 100 at a time; on iPhone a big batch takes a moment because the phone converts each photo before handing it over.
3. **Check them.** Results show which photos have the person, with the matched face, confidence, file name and the photo's own date (read from the picture, since phones don't pass the real date otherwise).
4. Tap a result to see it full size. **Share…** sends the selected matches anywhere (Save to Files, another app), in groups of ten where the phone requires it; **Copy list** copies file names and dates so you can find them in Photos by searching the date.
5. Delete, hide or sort them in Photos using the steps above. Results are remembered, so the app reopens with your last check while you work through them.

## Requirements and limits

- **Desktop browser:** Chrome, Edge, Brave, Opera or Arc on desktop (needs the File System Access API). Firefox and Safari don't support it. Android Chrome 132+ also exposes a folder picker, but that path is untested here.
- **Phone browser:** Safari on iOS 16+ (iOS 17+ decodes HEIC natively), Chrome on Android. The phone page can't delete, hide or move photos; that's an operating-system rule for web pages.
- **Files:** JPEG, PNG, WebP, GIF, BMP, AVIF and HEIC/HEIF photos; MP4, MOV, WebM and other browser-decodable video. Formats the browser can't decode (for example HEVC on machines without hardware support) are listed under **Skipped files** after a scan.
- **Face model:** downloaded once (about 12 MB) from a public CDN, then cached by the browser (and by the phone app's service worker for offline use). It runs on the GPU where available and falls back to WebAssembly where it isn't.
- **Speed:** roughly 0.3–1 s per photo on a laptop GPU, 1–3 s on a phone; videos take longer depending on how many frames you sample (Settings).
- **Timestamps:** when the desktop browser can't move a file in place it copies and deletes, which gives the file a new "modified" date. The photo's own EXIF date is untouched.
- **Accuracy:** face recognition is not perfect. Heavy makeup, masks, profile views, low light and small faces reduce recall; look-alikes and relatives can produce false positives. That's why every action shows you the list first. Start on Strict, then loosen and review what appears.

## Privacy

The folder handle (desktop), face fingerprints (128 numbers per face), small thumbnails, your people, and a log of the changes made (desktop) are stored in the browser's IndexedDB for this site only. Nothing is sent to any server. Clear site data in your browser to wipe it.

## Implementation notes

- No build step. Shared logic lives in `public/face-sweep-core.js`; the desktop page is `public/face-sweep.html`; the phone app is `public/face-sweep-phone/index.html` with its own manifest, icons and service worker (scoped to that folder so it never touches the other apps on the site).
- Face detection and recognition: [`@vladmandic/face-api`](https://github.com/vladmandic/face-api) (SSD MobileNet v1 detector, 68-point landmarks, FaceNet-style 128-d descriptors), loaded from jsDelivr. Its WebAssembly fallback files come from the matching `@tensorflow/tfjs-backend-wasm` package.
- Images are decoded through an `<img>` element so EXIF orientation is applied everywhere and Safari's native HEIC decoding is used; other browsers fall back to `heic2any` for HEIC.
- Photo dates are read from EXIF (JPEG APP1 and HEIF `Exif` items) without decoding the image, because phone pickers report the pick time as the file's modified time.
- The phone cache is keyed by file size plus a hash of the file's head and tail, since phone pickers hand over re-exported copies with fresh timestamps.
- Matching: Euclidean distance between a file's face descriptors and the person's reference descriptors; the Strictness slider is that distance threshold (default 0.55).
- "People found": greedy clustering of all detected faces at distance 0.5.
