# Ward Bloods

A results tracker for ward teams. It covers:
- bloods trended in tables, with your lab's reference ranges and paste-import from lab reports
- microbiology and sensitivities, pathology and radiology, with image and PDF upload
- a chase list for each patient and for the whole ward
- Active, Discharged and Deceased patient lists, with readmission

Everyone in your team sees the same patients live. Access requires an invite, a password and an authenticator-app code.

**No identifiers are stored.** There are no fields for name, hospital number or date of birth. Use initials or bed number as the label, and keep identifiers out of notes, reports and images.

---

## Before you start
1. **Get approval from the hospital.** Ask IT or the data protection officer whether a team-run results tracker is allowed. Under the Barbados Data Protection Act 2019, health data is sensitive personal data, and whoever runs the database is responsible for it.
2. Keep this repo **free of patient data**. It only ever contains code.

---

## Setup (about 45 minutes)

### 1. Create the Supabase project
1. Go to supabase.com and click **New project**. Choose the region closest to you (usually *East US*) and a strong database password.
2. For real patient data, use the **Pro plan**. It adds daily backups, and projects on the free plan pause after a week of inactivity.
3. In **Settings → Legal documents**, accept the Data Processing Agreement.

### 2. Create the database, security rules and private file storage
1. Open **SQL Editor → New query**.
2. Paste in the whole of `supabase/schema.sql` and click **Run**.
3. Create your team (change the name):
   ```sql
   insert into public.teams(name) values ('Medicine A interns');
   ```
4. Check **Storage** in the sidebar. You should see a bucket called `ward-files` marked **Private**.

### 3. Lock down sign-in
In **Authentication → Sign In / Providers**:
- **Allow new users to sign up**: **OFF**.
- **Email**: enabled. Turn off every other provider.

In **Authentication → Multi-Factor**:
- Enable **TOTP (authenticator app)**.

In **Authentication → URL Configuration**:
- Set **Site URL** to your app's address (from step 5).

### 4. Add each person
1. Go to **Authentication → Users → Add user → Create new user**. Enter the email and a temporary password, and tick **Auto confirm user**.
2. Add them to the team:
   ```sql
   insert into public.team_members(team_id, user_id)
   select t.id, u.id from public.teams t, auth.users u
    where t.name = 'Medicine A interns' and u.email = 'colleague@example.com';
   ```
3. On first sign-in, the app shows a QR code to scan with Google Authenticator, Microsoft Authenticator or Authy. **No one can see any patient without that 6-digit code**, because the database itself enforces it.

To remove someone, delete them in **Authentication → Users**.

### 5. Put it online
1. Open `config.js` and paste in the two values from **Settings → API**:
   ```js
   window.WB_CONFIG = {
     SUPABASE_URL: "https://xxxx.supabase.co",
     SUPABASE_ANON_KEY: "eyJ...",   // "anon public" key, never the secret service key
     IDLE_MINUTES: 15
   };
   ```
2. Host the folder using one of these:
   - **GitHub Pages**: create a repo, upload these files, then go to **Settings → Pages → Deploy from a branch → main / (root)**. Pages on a private repo needs a paid GitHub plan. A public repo is fine here because it holds no secrets or patient data.
   - **Netlify or Cloudflare Pages** (free, and they work with private repos): connect the repo and deploy the root folder.
3. Open the address on your phone and your colleague's phone, and sign in.

### 6. Test the security (5 minutes, do this before real patients)
1. Create a third user who is **not** in the team and sign in as them. The app should say *"Not in a team yet"* and show nothing.
2. In Supabase, open **Advisors → Security Advisor**. It should show no "RLS disabled" warnings.
3. Open `config.js` and confirm the key is the **anon public** key from Settings → API, not the secret service key.

---

## Everyday use
- **Paste results**: copy results from the lab system, then click Paste results, check the values and save. Names and hospital numbers in the pasted text are ignored.
- **Discharge / Readmit / Mark deceased** are at the bottom of each patient. Nothing is deleted when you do these. **Delete permanently** removes the patient and their images.
- **Images**: crop out or cover names and numbers before uploading. The app asks you to confirm this each time.
- Sign out on shared ward PCs. The app also signs you out automatically after 15 minutes idle and when the tab closes.

## How the data is protected
| Layer | Protection |
| --- | --- |
| Data stored | No names, hospital numbers or dates of birth; paste-import keeps only test names and values |
| Sign-in | Invite-only; email and password plus authenticator-app 2FA; auto sign-out |
| Database | Row Level Security: only your team, and only after 2FA |
| Edits | All changes go through one checked function that merges edits and records who changed what |
| Files | Private bucket; the same team and 2FA rule; links expire after 1 hour; photo metadata stripped |
| Transport and storage | HTTPS everywhere; Supabase encrypts at rest; daily backups on Pro |
| Browser | Strict content-security policy; the Supabase library pinned with an integrity hash |

## Changing reference ranges or test names
Everything is in `index.html`:
- To change ranges, search for `const PANELS=[`. Ranges marked `lab:1` came from your lab's reports.
- To add a lab's spelling for paste-import, search for `const ALIASES={`.
