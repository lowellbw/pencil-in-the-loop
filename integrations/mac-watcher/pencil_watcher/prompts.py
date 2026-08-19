"""The text delivered into the receiving session.

Wave 3: tune the wording here. Each block below is a single named constant so
there is exactly one place to change.
"""

from __future__ import annotations

# The reply-channel instruction. docs/04 F6 and docs/05 describe an agent
# writing outbox/<slug>.review/reply.md, which the iPad app watches for and
# surfaces on the Sent screen. Writing that file is the receiving agent's job —
# the watcher only asks for it.
REPLY_CHANNEL_INSTRUCTION = (
    "When you have acted on this review, write your reply to "
    "{reply_path}\n"
    "as markdown. The iPad app watches for that exact file and shows it to the "
    "user on the Sent screen, where they can open it as a new document and "
    "annotate it in turn. Do not create any other file for the reply, and do "
    "not rename it. If you have nothing to say back, write a short "
    "acknowledgement there anyway — silence reads as a failure to the user."
)

# Opening line of the delivered turn.
DELIVERY_HEADER = "A pencil review came back from the iPad for “{title}”."

# How to read the anchors. docs/05 is explicit that this instruction measurably
# improves how reliably edits land, so it is repeated in the delivered turn and
# not left only inside review.md.
ANCHOR_INSTRUCTION = (
    "Each comment quotes exact text from the document you produced. Locate each "
    "one by matching the quote, never by line number — the document may have "
    "changed since it was sent."
)

# Pointer block used when the review is inlined.
BUNDLE_POINTER = "Full bundle (review.json, ink images, manifest): {bundle_path}"

# Used instead of the inlined review when review.md is too large to inline.
TOO_LARGE_NOTICE = (
    "The review is {size} characters, which is too large to inline. Read it "
    "from {review_path} before doing anything else."
)

INK_NOTICE = (
    "Handwritten pages are attached as images in {ink_path}. Position carries "
    "meaning — arrows and circles refer to the text they point at, and a "
    "strikethrough means delete. Read them alongside the comments."
)


def build_delivery_text(
    *,
    title: str,
    review_text: str,
    review_path: str,
    bundle_path: str,
    reply_path: str,
    ink_path: str = "",
    max_inline_chars: int = 40000,
) -> str:
    """Assemble the turn delivered into the receiving session."""
    parts = [DELIVERY_HEADER.format(title=title), ""]

    if review_text and len(review_text) <= max_inline_chars:
        parts.append(review_text.strip())
    else:
        parts.append(
            TOO_LARGE_NOTICE.format(size=len(review_text), review_path=review_path)
        )
    parts.append("")

    if ink_path:
        parts.append(INK_NOTICE.format(ink_path=ink_path))
        parts.append("")

    parts.append(BUNDLE_POINTER.format(bundle_path=bundle_path))
    parts.append("")
    parts.append(ANCHOR_INSTRUCTION)
    parts.append("")
    parts.append(REPLY_CHANNEL_INSTRUCTION.format(reply_path=reply_path))

    return "\n".join(parts).strip() + "\n"
