# Face Sweep

Find every photo and video of one specific person in your library, then move, hide or delete those files — after you review the list and confirm.

Everything runs on your own computer inside the browser. Your files are never uploaded.

- **App:** `public/face-sweep.html`
- **Local:** `npm start` then open <http://localhost:3000/face-sweep>
- **Hosted:** once merged to `main`, GitHub Pages serves it at `https://jamstand.github.io/just-be-making-stuff/face-sweep.html`

## How to use it

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

## Requirements and limits

- **Browser:** Chrome, Edge, Brave, Opera or Arc on desktop (needs the File System Access API). Firefox, Safari and mobile browsers don't support it.
- **Files:** JPEG, PNG, WebP, GIF, BMP, AVIF and HEIC/HEIF photos; MP4, MOV, WebM and other browser-decodable video. Formats the browser can't decode (for example HEVC on machines without hardware support) are listed under **Skipped files** after a scan.
- **Face model:** downloaded once (about 12 MB) from a public CDN, then cached by the browser. It runs on your GPU where available.
- **Speed:** roughly 0.3–1 s per photo on a typical laptop GPU; videos take longer depending on how many frames you sample (Scan settings).
- **Timestamps:** when the browser can't move a file in place it copies and deletes, which gives the file a new "modified" date. The photo's own EXIF date is untouched.
- **Accuracy:** face recognition is not perfect. Heavy makeup, masks, profile views, low light and small faces reduce recall; look-alikes and relatives can produce false positives. That's why every action shows you the list first. Start on Strict, then loosen and review what appears.

## Privacy

The folder handle, face fingerprints (128 numbers per face), small face thumbnails, your people, and a log of the changes you made are stored in the browser's IndexedDB for this site only. Nothing is sent to any server. Clear site data in your browser to wipe it.

## Implementation notes

- Single file, no build step: `public/face-sweep.html`.
- Face detection and recognition: [`@vladmandic/face-api`](https://github.com/vladmandic/face-api) (SSD MobileNet v1 detector, 68-point landmarks, FaceNet-style 128-d descriptors), loaded from jsDelivr.
- HEIC decoding: `heic2any`, loaded lazily only when a `.heic`/`.heif` file is met.
- File access: File System Access API (`showDirectoryPicker`, `entries()`, `createWritable`, `removeEntry`, `move` where supported).
- Matching: Euclidean distance between a file's face descriptors and the person's reference descriptors; the Strictness slider is that distance threshold (default 0.55).
- "People found": greedy clustering of all detected faces at distance 0.5.
