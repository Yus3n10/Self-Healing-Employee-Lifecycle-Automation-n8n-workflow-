# Stage 0 · Setup

Everything here is free. Nothing needs Docker or WSL.

Work through it top to bottom. At the end you will have n8n running, a Postgres
database with the schema loaded, a mock IdP answering on port 8100, and four
credentials saved in n8n.

---

## 0.1 Accounts and services you need

| Service | Cost | Used for | Sign up at |
|---|---|---|---|
| Neon | Free tier | Postgres for runs, steps, audit log | https://neon.tech |
| Google account | Free | Gmail SMTP for approval emails | you already have one |
| Google AI Studio | Free tier | Gemini API key (Stage 3 only) | https://aistudio.google.com |
| n8n | Free, self-hosted | The orchestrator | installed below |

You do **not** need n8n Cloud, Docker, Slack, or any paid API.

---

## 0.2 Install n8n

Open PowerShell (a normal window, not admin).

```bash
node --version
```

You need Node 20.19+ or 22.x. If `n8n` later refuses to start with a Node
version error, install Node 22 LTS alongside what you have:

```bash
winget install CoreyButler.NVMforWindows
```

Then, in a **new** PowerShell window:

```bash
nvm install 22.20.0
```

```bash
nvm use 22.20.0
```

Now install n8n globally:

```bash
npm install -g n8n
```

This takes 2 to 5 minutes. Verify:

```bash
n8n --version
```

### Version note, read this once

This guide was written against n8n 1.x conventions. Verified installed here:
**n8n 2.34.5 on Node 24.18.0**, which runs fine. The node *types* this project
uses (Form Trigger, Code, If, Switch, Postgres, HTTP Request, Wait, Execute
Sub-workflow, Loop Over Items, Send Email, Error Trigger, Schedule Trigger,
Respond to Webhook, Basic LLM Chain) are stable across that jump, but individual
**field labels and the position of Options may have been renamed**.

When a label in this guide does not match what you see, the surrounding table
still tells you what the setting has to *do*. Find the equivalent, and tell me
what your version actually calls it so the guide gets corrected rather than
quietly drifting out of date. Three spots are the most likely to differ:

| Guide says | Where | If it differs |
|---|---|---|
| Postgres → Options → **Query Parameters** | every Execute Query node | Look for any option that supplies values for `$1`, `$2` |
| Form Trigger → **Respond When** | §1.2 | Pick whatever means "answer immediately, do not wait for the workflow" |
| Form field prefill via query parameters | Stage 3 | If prefill does nothing, the email still lists every value to type |

Also note: **npm blocked the install scripts** for `ssh2`, `msgpackr-extract`
and a few others during install (npm 11's new default). n8n's core loads and the
CLI works, so this project is unaffected. If you later use the SSH or SFTP
nodes and they fail, that is the cause, and the fix is
`npm approve-scripts --allow-scripts-pending` followed by a reinstall.

### Start n8n

From the project folder:

```bash
cd "D:\Claude Local\jml-orchestrator"
```

```bash
powershell -ExecutionPolicy Bypass -File .\scripts\start-n8n.ps1
```

The script generates an encryption key on first run and saves it to
`%USERPROFILE%\.n8n\project-encryption-key.txt`. **Back that file up.** If you
lose it, every saved credential becomes undecryptable and you re-enter all of
them.

Open http://localhost:5678 and create the local owner account. It asks for
email, first name, last name, password. This account is local to your machine
only; nothing is sent anywhere.

n8n stores its own data in `%USERPROFILE%\.n8n\database.sqlite`. That is fine
for this project. Postgres is for *your* application data, not n8n's internals.

> Leave this PowerShell window open. n8n runs in the foreground. Use a second
> window for everything else.

---

## 0.3 Create the Postgres database on Neon

1. Sign up at https://neon.tech with GitHub or Google.
2. Create a project. Fill in exactly:
   - **Project name**: `jml-orchestrator`
   - **Postgres version**: 17 (or the newest offered)
   - **Cloud provider**: AWS
   - **Region**: `Asia Pacific (Singapore)` — closest to you, lowest latency
3. After it creates, you land on the dashboard. Click **Connect** (or
   **Connection Details**). You will see a connection string like:

   ```
   postgresql://neondb_owner:npg_AbC123xyz@ep-cool-mud-a1b2c3d4-pooler.ap-southeast-1.aws.neon.tech/neondb?sslmode=require
   ```

4. Write down these five parts. You will type them into n8n in step 0.6.

   | Part | From the example above |
   |---|---|
   | Host | `ep-cool-mud-a1b2c3d4-pooler.ap-southeast-1.aws.neon.tech` |
   | Database | `neondb` |
   | User | `neondb_owner` |
   | Password | `npg_AbC123xyz` |
   | Port | `5432` |

   Use the **pooled** host (the one containing `-pooler`). n8n opens and closes
   connections frequently and the pooler handles that better.

### Load the schema

1. In the Neon console left sidebar, click **SQL Editor**.
2. Open `D:\Claude Local\jml-orchestrator\db\schema.sql`, copy the whole file,
   paste it into the editor, click **Run**.
3. Clear the editor. Open `db\seed_entitlements.sql`, copy, paste, **Run**.
4. Verify. Paste this and Run:

   ```sql
   SELECT role_code, count(*) AS entitlements
   FROM role_entitlements GROUP BY role_code ORDER BY role_code;
   ```

   Expected output: 6 rows, `ENG_JUNIOR` 6, `ENG_SENIOR` 7, `FIN_ANALYST` 6,
   `IT_ADMIN` 6, `SALES_REP` 5, `SUPPORT_AGENT` 5.

If you get `permission denied to create extension "pgcrypto"`, delete the
`CREATE EXTENSION` line and re-run. Neon's Postgres 17 has `gen_random_uuid()`
built in.

---

## 0.4 Start the mock IdP

Second PowerShell window:

```bash
cd "D:\Claude Local\jml-orchestrator\mock-idp"
```

The virtual environment already exists if you ran the self-check. If not:

```bash
py -3.11 -m venv .venv; .\.venv\Scripts\python.exe -m pip install -r requirements.txt
```

Run the self-check once. It must print `mock IdP self-check passed`:

```bash
.\.venv\Scripts\python.exe test_mock_idp.py
```

Now start the server:

```bash
$env:MOCK_IDP_API_KEY = "dev-mock-idp-key-change-me"; .\.venv\Scripts\python.exe -m uvicorn main:app --host 127.0.0.1 --port 8100
```

Verify in a third window:

```bash
curl.exe http://127.0.0.1:8100/health
```

Expected: `{"status":"ok","users":0,"chaos_mode":"off"}`

Interactive API docs are at http://127.0.0.1:8100/docs. Keep that tab open;
you will use it constantly to check what the workflow actually did.

> Leave this window open too. You now have three: n8n, mock IdP, and a spare.

### Opening those windows without thinking about it

`uvicorn` and `n8n start` both hold their window forever, so you cannot type the
next command into the same one. From the second session onward, skip the manual
window juggling:

```bash
cd "D:\Claude Local\jml-orchestrator"; powershell -ExecutionPolicy Bypass -File .\scripts\start-all.ps1
```

That opens both servers in their own titled windows and leaves the window you
ran it from free for `curl` and `git`. To open a spare window by hand instead:
in Windows Terminal press **Ctrl+Shift+T** for a new tab, or press **Win+X**
and choose **Terminal**.

---

## 0.5 Get a Gmail app password

Approval emails go out over SMTP. Gmail needs an app password, not your login
password.

1. Go to https://myaccount.google.com/security
2. Turn on **2-Step Verification** if it is not already on. This is required;
   app passwords do not exist without it.
3. Go to https://myaccount.google.com/apppasswords
4. In **App name**, type `n8n-jml`. Click **Create**.
5. Copy the 16-character password it shows. Remove the spaces. You cannot view
   it again after closing the dialog.

---

## 0.6 Create the four n8n credentials

In n8n, open the left sidebar, click **Overview**, then the **Credentials**
tab, then **Add credential** (top right).

### Credential 1 — Postgres

Search for and select **Postgres**. Fill in exactly:

| Field | Value |
|---|---|
| Host | your Neon pooled host, e.g. `ep-cool-mud-a1b2c3d4-pooler.ap-southeast-1.aws.neon.tech` |
| Database | `neondb` |
| User | `neondb_owner` |
| Password | your Neon password |
| Maximum Number of Connections | `20` |
| Ignore SSL Issues | **off** |
| SSL | `require` |
| Port | `5432` |
| SSH Tunnel | **off** |

Rename it (click the name at the top) to **`JML Postgres`**. Click
**Save**. The connection indicator should turn green.

If it fails with `no pg_hba.conf entry` or an SSL error, confirm SSL is set to
`require` and that you used the pooled host.

### Credential 2 — Header Auth (mock IdP key)

**Add credential** → search **Header Auth** → select it.

| Field | Value |
|---|---|
| Name | `X-API-Key` |
| Value | `dev-mock-idp-key-change-me` |

Rename the credential to **`Mock IdP Key`**. Save.

> `Name` here is the HTTP header name, not a label. Getting this wrong gives
> you 401s later that look like a URL problem.

### Credential 3 — SMTP

**Add credential** → search **SMTP** → select it.

| Field | Value |
|---|---|
| User | your full Gmail address, e.g. `pgeagoni@gmail.com` |
| Password | the 16-character app password, no spaces |
| Host | `smtp.gmail.com` |
| Port | `465` |
| SSL/TLS | **on** |
| Disable STARTTLS | **off** |
| Client Host | leave empty |

Rename to **`JML SMTP`**. Save.

### Credential 4 — Google Gemini (needed from Stage 3 onward, do it now)

1. Go to https://aistudio.google.com/apikey
2. Click **Create API key**, choose **Create API key in new project**. Creating
   it in a *new* project matters: it auto-enables the Generative Language API.
   Keys created in an existing project without that API enabled return 401.
3. Copy the key.

In n8n: **Add credential** → search **Google Gemini** → select
**Google Gemini(PaLM) Api**.

| Field | Value |
|---|---|
| Host | `https://generativelanguage.googleapis.com` |
| API Key | the key you copied |

Rename to **`JML Gemini`**. Save.

---

## 0.7 Set the project defaults on every workflow

You will create nine workflows. Each one needs the same three settings. Do this
every time you create a new workflow, from the workflow editor:
**three-dot menu (top right) → Settings**.

| Setting | Value | Why |
|---|---|---|
| Error Workflow | `JML — Error Handler` (available after Stage 4) | Central failure alerting |
| Timezone | `Asia/Manila` | `due_at`, SLA maths, and Schedule triggers are all wrong otherwise |
| Save failed production executions | `Save` | You need failures in the execution list to debug |
| Save successful production executions | `Save` | Needed for the demo recording |
| Save manual executions | **on** | Otherwise test runs vanish |
| Timeout Workflow | **on**, 1 hour | A hung run must not sit forever |

---

## Stage 0 checklist — do not continue until all six are true

- [ ] `http://localhost:5678` loads the n8n editor and you are signed in.
- [ ] `%USERPROFILE%\.n8n\project-encryption-key.txt` exists and is backed up.
- [ ] The Neon SQL Editor returns 6 rows from the `role_entitlements` query.
- [ ] `curl.exe http://127.0.0.1:8100/health` returns `"status":"ok"`.
- [ ] `test_mock_idp.py` prints `mock IdP self-check passed`.
- [ ] Four credentials exist in n8n: `JML Postgres`, `Mock IdP Key`,
      `JML SMTP`, `JML Gemini`.

### Common Stage 0 errors

| Symptom | Cause | Fix |
|---|---|---|
| `n8n : command not found` after npm install | npm global bin not on PATH | Close and reopen PowerShell. If still missing, run `npm config get prefix` and add that folder to PATH. |
| n8n starts then exits with a Node version error | Node too new or too old | Install Node 22.20.0 via nvm as in 0.2 |
| Postgres credential red, `getaddrinfo ENOTFOUND` | Host typo, or you copied the whole connection string into the Host field | Host is only the part between `@` and `/` |
| Postgres credential red, `password authentication failed` | Password contains a character you dropped when copying | Reset the Neon role password and copy again |
| `curl.exe` gives "Could not resolve host" | You used `curl` (the PowerShell alias for Invoke-WebRequest) | Always use `curl.exe` with the `.exe` |
| Mock IdP returns 401 to everything | `MOCK_IDP_API_KEY` not set in the uvicorn window | Restart uvicorn with the `$env:` prefix shown in 0.4 |

Next: `02-stage1.md`.
