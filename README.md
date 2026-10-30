# Vista Training site

Employees open `index.html`, sign in with name, employee number and store, watch the three videos in order (no skipping ahead, no speed-up), then take the 18-question quiz. Managers open `manager.html` to see who finished.

## Files
- `index.html`: employee training page (English / Español)
- `manager.html`: manager report (login required)
- `setup.sql`: creates the database tables, run once in Supabase
- `videos/`: the training videos (`day1-en.mp4` is included)

## Setup (about 20 minutes, one time)

### 1. Create the database
1. Go to supabase.com and create a **new project** (keep it separate from the hiring tracker). Name it "vista-training".
2. Open **SQL Editor > New query**, paste everything from `setup.sql`, and click **Run**.
3. Open **Authentication > Sign In / Providers** and turn **off** "Allow new users to sign up". Only people you add can see the report.
4. Open **Authentication > Users > Add user** and create a login (email + password) for yourself and each store manager.
5. Open **Project Settings > API** and copy the **Project URL** and the **anon public** key.

### 2. Connect the pages
Paste the URL and key into both files:
- `index.html`: `SUPABASE_URL` and `SUPABASE_ANON_KEY` inside `CONFIG` near the bottom
- `manager.html`: `SUPABASE_URL` and `SUPABASE_ANON_KEY` near the bottom

The anon key is safe to put in a web page. The database only lets employees save progress, and only signed-in managers can read the report.

### 3. Put it on GitHub Pages
1. Create a new GitHub repository, for example `vista-training`.
2. Upload all files, keeping the `videos` folder.
3. Go to **Settings > Pages**, choose **Deploy from a branch**, pick `main` and `/ (root)`, and save.
4. After a minute your site is at `https://<your-username>.github.io/vista-training/`, and the report is at `.../manager.html`.

### 4. Add more videos
1. Compress each video before uploading (NotebookLM videos shrink about 80% with no visible loss). Keep each file under 50 MB; GitHub refuses files over 100 MB.
2. Name them `day2-en.mp4`, `day3-en.mp4`, `day1-es.mp4`, `day2-es.mp4`, `day3-es.mp4` and upload them to `videos/`.
3. In `index.html`, fill in the matching paths in `CONFIG.VIDEOS`. Any blank path shows as "Coming soon".

### 5. Share with employees
Make a QR code for the site link and post it in each break room next to The Vista Way cards.

## How the no-skip player works
- Employees can pause and rewind 10 seconds, but can't jump past what they've already watched or change the speed.
- Leaving the page or switching apps pauses the video, and it resumes where they left off.
- A video counts as complete only when it plays to the end.
- This stops normal skipping. Someone technical could still get around it, so the quiz and the trainer's sign-off sheet remain the real check.

## Stores
The store list is in `CONFIG.STORES` in `index.html`: Alameda, Central, Doniphan, Horizon, Montana, Piedras, Urban.
