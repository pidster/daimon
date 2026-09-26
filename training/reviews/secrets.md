# Review of secrets.tsv

**Verdict: usable after fixes.** Format is clean and most individual labels are right, but the set has a strong,
product-inverting shortcut in the secret class and several label-exclusive tells in the personal class. Trained
as it stands, the classifier would learn "contains EXAMPLE, FAKE, or the q8Lm2Nz4Kx7 filler" as secret and "contains
555, QQ, or a documentation-range IP" as personal. `fixes-secrets.tsv` has 153 fixes (99 edit, 3 remove, 1 relabel,
50 add). Every non-add line in it matches an existing line exactly, and every line has six fields (checked by script).

Counts: 573 examples (secret 170, personal 151, none 252), 69 comment lines. Line numbers below are file line
numbers.

## 1. Mislabels

- **440** `none  admin_password: admin`: this is an assigned admin password. In a deployed config it is a live
  credential, and it contradicts **61** (`admin_pw=letmein1`, secret) and **119** (`root:toor`, secret). Relabel it
  secret. Rule 2's placeholder list (changeme, xxxxxxxx, ...) does not cover "admin".
- **439** `none  password: password`: it could be a placeholder or a live weak password, and the line itself
  doesn't say which. Remove it.
- **490** `none  session-id header missing, generating 3c1b7e9a`: this prints a newly generated session id, which
  the file's own definition (line 6, "cookie or session id") calls secret. Edit it so it no longer prints the id.
- **161** `secret  ftp://anon:guest123@files.example.org/pub`: the `anon` user on `/pub` reads as anonymous FTP,
  where the password is conventionally not a credential. Edit it to a non-anonymous user.
- **312** `personal  upstream billing-api.prod.internal returned 503`, and the private-host lines in general
  (**307-311, 315, 364, 365**): these are labelled personal only because SecretScanner files private hosts under
  `.personal`. That keeps the set consistent with the product, but it tells the classifier that infrastructure
  topology is personal data. I left the labels alone. The header should say this is a product convention, not a
  definition of personal data, and hard negatives for generic `.internal`/`.local` names are added (below).
- **60, 202** (a bare `AKIA...` access key id, labelled secret) conflict with rule 7 (line 37: "key ids ... are
  none"). AWS documents the access key id as an identifier, not a secret. The scanner flags it, so the label
  matches the product, but rule 7 should name this exception explicitly.
- **138** `CURLOPT_USERPWD, "api:9f8e7d6c5b4a"` and **146** (`X-Auth-Token: 5e1c9a7f3b2d`) are correct. I note them
  only because the same hex runs appear in none lines (**468** `5e1c-9a7f3b2d8e4a`, **524** `5E:1C:9A:7F:3B:2D...`,
  **472** `nonce: 7f3a9c1e5b2d`, and secret **208** `7f3a9c1e5b2d8f4a`). The reuse is label-neutral, but it shows
  how templated the data is.

## 2. Inconsistency and rules to challenge

- **Default credentials.** **119** `root:toor@tcp(127.0.0.1...)` is secret, while **438**
  (`POSTGRES_PASSWORD=postgres`), **441** (`jdbc ... user=test&password=test` on localhost), **439** and **440**
  are none. It is the same situation (a known or default value on a local database) with opposite labels. The fix
  gives 119 a non-default value, relabels 440, removes 439, and keeps 438/441 as none because their dev/test
  context is explicit. An added line, `docker run -e POSTGRES_PASSWORD=Vy8-quill-3 ...` (secret), pairs with 438.
- **Rule 1 (lines 16-17) is the most harmful rule in the file.** It says EXAMPLE/FAKE markers are fine and that the
  label is what the line would be if live. wisp's own `SecretScanner.isPlaceholder`
  (harness/Sources/WispCore/Condense/SecretScanner.swift, lines 248-253) does the opposite: a value containing
  "example", "fake", "dummy" or "placeholder" is not a secret. Real text agrees with the scanner: `AKIA​IOSFODNN7EXAMPLE`
  and `wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY` sit in thousands of READMEs as placeholders. Line **58**'s value is
  exactly that AWS documentation secret with `EXAMPLEKEY` swapped for `FAKEKEY99`. It is also 39 characters, so it
  misses the scanner's 40-character aws-secret-key shape. **Proposed rule:** secrets carry no marker, and
  EXAMPLE/FAKE values are none (placeholders), which matches the scanner.
- **Rule 3** (line 25) deliberately diverges from the scanner's example.com skip. That is fine as stated, and
  example.com is spread across labels (secret 16%, personal 18%, none 10%), so it is not a tell.
- **Rule 5** (line 31) gives no ruling on public figures: **624** "a real person announced..." is none although it is a
  full name in context. State that named public or historical figures in public-fact sentences are none.
- **Rule 7** exempts Sentry DSNs (**527, 528**). That is reasonable, but Sentry DSNs have been documented as
  abusable for event spam. It's acceptable; I'm noting it.
- The rule for user names in home paths covers only `/Users/<name>/`, but `/home/<name>/` and
  `C:\Users\<name>\` identify a person just as much. The set has none of either, so the classifier will treat them
  as none. Adds are proposed for both, with CI and Public-profile hard negatives.

## 3. Near-duplicates and templated families

- **Filler strings.** `q8Lm2Nz4Kx7Pw1Rv5Tb8Yc3Hd6Jf0MsAe` or a prefix of it appears in 41 secret lines and 9 none
  lines, and the alphabet walk `aB1cD2eF3gH4iJ5kL6mN7oP8qR9s` appears in about 10 more. A classifier can memorise
  these few strings. Every secret occurrence is replaced by a random run with the same case pattern (79 automated
  edits; hex stays hex, base32 stays base32, AKIA ids stay uppercase).
- **Phones** (**233-242, 318, 324, 334, 338, 343, 349, 360, 366, 370**): 19 of the 20 personal phone numbers use 555,
  and the only none phone (**572**) is also 555. Keep them all, but rewrite five malformed ones (below) into other
  fictional ranges.
- **"Role: First Last"** (**257-270, 330-332, 340, 344, 352, 354, 366-370**, about 35 lines): the shape is fine, but
  45% of personal lines contain a capitalised "First Last" pair against 4% of none lines. Remove **332**, which has
  the same shape as 260 and 268, and add capitalised non-name hard negatives.
- **Cards** (**282, 284, 286, 291**) all use the `1234 5678` motif. Keep them, but the motif is a weak tell.
- **395/396**: two empty assignments of the same shape. Remove 396.
- **127-129**: three BEGIN private-key lines. That's fine, since they are distinct key types.

## 4. Leakage against RedactionEvalTests.swift

I compared every line against the eval fixture lines (SequenceMatcher on normalised text) and every quoted eval
value (substring search).

- **583** `none  [5/12] Compiling WispCore SecretScanner.swift` is a near-exact copy (similarity 0.83) of the
  "build output" fixture's kept text `[5/12] Compiling WispCore Agent.swift`. That is leakage: edit it to a
  different line.
- **No eval value** (Margaret Oyelaran, 88-2041-7736, 42 Wren Lane, db-prod-7.internal.acme.net, tomasz.kowalczyk,
  Priya Raghunathan, Owen Pritchard) appears in the training set.
- Shape-level near-leaks, with no action needed: **333** `Account 55-0192-8841 belongs to Ptolemy Harcourt` mirrors
  the ticket fixture's `(account 88-2041-7736)`, and **313** `logged in as rhiannon.pryce (uid 501)` mirrors
  `login ok for user tomasz.kowalczyk`. Both teach the eval's cases without copying them. They're acceptable, but
  should not be multiplied.

## 5. Realism and shortcut features

Feature rates by label, measured by script:

| Feature | secret | personal | none |
| --- | --- | --- | --- |
| `EXAMPLE` or `FAKE` | **47%** (80/170) | 0% | 6% |
| filler `q8Lm2Nz4Kx7...` | **24%** | 0% | 4% |
| 555 phone | 0% | 13% | 0.4% (placeholder only) |
| `QQ` (postcodes, NI numbers, reg plate) | 0% | **7% (11/11 occurrences)** | 0% |
| doc-range IP (192.0.2/198.51.100/203.0.113) | 0% | 8% (12) | 2 lines |
| capitalised "First Last" | 0% | 45% | 4% |

- **The EXAMPLE/FAKE marker is the most serious finding.** It separates secret from personal perfectly and nearly
  separates it from none. The rest of the product (isPlaceholder) and real-world text use it in the opposite
  sense. The fixes strip it from every secret line, and add none lines that carry EXAMPLE (the AWS documentation key
  pair and EXAMPLE-filled token shapes).
- **QQ** occurs only in personal lines: **244, 252, 253, 274, 275, 281, 288, 321, 339, 352, 371**. An added UK
  address without QQ dilutes it. Leaving it would teach "QQ ⇒ personal".
- **Doc-range IPs** occur almost only in personal lines (**293-300, 348, 356, 369, 373**); the none examples are
  **541** and **547**. Adds put doc-range IPv4 and IPv6 addresses into server and config contexts as none.
- **Self-labelling annotations** give the answer away: **572** "(placeholder)", **574** "(sample)", **611**
  "(city centre)", **613** "(documentation range)". Real text does not annotate itself, so the annotations are
  removed.
- **Lines no real tool produces:**
  - **189**: a traceback head and its final line joined by "...".
  - **362**: `Crashed Thread:` and `Path:` on one line, when crash reports print them on separate lines.
  - **229**: `example.nl.example.com`.
  - **234**: `(555) 014-2291`, where the exchange cannot start with 0.
  - **235**: `+1 555 0199 234`.
  - **238**: `555 0123 4567`.
  - **240**: `0555 123 4567`.
  - **241**: `+61 4 5550 1234`.

  The phone edits move numbers into the Ofcom (020 7946 0xxx, 0113 496 0xxx) and ACMA (0491 570 xxx) fictional
  ranges, or 555-01XX with a real area code.
- Minor tells: **85** `Tr0ub4dor&3` and **383** `correct horse battery staple` are the xkcd examples, widely quoted
  as examples. They're acceptable as assigned values, but don't add more. Many replaced uppercase markers still
  produce short all-caps runs; that is harmless.

## 6. Safety of the data

- **245** `[a real London address, removed]`: the postcode and street were a real institution's real address; replaced with an invented one.
  postcode, so a real address is presented as a person's flat. Edited.
- **248** (3-14-2 Yoyogi, Shibuya-ku 151-0053), **250** (Hauptstraße 47, 10827 Berlin) and **255** (Calle de Alcalá
  98, 28009 Madrid) are real streets with real postcodes, and probably real buildings. They're paired only with
  invented names, so the risk is low; replace them if the set is published.
- **624** names a real person, a real living person. Edited to Grace Hopper, matching **626** (Ada Lovelace).
- **518** and **519** are GitHub's real published host key and fingerprint. They're public and harmless, but real.
  **81**'s value is the FIPS-197 AES test-vector key, which is public.
- **Cards 282-286, 291, 372** are Luhn-valid (checked) with real network BINs, so a real card number cannot be ruled
  out; the chance is tiny. Prefer BINs from the issuers' published test ranges if the set is published.
- No key-shaped value looked like a live credential. All the high-entropy values are markers, fillers, zeros, or
  sequential hex. Decoded base64 (**101, 104, 167, 178, 180, 191**) gives only invented values.

## 7. Balance and coverage gaps

Balance (44% none, 30% secret, 26% personal) is reasonable. The gaps below are covered by 50 adds.

- **Secret** formats missing:
  - fine-grained `github_pat_`;
  - PGP and encrypted PKCS#8 private-key headers (**517**'s public block has no private pair, so `BEGIN PGP` reads
    as none);
  - `.pgpass`;
  - Azure storage connection strings;
  - Telegram and SendGrid tokens;
  - credentials in a package-index URL;
  - an API key in an access-log query string;
  - a JWT in a cookie;
  - `git credential fill` output;
  - `npm config set ..._authToken`;
  - a Rails initializer assignment;
  - a sudo here-string;
  - the `Authorization: token` scheme;
  - marker-free env and YAML keys.
- **Personal** gaps:
  - Linux and Windows home paths;
  - IPv6 client addresses;
  - URL-encoded emails;
  - a git log `Author:` line for a person (**570, 571** are bots only);
  - non-555 phones;
  - non-Latin-script names;
  - non-English contexts;
  - an address without QQ.
- **None** gaps:
  - EXAMPLE placeholders, including the AWS documentation key pair;
  - generic `.internal`/`.local` names (`host.docker.internal`, `metadata.google.internal`, an mDNS `local.`
    browse);
  - doc-range IPs as infrastructure;
  - capitalised non-names;
  - organisational phone numbers;
  - CI home paths;
  - the Windows Public profile;
  - doc IPv6 for servers.

## 8. Format

There are no problems. Every non-comment line is `label<TAB>text` with exactly two fields, and there are no unknown
labels, embedded tabs, empty texts, blank lines, or exact duplicates. Line **397**'s text begins with `#` after the
label, which is allowed.

## Summary of the most harmful problems

1. **The EXAMPLE/FAKE marker and filler strings are secret-only shortcuts** (80/170 and 41/170 secret lines, for
   example 47, 58, 64, 115, 145). They invert SecretScanner's placeholder rule and real-world usage, so the
   classifier would flag documentation placeholders and miss unmarked real keys. Rule 1 must change.
2. **Label-exclusive tells in personal**: 555 phones (19/20), QQ (11/11), doc-range IPs (12/14), capitalised
   name pairs (45% against 4%), and self-labelling annotations in none (**572, 574, 611, 613**).
3. **Default and weak credentials labelled inconsistently** (**119** secret against **438-441** none), plus
   **490**, a generated session id labelled none. Together they teach that weak or printed credentials are safe.
   The near-copy of an eval kept line (**583**) and a real institutional address (**245**) should also be fixed.
