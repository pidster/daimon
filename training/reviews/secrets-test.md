# Review: secrets test set (`training/secrets/test.tsv`)

Reviewed 2026-09-26 against `training/secrets/labels.md`, `NOTICE.md` and `licenses/`, the builder's `unsure.tsv` (28 lines) and `build.py`, the source research in `secrets-datasets.md`, and `train.tsv` and `dev.tsv`. I read all 653 labelled lines. Line numbers are lines of the file, so the header is lines 1 to 11. Fixes are in `secrets-test/fixes.tsv`: 49 rows, of which 5 relabel, 8 drop and 36 edit. Every row matches exactly one line, and applying them all leaves 645 lines (211 secret, 219 personal, 215 none). Seven of the edits, the IP moves, are marked "optional, publication". The fix list does not cover the questions in "Needs a person".

**Verdict: usable after fixes.** The labels mostly follow labels.md, and the U+200B marking is nearly complete. Before this is pushed:

- One value is a token that gitleaks copied from a public repository.
- Nine placeholders in provider formats have no U+200B.
- Several lines keep the fixture's own verdict ("POSITIVE", "# FP").
- Four Privy lines carry FakeNameGenerator values, which NOTICE.md says were excluded.

The deeper limit is structural. Each label comes almost entirely from one family of sources, so the set partly measures whether a line looks like code or like a form.

## 1. Mislabels

- **246** `...please contact Emily at emily.gaskins@example.com, or use the pin 8948 to access the secure client portal.` is personal. The builder's reason is that "the pin reads as a portal code". But a code that opens a portal is a credential. Train labels `door code and alarm PIN is 4471` as secret, and this set labels the other PINs as secret (237 to 239, 450 to 452). Under rule 6 the line is secret. Fix: relabel to secret.
- **199** `curl -i -u 'test:test'` is secret. Train labels `jdbc:postgresql://localhost:5432/test?user=test&password=test` as none, which is the same stock test credential. Fix: relabel to none, for consistency with train. (If a person prefers secret, then train line 267 is the one that is wrong.)
- **373** `- **Date of Death:** 1967-04-20` is personal. NOTICE.md says "a date that is not a birth date is none", and labels.md lists only date of birth. Fix: relabel to none.
- **497** `Swift BIC Code: TRBVUSZN267` is personal. A BIC identifies a bank branch, not a person. Nothing else on the line is personal. Fix: relabel to none.
- **426** `"source_ip": "f4e3:..."` is none. Rule 4 makes an IP personal when it is tied to a client request, and a source IP is the client side. 403 and 494, which are bare IPs in a user record, are labelled personal. Fix: relabel to personal. 427 `destination_ip` stays none.
- **475** `:70:O12537849` is personal because the source spans it as a passport number. The line itself is a remittance-reference field of a SWIFT message, and no reader could tell. Fix: drop it, because a line nobody can decide measures noise.
- I checked the rule-6 cases and they are right: 150 (email and password), 193 (`j.smith:` and password), 235 (email and API key), 237 (user name and PIN), 450 (address and PIN), 451 (name and PIN).
- I checked placeholders, masks, key ids and public keys, and found no line in the wrong class. Placeholders and masks are none: 584 to 593, 603, 606 to 612, 616, 617, 620 to 625, 643, 650, 655 and 657. The partly masked `tgp_` at 666 is also none. Ids and public keys are none: 553 (a Vault accessor), 562, 563, 571, 579 and 583, the public keys at 565 and 598, 664 (`pk_test_`) and 667 (a Twilio SID). Secrets built from invented sequences are secret by rule 1 (186, 187, 207, 208), and so are default values in `getenv(..., "literal")` (47 to 49, 181).
- Role addresses, stock names and infrastructure IPs are handled right:
  - The stock placeholders are none: 498 to 501 (the John Doe template), 635 (`Nobody John Doe`) and 669 (`dummyuser@`).
  - The server and infrastructure IPs are none: 424, 425, 427, 442, 443 and 520.
  - A support contact given by a person's address stays personal (269, 325, 371, 375, 392). The address names a person, so this follows rule 3.

## 2. Inconsistency, and the 28 unsure lines

| Line | Builder | Verdict |
| --- | --- | --- |
| 96 `password = "0xAb…"` | secret | Agree. |
| 199 `curl -i -u 'test:test'` | secret | **none**, to match train (fixed). |
| 207 `DATABRICKS_TOKEN=dapi1234…` | secret | Agree (rule 1). |
| 208 `"token3": "xoxp-1234-…"` | secret | Agree. |
| 237 `…assigned a PIN of 9283.` | secret | Agree (train's alarm PIN). |
| 239 `- **PIN: 945076**` | secret | Agree. |
| 241 MAC address | personal | Agree, but labels.md has no rule for device ids; see "Needs a person". |
| 243 card and CVV | personal | Agree (train: `6011 1234 5678 9019 cvv 123` is personal). |
| 244 `The CVV code for this credit card is 641.` | personal | **Person.** A CVV alone identifies nobody, so personal is the wrong reason. It is closer to secret (card authentication data, like a PIN) than to personal. |
| 246 pin for a portal | personal | **secret** (fixed). |
| 313 password that "meets these requirements" | secret | Agree (rule 1). |
| 315 `"token": "brown2813"` | secret | Agree. The source calls it a user name, but it sits in the token field of the same record as 314. |
| 327 VIN | personal | Agree, but the rule is missing; see "Needs a person". |
| 449 "A sample Password is …" | secret | Agree. 444, where the values are named as *not* acceptable passwords, is none. That is a defensible split, but it is fine-grained. |
| 450 address and Account_Pin | secret | Agree (rule 6). |
| 453 `NAD+SU+…` supplier address | personal | **Person.** SU is the supplier, usually a business, so I lean none. |
| 469 latitude and longitude | personal | Agree (a claimant's home), but the rule is missing. |
| 475 `:70:O12537849` | personal | **Drop** (fixed). |
| 497 BIC | personal | **none** (fixed). |
| 500 `johndoe@email.com` | none | Agree with the label. The domain is real; fixed by an edit. |
| 517 bitcoin address | none | Agree (public by design, like a public key). |
| 521 "renowned designer, Sophie Delacroix" | none | **Person.** labels.md has no exception for public figures. 456 (a named head of safety) is personal, so I lean personal. |
| 526 IMEI | personal | Agree, consistent with 241. |
| 630 CSRF `authenticity_token` | none | Agree. It is served to every visitor and is not a session id. |
| 649 `ENC(…)` | none | Agree. Its comment gives the label away (fixed by an edit). |
| 666 `tgp_…xxxxxxxxxx` | none | Agree, weakly. 34 characters are visible, so the "masked" rule is being stretched. |
| 667 Twilio `AC…` SID | none | Agree (an account id, rule 7). |
| 668 WeChat app id | none | Agree. |

Other inconsistencies:

- **291** `The property has the PIN 776706.` is none, but Nemotron spans the value as a `pin`, the same span type as 237 and 239. A property identification number is not a credential, so none is defensible, but a reader could see it either way. See "Needs a person".
- **372** `Service located at 039 Holloway Round, …` is personal, while 308 (a polling place) and 309 (a company facility) are none. In the source document, this is where a hosted service is located, so it is closer to 309. I lean none.
- **631** `ntn_12345678901` is none, while 186 and 207 (invented sequences) are secret. The line is too short to be a Notion token, so none holds up, but the boundary between an invented sequence (secret) and a placeholder (none) is left to taste.

## 3. Shortcuts

- **U+200B predicts the label.** 207 of the 213 secret lines carry one, against 12 of the 218 none lines and none of the 222 personal lines. The six secret lines without one are PINs and `test:test`. A loader that keeps the character hands a classifier 97% of secret recall at 94% precision. `RiskExamples.parse` strips it. `TrainingSplit.parse`, which `wisp classifier split` and `baseline` use, keeps it on purpose and ignores it only when comparing lines. No secrets loader exists yet. Whatever measures this set must strip U+200B, and a test should pin that down.
- **Fixture verdicts left in the text.** NOTICE.md says the markers were removed, but they are still there:
  - "POSITIVE" and "positive" appear on six secret lines (57, 58, 93, 94, 148 and 154) and on 115.
  - "# FP" is on 673, "# looks like a key, but FP for aws multi" on 636, and "# this is encrypted key that should be not found" on 649.
  - The value "not-a-key-in-the-line" appears on 642.
  - Annotations naming the token type ("# Google OAuth Secret", "# Google API Key", and so on) are on 66 to 70.

  An on-device model used as a baseline (`scan --thorough`) reads English, so these lines tell it the answer. Fixed by edits (and by dropping 642).
- **Each label comes from its own sources.** 192 of the 213 secret lines come from CredSweeper and gitleaks, and 200 of the 222 personal lines come from Nemotron and Gretel. Outside the hard-negative slice, 192 of the 214 code-source lines are secret. The style of a source therefore carries the label:
  - Markdown bold: 44 personal lines, 16 none, 4 secret.
  - A line that ends in a full stop: 84 personal, 30 none, 12 secret.
  - A line of eight or more words: 105 personal, 56 none, 21 secret.
  - A bare token of one word: 76 secret lines.

  So a classifier that only tells code from prose scores well above chance. The none class is what stops it: 120 hard negatives in code and 65 none lines in prose. **For the measurements**, report recall by source and by slice, not only overall. Secret precision is flattering, because code-shaped lines that are none (ordinary config, logs and source) are almost absent outside the hard slice. Personal recall measures prose forms and documents, not logs: only 3 personal lines come from code sources, and there are 14 from Privy.
- CredSweeper's invented marker words ("gireogi", "Cr0ckle", "g1re0g1") appear only in secret lines (39, 63, 70, 97, 109, 111, 122, 144). Train has none, so no classifier can learn them. They are just unrealistic.
- `@example.` predicts personal (43 of 45). That is what rule 3 says, and train has the none counter-examples, so it is not a flaw of the set.

## 4. Publication safety

**Not safe to push as it stands; safe after the fixes below.** I checked every credential-shaped token with a script: `secrets-review/nozw.py` in the scratchpad. It runs about 60 provider patterns over the raw text, where a U+200B hides a match, and an entropy pass over whole tokens with no U+200B. I also ran `wisp scan` on the file raw, stripped of U+200B, and with the fixes applied.

- **220** `oc login --token=sha256~ZBMKw9VAayhdnyANaHvjJeXDiGwA7Fsr5gtLKj3-eh-` is a real token from a real project. gitleaks' `openshift.go` cites its origin: `github.com/IBM/tekton-tutorial-openshift/.../docs/lab1/0_setup.md#L85`. It has almost certainly expired. Even so, NOTICE.md says tokens "lifted from public repositories were left out". Fix: drop it.
- **Placeholders in push-protection formats without U+200B.** In the hard slice, 587, 590, 610, 611, 612 and 617 carry one, but nine similar lines do not:
  - 588 `GR1348941XXXX…` (GitLab runner)
  - 589 `glsa_XXXX…_AAAAAAAA` (Grafana service account: 32 characters and an 8-hex tail, which matches the pattern)
  - 593 `hvs.xxxx…` (Vault)
  - 594 `hf_xxxx…`
  - 606 `sha256~XXXXXXXXXX_PUT_YOUR_TOKEN_HERE_XXXXXXXXXXXX` (43 characters, which matches the OpenShift pattern)
  - 607 `pnu_` followed by 36 X (Prefect)
  - 650 `figd_xxxx…`
  - 664 `pk_test_…`
  - 667 `AC…` (Twilio SID)

  Some of these would pass validity checks, but a pattern match is enough to block a push. Fix: add a U+200B after the fourth character of each. After the fixes, the provider pass finds nothing without a U+200B, and `wisp scan` reports only 20 assigned-secret findings and 1 url-password finding, all on values that carry a U+200B.
- **Every secret-labelled credential value carries a U+200B.** The script found no provider match in a secret line. The one remaining partial match is the `atlasv1.` suffix on 73, whose 14-character prefix the U+200B breaks. The secret lines without a U+200B are PINs and `test:test`, which no scanner matches.
- **Real mail domains.** NOTICE.md moved only the Nemotron and Gretel addresses:
  - 150 `smtps://example@gmail.com:<password>@smtp.gmail.com` pairs a real, probably registered, mailbox with a password.
  - 222 `james.fake@ymail.com` is labelled personal.
  - 500 `johndoe@email.com` (email.com is a real provider).
  - 627 `src@gmail.com` and `dst@gmail.com`.

  Fix: edit all four lines to use example.com.
- **Routable IP addresses tied to people.** Rule 1 uses documentation ranges, but the third-party lines use routable addresses:
  - 250, 252, 290 and 403.
  - Three security-incident lines: 319 "attempted authentication from 216.158.70.128", 347 "168.108.109.164 was found to have accessed patient record …, a violation of our data privacy policy", and 394, which includes 3.106.11.32, an AWS address.

  These accuse whoever holds the address. Fix (optional): move them to documentation ranges. The infrastructure IPs in none lines (424 to 427, 442, 443, 520) are lower risk and are left alone.
- **Values that could belong to real people.** These are not in the fix list; a person should decide:
  - 20 SSNs are in issued ranges (for example 570-30-7083, 013-41-0633 and 524-77-3390). Rule 1 promises 9xx and 000.
  - About 25 US phone numbers are not 555, in real area codes (616, 907, 704, 509, 703, 602 and others).
  - Six card numbers pass Luhn and carry real issuer prefixes (343, 358, 384, 387, 479, 482).
  - All five IBANs have valid checksums.

  The sources are synthetic and already public under CC BY or Apache, so this adds little new exposure. But the set breaks labels.md's own synthesis convention, and a number like "Todd … 509-773-1090" may well ring a real phone. The options are to neutralise the values (which moves the test's value formats towards train's), or to keep them and say in the header that rule 1's value conventions do not hold for the third-party lines.
- The names are synthetic by the sources' account, and I found no real person tied to data. Some real public identifiers are harmless: the GPGTools public-key line (598), `vipul-<hash>.png` (609), `api.contoso.org`, `appsecclass.report`, and a Bank of America URL with a placeholder account (297).
- 204 `A3-ASWWYB-798JRYLJVD4-23DC2-86TVM-H43EB` is the example Secret Key from 1Password's whitepaper, as gitleaks notes. It is published but was never live, so keeping it is acceptable.

## 5. Licensing

- **CC BY 4.0 (Nemotron-PII): met.** NOTICE.md gives the title, the creators (Steier, Manoel, Haushalter and Van Segbroeck, NVIDIA 2025), the URL and revision, a link to the licence and its full text, and a list of the changes. It also has a no-endorsement line and says that the adapted lines stay under CC BY 4.0. The card has no copyright notice to keep. The test.tsv header points to NOTICE.md.
- **Apache-2.0 (both Gretel sets): met.** The licence text is included, the changes are stated in the file header and in NOTICE.md, neither card has a NOTICE file or a copyright line, and the citations match the cards. One small point: NOTICE.md gives the finance set's authors but not its title ("Synthetic-PII-Financial-Documents-North-America"). Apache does not require the title.
- **MIT (CredSweeper and gitleaks): met.** The copyright and permission notices match the upstream `LICENSE` files exactly.
- **Privy: MIT, with a caveat.** The card declares `license: mit` but gives no holder, and `Privy-MIT.txt` says so honestly. The generator itself is Apache-2.0 (The Pixie Authors). That does not govern its output, but NOTICE.md could say so.
- **Privy contains FakeNameGenerator (CC BY-SA 3.0) values, contrary to NOTICE.md.** presidio's `update_fake_name_generator_df` renames FNG columns to the Faker methods `state`, `state_abbr`, `city`, `zipcode`, `country_code` and `credit_card_expire`. `RecordGenerator` then serves those fields from the FNG record. Privy uses that record set in both branches of its constructor. The affected lines:
  - 547 (`"AL"`, `"US"` and `"36608"`, a matching Alabama ZIP from one record)
  - 548 (`"Texas"`)
  - 550 (`"Alexandria"`, `"VA"` and `"US"`)
  - 523 (`"expirationdate": "7/2026"`)

  Each value is a bare fact and probably not protected, but the NOTICE statement is wrong. Fix: drop 547, 548 and 550, and remove the `expirationdate` pair from 523. Otherwise, amend NOTICE.md.
- A few gitleaks fixtures are themselves lines from other projects: 606 from krkn-chaos/krkn, 629 from microsoft/windows-rs, and 220 from IBM's tutorial, which is dropped. They are too short to matter; this is noted for completeness.
- Nothing is included from a source whose licence forbids it. None of ai4privacy, SecretBench, CredData, TruffleHog or semgrep is used.

## 6. Realism and balance

- The label mix is 213 secret, 222 personal and 218 none. That is balanced, which is right for per-class recall. It is far from real use, where almost every line is none.
- About 76 secret lines (36%) are a lone provider-prefixed token. These test prefix recognition, which the rules already do. In practice tokens sit inside assignments, headers and URLs.
- The personal lines are LLM-written forms and documents (`**Consignor:** …`, "I, Nancy Bingham, born on …"), plus EDI, SWIFT and XBRL fragments. They are not logs, config or tickets. labels.md's own personal categories are missing altogether: **there is no `/Users/<name>/` home path and no private hostname** (`.internal`, `.corp`, `.lan`, `.local`), both of which train has (16 lines). Log-style personal lines (a login from an IP for a user) are rare.
- A rules baseline scores badly here. `wisp scan --personal` on the stripped lines flags 27 of the 213 secret lines and 36 of the 222 personal lines, because most provider formats and prose PII are outside its rules. The set can therefore show what a classifier adds, but not how it compares with a scanner on familiar formats.
- No sub-type dominates. Among the personal lines: 43 emails, 32 addresses, 28 phone numbers, 25 SSNs or national insurance numbers, 19 dates of birth, 17 card numbers, 17 IBAN or bank-account lines, and 13 licence, passport or plate numbers. PINs are 7 of the secret lines, and passwords are about 48. SSN template lines (`Social Security Number: NNN-NN-NNNN`) come up six times, which is fine.
- There are small clusters inside the set: 51 to 53 (one password in three syntaxes), 54 to 56, 158 to 160 (`IhqSb1Gg` three times), 135 and 136, and one Gretel record split into 314, 315, 402 and 403. Each is at most three lines, so I left them.
- 163 (`Test sample for "AWS Multi" rule`) is a fixture heading. Fixed by dropping it.

## 7. Overlap

`swift test --filter TrainingSetsTests` passes, so there are no exact, normalised, family or near overlaps. Beyond that check:

- **80** `b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQAAAAAAAAABAAAAMwAAAAtzc2gtZWQyNTUx` is the first 76 characters of dev line 43. It is the fixed header of every unencrypted ed25519 key. Fix: drop it.
- 79 `var PKEY = \`-----BEGIN OPENSSH PRIVATE KEY-----` has the same header as train's bare line. It is a different line, so I kept it.
- A word-Jaccard pass at 0.5 and a check for shared high-entropy values against train and dev found nothing else. Train and dev were written independently; this set's sources differ.
- After the fixes, no line equals a train or dev line even with U+200B and whitespace ignored.

## Format

Every line is `label<TAB>text` with a known label. There are no tabs in the text, no CRs and no duplicates, and the file ends with a newline. The header is accurate, except for two claims that the fixes make true: that the fixture markers were removed, and that public-repository tokens were left out. `training/README.md` still says "to come" for the secrets test set. It also says all test sets are "real data", which this one is not.

## Needs a person

1. **CVV policy.** Should 244 (CVV alone) be secret or personal? Card and CVV together stay personal, as train has it.
2. **Rules labels.md lacks**, each used by several lines:
   - bare account user names: 242, 247, 249, 251, 311, 340, 341, 402 and 493;
   - device ids: MAC 241, IMEI 526, VIN 327;
   - precise location: 469;
   - bank account, IBAN and routing numbers: about 17 lines;
   - public figures: 521.

   I would add "an account user name, a device id (MAC, IMEI, VIN), precise coordinates, and a bank account or IBAN tied to a person are personal; a bank code (BIC, routing number) alone is none".
3. **453** (EDI supplier address) and **372** (service location). I lean none for both.
4. **291** (a property PIN that the source spans as `pin`). I lean keeping none.
5. **Whether to neutralise** issued-range SSNs, non-555 phones, Luhn-valid cards and routable IPs (section 4), or to document the exception.
6. **482** `RFF*IM*4320419686216000` is Luhn-valid and Visa-shaped but sits in a reference segment. I kept it personal, because a scanner and a reader would both call it a card number.

## Most harmful problems

1. A real OpenShift token from IBM's public tutorial (220), which NOTICE.md says was excluded.
2. Nine placeholder tokens in provider formats with no U+200B, which could block the push.
3. Fixture verdicts left in the text ("POSITIVE", "# FP", "should be not found"), which give the label to any model that reads English.
4. Labels come from their own sources, so code-versus-prose style predicts the class. Report by source and slice. Personal in logs and paths is not measured at all.
5. Real mail domains paired with a password (150) or labelled personal (222), and routable IPs in lines that accuse someone of a breach (319, 347, 394).
6. FakeNameGenerator values in four Privy lines, against what NOTICE.md says.
