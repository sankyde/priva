# Security

Priva's promise is that nobody but the people talking can read what they exchange, and that nobody can tie a
purchase to a username. A flaw in either is the most important thing anyone can tell us about.

**Report privately** to hello@jexxa.org, with "Priva security" in the subject. Say what you found, how to
reproduce it, and what it lets an attacker do. Please don't open a public issue, and give us a reasonable time to
fix it before you publish: we'll reply within a few days and keep you updated.

In scope: the iOS app, the Supabase functions and migrations (`supabase/`), and the rendezvous relay
(`rendezvous/`). How Priva is designed to hold up is in [docs/SYSTEM_DESIGN.md](docs/SYSTEM_DESIGN.md) (threat model)
and [docs/SECURITY_VERIFICATION.md](docs/SECURITY_VERIFICATION.md). Known open items are in
[docs/audit/FIX_STATUS.md](docs/audit/FIX_STATUS.md) under "Decisions".
