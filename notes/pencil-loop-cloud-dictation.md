# Pencil Loop — use cloud dictation when online

**Status:** design note / not yet built
**Date:** 2026-08-21

---

## The note, in one line

When the device has a network connection, Pencil Loop should stop relying on
on-device dictation and send the recorded audio to a cloud ASR model instead.
The on-device path stays, but demoted to an offline fallback and an instant
first draft.

Latency is explicitly *not* a constraint here. A spoken margin comment is a
fire-and-forget act — you say it, you carry on annotating, you don't sit
watching the text appear. That buys us a lot: we can use batch (non-streaming)
models, which are both cheaper and more accurate than their realtime siblings,
and we can afford a second pass over the transcript before it's shown.

---

## Why the current on-device dictation is the weak link

Three separate problems, worth naming separately because they have different
fixes:

1. **Raw acoustic accuracy.** On-device models are small by necessity. If the
   app is still on `SFSpeechRecognizer` this is severe — measured WER around
   9% on clean speech and 16% on noisy speech. Apple's newer `SpeechAnalyzer`
   / `SpeechTranscriber` (iOS 26+) is a step change: roughly 2.1% clean and
   4.6% noisy, a 3.5–4× reduction on the same audio.
2. **No idea what the document is about.** This is the big one and no
   on-device model fixes it. A comment on a paragraph about Ofgem's RIIO-3
   price control will be transcribed by a context-free model as "Ofcom",
   "R I O three", or worse. The words that matter most in a review comment —
   names, statutes, case citations, acronyms, the author's own coinages — are
   exactly the words a generic model gets wrong.
3. **Far-field capture.** An iPad on a desk with a Pencil in hand is not a
   headset. The mic is a foot or two away, there's paper rustle and Pencil-tip
   noise. Small models degrade fastest here.

Cloud models fix (1) outright, and — crucially — the good ones can be *told*
about the document, which fixes (2). (3) is a capture problem and is worth
fixing regardless of where transcription happens.

---

## What "good" means for this app

Ranked, because these trade off:

| Priority | Requirement | Why |
|---|---|---|
| 1 | Proper nouns and jargon come out right | A wrong name makes the whole comment untrustworthy and needs a manual edit |
| 2 | Sensible punctuation and paragraphing | Comments get read back later, out of context |
| 3 | Verbatim-faithful — no invention | A review comment that says something you didn't say is worse than a garbled one |
| 4 | Works offline, degraded but working | The whole app is built around a synced folder, not a live connection |
| 5 | Reasonably quick — seconds, not minutes | "Relatively quick" per the brief |
| 6 | Cheap | It will be, at this volume. See costs below |

Explicitly *not* required: sub-second streaming latency, live word-by-word
display, speaker diarization (single speaker), word timestamps (nice for
audio-scrub-back, not essential).

---

## Architecture: draft, then upgrade

Don't make dictation a blocking network call. The app already lives in a
synced-folder world where things arrive when they arrive — lean into that.

```
Pencil tap → record audio ──┬─→ on-device transcribe → DRAFT shown instantly
                            │                          (works offline, always)
                            │
                            └─→ queue for cloud upgrade
                                     │
                                     ▼
                            cloud ASR (+ document keyterms)
                                     │
                                     ▼
                            LLM cleanup pass (+ document context)
                                     │
                                     ▼
                            FINAL replaces draft in the review file
```

Properties this buys:

- **Never blocks.** You always get text immediately, online or not.
- **Offline is not a special case**, just an upgrade that hasn't happened yet.
  Queue drains when connectivity returns.
- **Failure is invisible.** If the cloud call fails permanently, you keep the
  draft. Nothing is lost.
- **Audio is the source of truth.** Keep the clip until the upgrade lands (and
  optionally beyond) so any pass can be re-run later with a better model.

The one UX cost: text can change under the reader's eyes a few seconds after
they spoke. Handle it by marking drafts visually (a subtle italic / dotted
underline) that clears when the final lands, so a changing transcript reads as
"still settling" rather than "the app is broken".

---

## Where should the cloud call actually happen?

Three options. This is the main architectural fork.

### A. Straight from the iPad to the provider
Simplest. But it means a provider API key on the device, which is either
shipped in the binary (unacceptable) or provisioned per-user (a whole auth
system). Also puts model choice behind an App Store release.

### B. Via a small relay service
A thin server that holds the keys, fans out to providers, does the cleanup
pass, and returns text. Standard, flexible, swap models server-side without
shipping an app update. Cost: a service to run and pay for, plus device auth.

### C. Via the synced folder — the Mac side does the transcription  ← recommended
The iPad drops `clip-<id>.flac` + `clip-<id>.json` (its draft transcript, the
document id, the anchor) into the synced folder. A small daemon on the Mac
watches the folder, does the cloud call, writes `clip-<id>.final.json` back.
The iPad picks it up on next sync and swaps the text in.

Why this wins for *this* app:

- It is exactly the architecture Pencil Loop already has. No new transport, no
  new auth, no new service. Files in a folder, same as everything else.
- API keys live on the Mac, in the same place all the other keys live. Nothing
  secret on the tablet.
- "When I'm online" resolves neatly: it's the *Mac* that needs to be online,
  and it usually is. The iPad can be on a train with no signal and the upgrade
  still happens the moment the folder syncs.
- Model changes are a config edit on one machine, not an app release.
- The daemon has the document text right there on disk, which is what makes
  the context-biasing below trivial.

Downside: upgrade latency is bounded by sync round-trip, so tens of seconds to
a couple of minutes rather than 2–3 seconds. Given the brief explicitly
deprioritises speed, that's an acceptable trade. If it ever chafes, add option
B later as a fast path with C as the durable fallback — the queue model above
supports both without redesign.

---

## Stage 1 — capture

Worth getting right first; no model recovers information the mic threw away.
There's an existing mic eval harness — point it at this.

- **Sample rate:** capture at 48 kHz mono, downsample to 16 kHz only if the
  provider requires it. Never capture at 16 kHz directly if 48 is available.
- **Audio session:** `AVAudioSession` mode matters a lot. `.measurement`
  disables AGC and EQ, giving the model a clean unprocessed signal;
  `.voiceChat` applies aggressive processing tuned for calls, which can hurt
  ASR. Test both on real desk-distance audio — this is a measurable choice,
  not a guess.
- **Format on disk:** FLAC. Lossless, roughly half the size of raw PCM, and
  universally accepted by ASR APIs. If bandwidth ever matters, Opus at 32 kbps
  mono is effectively transparent for ASR — but don't go below that, and never
  transcode through a lossy format twice.
- **Endpointing:** use `SpeechDetector` / VAD to trim leading and trailing
  silence, but pad by ~300 ms each side. Aggressive trimming clips the first
  phoneme, which is a classic source of dropped first words.
- **Capture a little before the trigger.** Keep a rolling 1-second pre-roll
  buffer so a comment started a beat before the tap isn't truncated.

---

## Stage 2 — the cloud ASR call

### Provider comparison (Aug 2026)

| Provider / model | Batch price | Context biasing | Notes |
|---|---|---|---|
| **AssemblyAI Slam-1** | ~$0.30/hr tier | `keyterms_prompt`, up to 1000 phrases (≤6 words each) | Prompt-based speech language model. Understands the *meaning* of supplied terms, so it also helps on related/variant terminology, not just exact matches. Reports a 66% reduction in missed-entity rate with keyterms |
| **ElevenLabs Scribe v2 (batch)** | $0.22/hr, +$0.05/hr keyterms, +$0.07/hr entity detection | Keyterm prompting | Top-tier accuracy, strongest multilingual. ElevenLabs themselves recommend batch over realtime for recorded audio |
| **Deepgram Nova-3** | $0.0043/min (~$0.26/hr), +~$0.0013/min keyterms | Keyterm prompting, up to 100 terms | Fastest and cheapest of the serious options. Good fallback |
| **OpenAI gpt-4o-transcribe** | Token-billed ($2.50/1M in) | Freeform `prompt` param | Convenient if already in the stack. 25 MB upload cap, no timestamps, and a mid-2024 knowledge cutoff that hurts on recent names |
| **Gemini 3 Flash (native audio)** | Audio input ~$1.00/1M tokens | Full prompt — the entire document can go in | Not an ASR model, an LLM that hears. Collapses stages 2 and 3 into one call. See "one-stage vs two-stage" below |

Top-tier providers now sit within 1–2 points of each other on standard
benchmarks, so the benchmark numbers are close to noise. **The differentiator
for this app is context biasing, not baseline WER.**

### Recommendation

**Primary: AssemblyAI Slam-1, with keyterms drawn from the document.**
Pencil Loop's content is dense with proper nouns — policy, government, courts,
energy. That's precisely the failure mode Slam-1's keyterm prompting targets,
and its semantic (rather than literal string-match) handling of supplied terms
means the terms extracted from a document help on their variants too.

**Fallback: Deepgram Nova-3.** Cheap, fast, keyterm-capable. Used when the
primary errors or times out.

**Worth benchmarking against: ElevenLabs Scribe v2 batch.** On paper the
accuracy leader, and cheapest at the base rate. If it wins on the local eval
set, switch — the abstraction below makes that a one-line change.

Put all of this behind a `Transcriber` interface with `transcribe(audio,
keyterms, language) -> {text, confidences}`. Providers churn; the interface
shouldn't.

### Building the keyterm list — this is the whole trick

For each comment, the app knows exactly which document and which section it's
anchored to. So build the keyterms from:

1. **Section-local terms.** Capitalised sequences, acronyms, and unusual
   tokens from the anchored paragraph and its neighbours. Highest weight.
2. **Document-level terms.** The same, extracted across the whole document,
   deduped and frequency-ranked.
3. **A personal lexicon.** A persistent, accumulating list — names of
   colleagues, recurring organisations, project codenames, the words you
   correct by hand most often. Every manual edit to a transcript is a free
   training signal: if the raw ASR said X and you changed it to Y, Y goes in
   the lexicon. This gets quietly better every week with zero effort.
4. **Command words.** "strike that", "new paragraph", "end comment" — the
   verbal control vocabulary, so it's recognised reliably.

Cap at the provider limit (1000 phrases for Slam-1, 100 for Nova-3), ranked
1 → 4, so the truncation behaviour is sensible on the smaller-limit providers.

---

## Stage 3 — context-aware cleanup

This is what turns "pretty good" into "I never have to edit it", and it costs
almost nothing.

Take the raw transcript and send it to a cheap fast LLM (Haiku 4.5 or
equivalent) alongside:

- the paragraph the comment is anchored to, plus surrounding context
- the document title and a one-line summary
- the personal lexicon
- word-level confidence scores from the ASR, if available

Ask it to do **correction, not rewriting**. The prompt needs to be strict about
this — the failure mode is an over-eager model that "improves" your comment into
something you didn't say. Constrain it to:

- fix misheard proper nouns, acronyms, and technical terms using the document
  as ground truth
- resolve homophones by context ("their/there", "principal/principle")
- apply sentence punctuation, capitalisation, and paragraph breaks
- remove filler ("um", "uh", false starts) — but keep hedges, because "I think
  this is wrong" and "this is wrong" are different review comments
- execute verbal commands ("strike that" deletes the preceding clause)
- **change nothing else.** No rephrasing, no tightening, no tone changes, no
  adding content. If a passage is unintelligible, mark it `[unclear]` rather
  than guessing.

Two safety rails:

- **Always keep the raw transcript** in the review file. The cleaned version is
  a view, not a replacement. A long-press should reveal the original.
- **Gate on edit distance.** If the cleanup changed more than, say, 25% of the
  tokens, that's a red flag — surface the raw version instead, or flag it for
  review. This catches both LLM over-reach and the case where the ASR output
  was so bad the model effectively invented a comment.

### One-stage vs two-stage

The tempting shortcut: skip the ASR entirely, hand the audio and the document
to a native-audio LLM (Gemini 3 Flash, GPT-4o-transcribe) in a single call.
One request, full context, simpler pipeline.

**Recommendation: build two-stage, evaluate one-stage as a challenger.**
Two-stage keeps a verbatim, acoustically-grounded anchor, and restricts the
LLM to *editing* something rather than *producing* it. Native-audio LLMs are
prone to confident hallucination on quiet, clipped, or near-empty audio —
precisely the conditions a hurried margin comment produces — and requirement 3
above (no invention) is non-negotiable for a review tool. But the gap is
closing and the eval harness will tell the truth. Run both arms.

---

## Online / offline behaviour

- **Don't trust reachability flags.** "Has wifi" and "can reach the API" are
  different claims — captive portals, VPNs, and hotel wifi all lie. Attempt the
  call with a short timeout and treat failure as the signal.
- **Durable queue.** The pending-upgrade queue lives on disk (in the synced
  folder, under option C), so it survives app kills, reboots, and sync gaps.
- **Idempotency key per clip**, so a retry after an ambiguous timeout can't
  produce a duplicate charge or a duplicate comment.
- **Backoff:** retry at 2s, 8s, 30s, 2min, then hourly, then give up after 24h
  and keep the draft permanently. Log the give-up; don't surface it as an error
  unless it's happening repeatedly.
- **Metered-connection setting.** Default to upgrading on any connection —
  audio clips are tiny (a 20-second FLAC is a few hundred KB) — but expose a
  wifi-only toggle for people who care.

---

## Privacy

The documents going through Pencil Loop may be confidential work drafts. Moving
transcription off-device is a genuine change in the data's exposure, and should
be a deliberate, visible one.

- **Zero-retention mode.** AssemblyAI, Deepgram, and ElevenLabs all offer
  no-storage / no-training configurations. Enable them explicitly and record
  which is in force. Don't rely on a default.
- **Per-document `local-only` flag.** A frontmatter field in the document that
  pins it to on-device transcription regardless of connectivity, with a visible
  indicator in the app. Some documents should simply never leave the device.
- **Be careful what goes in the prompt.** The keyterm list and the cleanup
  context contain *document text*, not just audio. That's arguably a larger
  disclosure than the audio itself. Consider sending only the extracted terms
  rather than full paragraphs for sensitive documents — a term list leaks far
  less than prose.
- **Delete audio after successful upgrade** by default, with an opt-in to keep
  it for re-processing.
- **Say all of this in the UI once**, on first enable. Not buried in settings.

---

## What changes in the review file format

The review file needs to carry provenance, because there are now up to three
versions of every comment:

```json
{
  "id": "cmt-8fa2",
  "anchor": { "doc": "riio3-response.md", "section": "3.2", "ink": "ink-8fa2.png" },
  "text": "Ofgem's RIIO-3 framework doesn't cover this — worth a footnote.",
  "transcript": {
    "draft":  { "text": "...", "source": "on-device", "model": "SpeechTranscriber", "at": "..." },
    "raw":    { "text": "...", "source": "cloud", "model": "slam-1", "at": "..." },
    "final":  { "text": "...", "source": "cleanup", "model": "haiku-4.5", "at": "..." }
  },
  "audio": "clip-8fa2.flac",
  "edited_by_hand": false
}
```

`text` is whatever the best available version is. Consumers that don't care
about provenance just read `text` and are unaffected — so this is a backwards-
compatible addition. `edited_by_hand` matters: a hand-edited comment must never
be overwritten by a late-arriving upgrade.

---

## Evaluation

There's already an ASR eval harness — this should run through it rather than
being judged by vibes.

**Build a golden set of ~100 real clips.** Actual Pencil Loop comments, not
read-aloud LibriSpeech sentences. Include the hard cases deliberately: iPad at
desk distance, background noise, a mid-sentence restart, a comment that's
mostly a proper noun, a very short "yes, agreed", a 90-second rant.

**Metrics, in order of how much they matter:**

1. **Keyterm error rate** — WER restricted to proper nouns, acronyms, and
   technical terms. This is the metric that predicts whether you trust the
   output.
2. **Edit rate** — what fraction of comments needed a manual correction. The
   real-world metric, and the one to actually optimise. Instrument it in the
   app so it accumulates for free.
3. **Overall WER** — the standard number. Useful for catching regressions,
   nearly useless for choosing between top-tier providers.
4. **Hallucination rate** — fraction of outputs containing content with no
   acoustic basis. Should be zero. Test explicitly with silence, a cough, and
   a truncated word as inputs.

**Arms to compare:** on-device baseline; each cloud provider bare; each cloud
provider + keyterms; each + keyterms + cleanup; one-stage native-audio LLM.
The keyterms and cleanup deltas are the interesting numbers — they'll likely
dwarf the provider-to-provider differences.

---

## Cost

At a realistic 30 comments/day averaging 20 seconds, that's ~10 minutes of
audio a day, ~5 hours a month.

| Line item | Monthly |
|---|---|
| Slam-1 with keyterms, ~5 hrs | ~$1.50 |
| Cleanup pass, ~900 short calls | well under $1 |
| **Total** | **~$2–3** |

The conclusion is that cost is not a decision input at this volume. Optimise
purely for accuracy, and don't accept a worse model to save cents. Even a 10×
usage increase keeps this under a normal coffee.

---

## Rollout

**Phase 0 — free wins, no cloud involved.** If the app is still on
`SFSpeechRecognizer`, move to `SpeechAnalyzer`/`SpeechTranscriber`. That alone
is a 3.5–4× WER reduction and it improves the offline path too, which the cloud
work will never touch. Note the one regression: `SpeechAnalyzer` drops the
custom-vocabulary hints `SFSpeechRecognizer` had — the cleanup pass more than
compensates, but it's why Phase 0 alone isn't the whole answer.

**Phase 1 — capture quality.** Audio session mode, sample rate, format,
endpointing, pre-roll. Measure with the mic eval harness. Cheap, permanent,
benefits every later phase.

**Phase 2 — the pipeline skeleton.** Draft-then-upgrade, the durable queue, the
`Transcriber` interface, the extended review file format. Ship it with a
pass-through "cloud" provider that just returns the draft, so the plumbing is
proven before any provider is involved.

**Phase 3 — one cloud provider, no context.** Slam-1, bare. Measures the pure
acoustic-model delta.

**Phase 4 — keyterm extraction.** Where the real gain is. Expect this to beat
Phase 3's delta.

**Phase 5 — the cleanup pass**, with the edit-distance guard rail and the
raw-transcript escape hatch.

**Phase 6 — the personal lexicon learning loop.** Every hand-edit feeds back.
Compounds quietly.

Phases 0–2 are worth doing regardless of which provider ultimately wins. Phases
3–5 are where the eval harness earns its keep.

---

## Open questions

- **Which repo does this live in?** Written here for now because there's no
  `pencil-loop` repo in the account. Move it to the real home.
- **Is the on-device path already `SpeechAnalyzer`?** Determines whether
  Phase 0 is a big win or a no-op.
- **How reliable is the sync round-trip in practice?** Option C's viability
  rests on it. If the folder can be stale for hours, option B moves up.
- **Are non-English comments in scope?** If so, ElevenLabs Scribe v2 gains a
  meaningful edge — it leads on multilingual accuracy.
- **Should the cleanup pass see other comments on the same document?** It would
  help consistency of terminology across a review, at the cost of a bigger
  prompt and more disclosure.

---

## Sources

- [Best Speech-to-Text APIs in 2026: benchmarks, pricing, decision guide](https://futureagi.com/blog/speech-to-text-apis-in-2026-benchmarks-pricing-developer-s-decision-guide/)
- [Best STT Providers 2026: Independent Benchmarks (Coval)](https://www.coval.ai/blog/best-speech-to-text-providers-in-2026-independent-benchmarks-and-how-to-choose/)
- [AssemblyAI — Slam-1 public beta](https://www.assemblyai.com/blog/slam-1-public-beta)
- [AssemblyAI — Keyterms prompting docs](https://www.assemblyai.com/docs/pre-recorded-audio/improving-transcript-results-with-keyterms-prompting)
- [ElevenLabs — Introducing Scribe v2](https://elevenlabs.io/blog/introducing-scribe-v2)
- [ElevenLabs — Speech-to-text API pricing](https://elevenlabs.io/pricing/api)
- [Deepgram Nova-3 pricing explained](https://convertaudiototext.com/blog/deepgram-nova-3-explained)
- [Apple — Bring advanced speech-to-text to your app with SpeechAnalyzer (WWDC25)](https://developer.apple.com/videos/play/wwdc2025/277/)
- [Apple's new Speech API vs Whisper: first real benchmark](https://get-inscribe.com/blog/apple-speech-api-benchmark.html)
- [SpeechAnalyzer vs SFSpeechRecognizer](https://blakecrosley.com/blog/speech-framework-vs-sfspeechrecognizer)
- [GPT-4o Transcribe specs and pricing](https://gate.ai/blog/gpt-4o-transcribe-openai-specs-pricing-api-use-cases)
- [Gemini API pricing](https://ai.google.dev/gemini-api/docs/pricing)
