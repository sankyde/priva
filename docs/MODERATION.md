# Moderation runbook

App Review requires that apps where people message each other let users **block** and **report** abusive people, and
that the developer **acts on reports within 24 hours** (App Review Guideline 1.2). This is how Priva does it without
reading anyone's messages.

## What the app does

| Action | Where | Effect |
|---|---|---|
| Block | Friend profile · friend request (⋯) · group member list | Their friend requests, messages, calls and group invites are dropped; their posts in shared groups are hidden. The 1:1 chat is deleted from this iPhone. Matched by username **and** identity key, so a rename doesn't get around it. They aren't told. Unblock in Settings → Privacy → Blocked. |
| Report | Same places | Opens an email to `PrivaSupportEmail` with the username, a reason, optional details and, only if the reporter leaves it on, that person's last ≤ 10 messages. The reporter's own username and messages are never included. No mail account → the report is copied (local clipboard, expires in 5 minutes). "Also block" is on by default. |
| Terms | Welcome screen, Settings | "By continuing you agree to the Terms of Use and Privacy Policy. Priva has zero tolerance for abusive content." |

Messages are end-to-end encrypted and never touch the server, so **a report is the only content the team ever sees**.

## Handling a report (target: within 24 hours)

1. Read the report. If the included messages show a breach of the Terms (harassment, threats, sexual content involving
   minors, spam/scams, impersonation, illegal content), remove the account.
2. Get the SQL:
   ```bash
   scripts/moderate.py remove <username>
   ```
   It derives the username's commitment exactly as the app does (the server never stores usernames) and prints:
   ```sql
   begin;
   insert into priva.retired_commits (ucommit) values ('…') on conflict do nothing;
   delete from priva.directory where ucommit = '…';
   commit;
   ```
3. Run it in the Supabase SQL editor.
4. Reply to the reporter (optional) and delete the report email.

**Effect:** nobody can find or add the username any more, it can never be registered again, and its friends' phones
show it as removed at their next directory check. What removal can't do (say so honestly if asked): messages already on
other people's iPhones stay there, and existing friends who don't block the person can still receive messages from
them over direct connections. Each purchase can register at most 3 usernames a month / 10 a year, which bounds
re-registration.

**Child sexual abuse material:** also report to NCMEC (CyberTipline, US) or the local equivalent, as the law where you
operate requires. Keep the report email only as long as the law requires.

**Mistakes:** `scripts/moderate.py restore <username>` prints the SQL that lets the name be registered again. The
removed keys can't be put back; the person sets Priva up again (or signs back in with their recovery phrase) and
their friends re-add them.

## Records

Keep a simple log (date, report id from the subject line, decision): no message content. Delete report emails once
the decision is made.
