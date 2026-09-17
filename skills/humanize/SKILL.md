---
name: humanize
description: Strip the tells of machine-generated prose out of anything a human will read, using Wikipedia's "Signs of AI writing" catalog as the source of truth. Use for any non-trivial prose - PR descriptions, Jira tickets, commit message bodies, docs, READMEs, reports, and chat replies of more than a couple of sentences - and whenever the user says something reads like AI, sounds robotic, or needs to sound human. Also apply it to your own replies in the same conversation, without being asked.
metadata:
  category: writing-conventions
  source: https://en.wikipedia.org/wiki/Wikipedia:Signs_of_AI_writing
---

# Humanize writing

Wikipedia's WikiProject AI Cleanup read thousands of AI-written edits and catalogued the patterns that gave them away. This skill inverts that catalog: instead of using it to detect machine prose, use it to avoid producing any.

The full catalog is in `references/tells.md`, organized to mirror the source page. Read it before any substantial writing or editing task. The load-bearing parts are below.

## The one idea underneath all of it

The source page calls the mechanism **regression to the mean**. A model predicts the statistically likely continuation, so specific, rare, checkable facts get smoothed into generic, positive, common ones. The page's own example: "inventor of the first train-coupling device" becomes "a revolutionary titan of industry." The subject ends up simultaneously less specific and more exaggerated.

So every tell below is the same failure in a different costume: **generic filler standing where a specific fact should be.** "Plays a pivotal role in the broader ecosystem" is what *I do not have a fact here* sounds like when it is trying to sound confident.

The fix is almost never a synonym swap. Supply the missing specific, or delete the sentence. If a phrase would survive being pasted into a document about a completely different subject, it carries no information.

## The hard defaults

These have no legitimate use in ordinary prose. Do not produce them.

1. **Significance flourishes.** No "stands as a testament to," "plays a vital/crucial/pivotal role," "underscores the importance of," "marks a turning point," "cements its place as," "rich cultural heritage," "indelible mark," "deeply rooted." No manufactured "this has generated debate about" for subjects nobody is debating. State the fact and stop.

2. **Trailing "-ing" analysis.** No sentence ends with a bolted-on participle commenting on the sentence it hangs off: "..., highlighting its significance," "..., reflecting a broader trend," "..., further solidifying its role as," "..., ensuring a seamless experience." Cut at the comma. This and item 1 are the two the source page's editors single out as the strongest tells.

3. **Negative parallelism.** No "not just X, but Y," no "it isn't about X, it's about Y," no "not only... but also..." as decoration, and not the reversed "X rather than Y" either. Say what the thing is. Reserve contrast for correcting a misconception someone actually holds.

4. **Wrap-up paragraphs.** No "In conclusion," "In summary," "Overall," and no closing paragraph restating what the reader just read. End on the last real point. Chat replies end when the answer ends, with no "Let me know if you'd like me to expand on any of this."

5. **Editorializing asides.** No "it's important to note," "it's worth remembering," "no discussion would be complete without." Either the point deserves stating or it does not.

6. **Em dashes.** Use commas, colons, parentheses, or a full stop. Standing rule regardless of the rest of this skill.

7. **Formatting tics.** No title case in headings. No emoji as bullets or section markers. No mechanical `**Bold lead-in:** description` list items repeated down a page. No bolding every key term. No horizontal rule before every heading. No small tables for content that is two sentences of prose. No curly quotes pasted into plain-text contexts.

8. **Chatbot residue.** Nothing from the conversation layer reaches the deliverable: no "Certainly!", "I hope this helps," "You're absolutely right," "Feel free to adjust," "As of my last update," no `[insert detail here]` placeholders, no "Here is the draft you requested" wrapped around the draft.

9. **Fabrication.** Never invent a citation, DOI, ISBN, URL, statistic, quote, or named expert. Never write "industry reports suggest" or "experts argue" with nothing behind it. If a source is unknown, say so plainly or drop the claim. Do not claim something is "not widely documented" and then speculate about what it probably is; that whole move, including the claim of absence, is invention.

Items 4 and 5 are classed on the source page as **historical** indicators, common in 2022 to 2024 models and rarer now. They stay hard rules here because they carry no information either way.

## The judgment calls

Wikipedia is explicit that its list is descriptive, not a banned-words list. These appear constantly in good human writing. The tell is **density**, not any single instance.

- **AI vocabulary.** The actual overused set: additionally, align with, boasts, bolstered, crucial, delve, emphasizing, enduring, enhance, fostering, garner, highlight, interplay, intricate, key, landscape, meticulous, pivotal, robust, showcase, tapestry, testament, underscore, valuable, vibrant. The page says to take this **literally**: a word being overused does not implicate its synonyms, so do not extend the list by association. Context matters too. One in a page is nothing; three in a paragraph is a smell.
- **Rule of three.** Triads are a real device. The tell is reaching for a third item because the rhythm wants one when you only had two. Let list length follow content.
- **Inflated copulas.** "Serves as," "represents," "features," "boasts," "functions as" where "is" and "has" would do. Prefer the plain verb unless the fancier one earns its keep.
- **Elegant variation.** Do not rename the same thing three ways in a paragraph to dodge repetition. Repeating the plain noun reads as human.
- **Promotional adjectives.** Vibrant, rich, nestled, in the heart of, groundbreaking, renowned, diverse array. Fine occasionally; a cluster turns any subject into a tourism brochure.

## Positive habits, not just subtraction

Removing tells produces prose that is clean and dead. The source page lists these as empirically **more common in human writing**, because models avoid them reaching for formal register. Reintroducing them matters as much as the deletions.

- **Plain words over stiff synonyms:** wrote not authored, moved not relocated, used not utilized, tried not attempted, died not passed away.
- **Simple is/has constructions:** "there is a," "it has a."
- **Commit to a claim.** "One of the best," "is the only," "was the first." Say the thing directly, including when it is unflattering or contested. Machine prose is relentlessly positive and dodges controversy.
- **Keep the hedges.** "Very," "perhaps," "tends to" are human traits, not AI ones. Do not strip them on reflex. Same for ordinary wordy constructions: "as a result of," "in order to," "the fact that." Compressing every one of these is over-correction.
- **Concrete over abstract.** Keep the odd, specific, checkable detail. Resist smoothing it into a category.
- **Voice.** Match the person's actual register. In technical team communication that usually means short, direct, collegial, unpadded. Contractions are fine.
- **Let structure follow content.** Not every piece needs an intro, three body sections, and a close. Sometimes the answer is two sentences with no heading.

## Commit messages, PR descriptions, and ticket comments

The source page treats edit summaries as their own category, and it transfers directly. Four things to avoid:

1. **Canned assurances of compliance.** "Ensured the changes adhere to our conventions," "revised for consistency and maintainability." A human cites a specific rule briefly and links it. The vague version signals the writer did not know which rule applied.
2. **Mentioning what was preserved.** "Refactored the worker while preserving existing behavior and test coverage." Humans do not narrate the parts they did not touch.
3. **Gesturing at sources instead of content.** "Added sourced content" rather than what the content says. In a PR: "improved error handling" rather than which error and what now happens.
4. **Stating the obvious about feedback.** "Addressed reviewer feedback by improving X." Just say what changed.

Also: no first-person formal paragraphs, no verbose justification of a one-line change, no markdown or emoji where the target does not render it.

## Worked rewrites

**1. Significance flourish plus participle tail**
Before: The library, established in 1897, serves as a vital community hub and stands as a testament to the town's enduring commitment to literacy, further cementing its role as a cultural cornerstone.
After: The library opened in 1897. It has the county's only surviving card catalogue and still runs a Saturday reading group.

**2. Weasel attribution**
Before: Industry observers have noted that the framework offers a robust, scalable, and seamless developer experience.
After: The framework's docs claim sub-second cold starts. I have not benchmarked that.

**3. Negative parallelism and wrap-up**
Before: This isn't just a refactor, it's a rethinking of how we handle state. In conclusion, the change positions us well for future growth.
After: The refactor moves state out of the components and into a single store. That should make the already-filed caching bug fixable.

**4. Bold-lead-in list and heading bloat**
Before:
### Key Benefits
- **Performance:** Improves performance across the board.
- **Scalability:** Scales seamlessly with demand.
- **Maintainability:** Easier to maintain over time.
After: Three things get better: p95 latency drops from 800ms to about 200ms, the worker count can scale independently of the API, and the retry logic lives in one file instead of four.

**5. Commit body**
Before: Refactored the queue configuration to ensure alignment with best practices and improve maintainability, while preserving existing job behavior and retry semantics.
After: Move the lock duration and retry backoff into one config object. Same values as before, just no longer duplicated across four workers.

## Do not over-correct

The source page lists these as bad evidence for AI, and chasing them makes writing worse:

- **Transition words in isolation.** "Additionally," "Consequently," "Notably" were formulaically overused by older models, but the pattern predates LLMs and most style guides accept it. Not a strong tell. Do not purge every transition.
- **Perfect grammar**, **formal or academic register**, and **mixed casual/clinical tone** are all weak evidence. Register should follow the audience, not a detector.

Suppressing every listed pattern yields stiff, hollowed-out prose that reads more artificial, not less.

## When not to apply this

If the user asked for a specific template, house style, or format that conflicts with the above, their instruction wins. Say so and follow it rather than silently overriding.

This skill governs prose. It does not apply to code, config, structured data, or quoted material from a source, which must be reproduced accurately.

## Mechanical backstop

This plugin's `hooks.json` also runs an experimental `agent`-type `PreToolUse` hook on GitHub PR/issue body-writing commands and on `Write`/`Edit` to `README.md`/`docs/*` files, scoped only to the hard-defaults list above (not the density-based judgment calls). It's a backstop for when this skill wasn't actually applied, not a substitute for applying it - it can only deny and ask for a rewrite, not fix the text itself.
