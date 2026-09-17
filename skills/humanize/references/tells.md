# Full catalog of AI-writing tells

Derived from Wikipedia's "Signs of AI writing" (WikiProject AI Cleanup), reorganized from detection into avoidance. Section numbering mirrors the source page so items can be checked against it.

Read this before a substantial writing or editing job. Sections 6 and 7 are Wikipedia-specific and generalize only loosely; sections 9, 10, and 11 are the ones most people skip and most need.

- [0. What the source says about itself](#0-what-the-source-says-about-itself)
- [1. Content](#1-content)
- [2. Language and grammar](#2-language-and-grammar)
- [3. Style](#3-style)
- [4. Communication intended for the user](#4-communication-intended-for-the-user)
- [5. Markup](#5-markup)
- [6. Citations](#6-citations)
- [7. Comments and discussion posts](#7-comments-and-discussion-posts)
- [8. Edit summaries, commit messages, PR descriptions](#8-edit-summaries-commit-messages-pr-descriptions)
- [9. Signs of human writing](#9-signs-of-human-writing)
- [10. Ineffective indicators, do not over-correct](#10-ineffective-indicators-do-not-over-correct)
- [11. Historical indicators](#11-historical-indicators)
- [12. Miscellaneous](#12-miscellaneous)

---

## 0. What the source says about itself

Three framing points, stated on the page and easy to lose:

1. **Descriptive, not prescriptive.** The list is observations, not rules. Many of these appear in editorials, blogs, and fan fiction written by people.
2. **The signs are not the problem.** They point at deeper failures: unsourced claims, synthesis, fabrication, non-neutral tone. The page warns explicitly against treating the surface signs as the thing to fix, because polishing them away just makes the real problem harder to see. Fix the cause.
3. **Detection is hard.** A 2025 study found humans distinguish LLM text from human text at roughly chance. Heavy LLM users manage about 90%. Automated detectors have non-trivial error rates and are defeated by paraphrasing. Human and machine writing are also converging as people absorb LLM phrasing.

The core mechanism is **regression to the mean**. LLMs infer the statistically likely continuation, so specific, unusual, rare facts get smoothed into generic, positive, common ones. The page's example: "inventor of the first train-coupling device" becomes "a revolutionary titan of industry". The subject becomes simultaneously less specific and more exaggerated.

---

## 1. Content

### 1.1 Undue emphasis on significance, legacy, and broader trends

Named by editors as possibly the single strongest tell. Arbitrary details get tied to a broader topic, and the writing keeps announcing significance instead of showing it.

Words to watch: *stands/serves as, is a testament/reminder, a crucial/pivotal/vital/significant/key role/moment, underscores/highlights its importance/significance, reflects broader, symbolizing its ongoing/enduring/lasting, contributing to the, setting the stage for, marking/shaping the, represents/marks a shift, key turning point, evolving landscape, focal point, indelible mark, deeply rooted.*

Sub-patterns:

- **Manufactured debate.** Situating the subject amid broader "debates" or "discussions": "has generated debate about authenticity, consent and...", "prompted broader reflection on", "raising philosophical questions about".
- **Applied to mundane subjects.** Etymology and census figures get significance clauses too. Real example: a hispanized place name "highlights the enduring legacy of the community's resistance and the transformative power of unity in shaping its identity."
- **Hedged preambles that puff anyway.** "Though it saw only limited application, it contributes to the broader history of early aviation engineering."
- **Biology and geography.** Species writeups over-emphasize ecosystem connections even when tenuous, and belabor conservation status and preservation efforts even when the status is unknown and no efforts exist.

Fix: state the specific fact and stop. Delete the significance clause unless a source asserts it.

### 1.2 Canned emphasis on notability, attribution, and media coverage

Proving importance by hammering that a subject was covered somewhere, and specifying what kind of outlet. More common in tools released 2025 and later.

Words to watch: *independent coverage, local/regional/national media outlets, music/business/tech outlets, trade publications, profiled in, written by a leading expert, active social media presence.*

The page notes LLMs often misattribute their own superficial analyses to the cited source, and that "maintains an active social media presence" is particularly idiosyncratic to AI text.

Fix: report the fact once. Do not editorialize about what the coverage proves.

### 1.3 Superficial analyses

The other strongest tell. Empty analysis attached to a sentence end as a present participle ("-ing") phrase, sometimes with a vague attribution to a third party.

Words to watch (trailing): *highlighting/underscoring/emphasizing..., ensuring..., reflecting/symbolizing..., contributing to..., cultivating/fostering..., encompassing..., enhancing..., valuable insights, align/resonate with.*

Real example: "the population of Douera stood at approximately 56,998 inhabitants, **creating a lively community within its borders**... Douera enjoys close proximity to the capital city, Algiers, **further enhancing its significance as a dynamic hub of activity and culture**."

Note the retrieval-augmented variant: newer chatbots attach these to named sources ("Roger Ebert highlighted the lasting influence") regardless of whether the source says anything close.

Fix: cut at the comma. If the analysis is real, state it as a plain attributed claim.

### 1.4 Promotional and advertisement-like language

Drift into travel-brochure or press-release voice even when neutrality was requested. Happens when generating and when rewriting; an edit summary claiming to "remove promotional tone" may introduce it.

Words to watch: *boasts a, vibrant, rich, profound, enhancing, showcasing, exemplifies, commitment to, natural beauty, nestled, in the heart of, groundbreaking, renowned, featuring, diverse array.*

Subtypes called out: anything framed as "cultural heritage" gets constant reminders of its importance; people and companies get a press-release voice ("emphasized the airline's commitment to sustainability, customer focus, and Africa's prosperity").

Note: older models (GPT-4) skew blatantly positive; newer ones are more subtly positive and avoid obvious superlatives like "the best."

### 1.5 Vague attributions and overgeneralization of opinions

Opinions pinned on unnamed authorities, or a couple of sources inflated into consensus.

Words to watch: *Industry reports, Observers have cited, Experts argue, Some critics argue, several sources/publications* (when only a few are cited), *such as* (before exhaustive lists).

Also: mentioning multiple "reviewers" or "scholars" while citing one person; implying a list is non-exhaustive when the sources give no indication other examples exist; "described in scholarship as", "modern researchers treat".

### 1.6 Outline-like conclusions about challenges and future prospects

A rigid formula: "Despite its [praise], [subject] faces challenges, including..." resolving into vague optimism or speculation about future initiatives. Often a dedicated "Challenges" or "Future Prospects" section at the end.

Words to watch: *Despite its... faces several challenges..., Despite these challenges, Challenges and Legacy, Future Outlook.*

The page is explicit: the tell is the rigid formula, not the mention of challenges.

### 1.7 Leads treating descriptive titles as proper nouns

Defining a non-proper-name title as if it were a standalone entity. Examples from the page: "**Catchment area (health)** refers to the geographic area from which...", "The '**List of songs about Mexico**' is a curated compilation of musical works that...".

---

## 2. Language and grammar

### 2.1 High density of "AI vocabulary" words

Words to watch: *Additionally* (especially starting a sentence), *align with, boasts* (meaning "has"), *bolstered, crucial, delve, emphasizing, enduring, enhance, fostering, garner, highlight* (as a verb), *interplay, intricate/intricacies, key* (as an adjective), *landscape* (as an abstract noun), *meticulous/meticulously, pivotal, robust, showcase, tapestry* (as an abstract noun), *testament, underscore* (as a verb), *valuable, vibrant.*

By era:

- **2023 to mid-2024 (GPT-4):** Additionally, boasts, bolstered, crucial, delve, emphasizing, enduring, garner, intricate/intricacies, interplay, key, landscape, meticulous/meticulously, pivotal, underscore, tapestry, testament, valuable, vibrant.
- **Mid-2024 to mid-2025 (GPT-4o):** align with, bolstered, crucial, emphasizing, enhance, enduring, fostering, highlighting, pivotal, showcasing, underscore, vibrant.
- **Mid-2025 on (GPT-5):** emphasizing, enhance, highlighting, showcasing, plus the notability vocabulary in 1.2.
- **Grok:** overuses superficially scientific words: causal, empirical, correlate, and still underscore as of 2026.

Two rules the page states directly and that are easy to violate:

- **Take the list literally.** A word being overused by AI does **not** imply its synonyms are overused. Do not extend this list by association.
- **Context matters.** "Underscore" can mean a literal underline or incidental music.

One or two of these is coincidence. A cluster is one of the strongest tells, because they co-occur.

### 2.2 Avoidance of basic copulatives

Replacing *is/are/has* with inflated verbs. One study found a 10%+ drop in "is" and "are" in academic writing in 2023, and the same decline shows up on Wikipedia.

Words to watch: *serves as/stands as/marks/functions as/represents [a], boasts/features/maintains/offers [a], refers to.*

Real diff from the page: "Gallery 825 on La Cienega Boulevard **is** LAAA's exhibition **arm**... **There are four** individual gallery spaces" was AI-edited into "Gallery 825 on La Cienega Boulevard **serves as** LAAA's exhibition **space**... The gallery **features** four separate spaces."

More elaborate modern variants: *ventured into politics as a candidate* (was a candidate), *began his career as* (was), *holds the distinction of being* (is).

Watch the lead-sentence dodge: writing *X refers to...* as though the article were about the term rather than the thing.

### 2.3 Negative parallelisms

Three shapes:

- **Not just X, but also Y:** "Not only... but...", "It is not just..., it's...". "This choice of language is not only dismissive but also unnecessarily harsh."
- **Not X, but Y:** "It's not..., it's...", "no..., no..., just...". "Kusama's self-portrait is not a mirror but a portal: not a representation of self, but a mechanism for its constant reinvention." "Not a career, not a body of work, not sustained relevance, just an algorithmic moment."
- **X rather than Y:** the reversed form, particularly common in Grok output. "prioritizing empirical consolidation of power amid fragmented loyalties rather than ideological purity."

The output reads as though it is correcting a misconception the reader never had. Common in human "myths busted" listicles, but stereotypically an AI sign.

### 2.4 Rule of three

Reflexive triads: "adjective, adjective, adjective" or "short phrase, short phrase, and short phrase". Used to make superficial analysis look comprehensive. From a real example: "tiles, metals, and plastics", "drywall, plywood, and other construction materials", "model making, woodworking, and other craft projects", stacked down a page.

### 2.5 Lexical diversity and elegant variation

Generative AI has a repetition penalty, so the same thing gets renamed repeatedly. In the page's example, one paragraph cycles through "non-conformist artists", "these artists", "like-minded artists", "Russian avant-garde artists" and separately "their creativity", "the immense talent", "their artistic aspirations", "his distinctive artistic vision".

Caveat the page adds: non-native English speakers often avoid repetition deliberately. Italian schools, for instance, teach it.

---

## 3. Style

### 3.1 Title case in headings
Capitalizing all main words: "Impact of Technology and Digitalization", "Human Rights and Economic Law". Sentence case is the human default in most contexts.

### 3.2 Overuse of boldface
Inherited from readmes, fan wikis, how-tos, sales pitches, slide decks, and listicles: every instance of a chosen term bolded, often "key takeaways" style. Some newer models have instructions to suppress this.

### 3.3 Inline-header vertical lists
The `**Bold lead-in:** description` pattern, repeated mechanically, where the bolded phrase is then reworded in the sentence after it. Bullet markers may appear as literal characters (•, -, –, #, emoji) rather than real list markup. Sometimes there is no punctuation separating the header from its text.

### 3.4 Overuse of em dashes
Used where humans would use commas, parentheses, colons, or hyphens, in a formulaic "punched up" sales cadence that over-emphasizes clauses and parallelisms. AI em dashes are usually space-surrounded, contrary to typographic convention.

The page hedges this one: most useful in combination with other signs, much more common on discussion pages than in article text, and OpenAI's GPT-5.1 now suppresses them.

### 3.5 Emoji as formatting
Emoji placed in front of section headings or bullet points. Mostly seen on talk pages and in edit summaries; rarer now.

### 3.6 Unusual use of tables
Small unnecessary tables for content better handled as prose or an infobox. Two-row "Key Statistics" tables, four-row staff-name tables, feature-comparison tables built from thin material.

### 3.7 Curly quotation marks and apostrophes
ChatGPT and DeepSeek typically emit curly quotes and curly apostrophes, sometimes mixed inconsistently with straight ones.

Weak signal on its own. Chicago style, Microsoft Word's smart quotes, macOS and iOS defaults, LanguageTool, professional typesetting, and citation tools all produce them. The page notes **Gemini and Claude models typically do not use curly quotes.**

### 3.8 Skipping heading levels
Starting sections at level 3 and skipping level 2.

### 3.9 Thematic breaks before headings
A horizontal rule (`---` or `----`) inserted before each heading. Common in Markdown output.

---

## 4. Communication intended for the user

Conversation-layer text leaking into the deliverable. Unambiguous, so never produce it.

### 4.1 Collaborative communication
Words to watch: *I hope this helps, Of course!, Certainly!, You're absolutely right!, Would you like..., is there anything else, let me know, more detailed breakdown, here is a.*

Also: text meant as advice about the deliverable rather than the deliverable ("If you plan to add this information to the X section, ensure that the content is presented in a neutral tone"), and instructions to the user left in HTML comments ("Delete this section before submission").

### 4.2 Knowledge-cutoff disclaimers and speculation about gaps in sources
Words to watch: *as of [date], Up to my last training update, as of my last knowledge update, While specific details are limited/scarce, not widely available/documented/disclosed, in the provided/available sources/search results, based on available information.*

The page flags the modern retrieval-era version as the more dangerous one: when the model cannot find sources, it says the information "is not publicly available" and then speculates about what it "likely" is and why it matters. The claim that something is undocumented is itself speculation. For people, this shows up as inventing that the subject "maintains a low profile" or "keeps personal details private".

### 4.3 Phrasal templates and placeholder text
Fill-in-the-blank slots left unfilled: `[Describe the specific section that needs editing]`, `[Specific Topic]`, `[Your Name]`, `[Entertainer's Name]`, `INSERT_SOURCE_URL_30`, `PASTE_SPOTIFY_TRACK_URL_HERE`, `access-date=2025-XX-XX`, `<!-- Add if available with citation -->`.

---

## 5. Markup

Wikipedia-specific in detail, general in principle: never emit formatting or reference syntax belonging to a different system than the one you are writing for.

- **Markdown where it does not render.** Asterisks, hashes, and backticks pasted into wikitext, plain-text email, or any non-Markdown target. `##` used as a heading in a system that reads it as a numbered list. A stray ```` ```wikitext ```` fence.
- **Reference-tracking artifacts.** ChatGPT: `:contentReference[oaicite:0]{index=0}`, `oai_citation`, `Example+1`, `turn0search0`, `turn0image0`, `({"attribution":{"attributableIndex":"1009-1"}})`. Gemini: `[cite: 17]`, `[span_1](start_span)`. Grok: `<grok-card data-id=...>`, `grok_render_citation_card_json`. DeepSeek: lenticular brackets and daggers, `【85†L261-269】`. Perplexity: `[attached_file:1]`, `[web:1]`, `ppl-ai-file-upload` S3 URLs. Unclassified: `:::writing{variant="document" id="68427"}`.
- **Invented categories, templates, and parameters** that sound plausible but do not exist, or that were renamed or deleted after the model's cutoff.
- **utm_source=** tracking left on URLs: `utm_source=chatgpt.com`, `utm_source=openai`, `utm_source=copilot.com`, `referrer=grok.com`. The page notes this near-definitively proves ChatGPT touched the URL, but not that ChatGPT wrote the prose.

---

## 6. Citations

Where the surface tells connect to real harm. Everything here is a correctness failure, not a style preference.

- **Broken external links**, especially several in one new document, and especially when the dead URLs are not in the Internet Archive either.
- **Invalid DOIs and ISBNs.** ISBN checksums fail; DOIs do not resolve.
- **DOIs that resolve to an unrelated paper.** The page's worked example fabricates two *Proceedings of the IEEE* citations with real-looking DOIs pointing elsewhere, one attributed to an author who had been dead for 30 years at the purported publication date.
- **Book citations with no page number and no URL**, on a general topic frequently referenced in its field. Also: real book, real page number, but the page does not contain the claim.
- **Incorrect reference reuse**, references declared but never used inline, named references used but never defined, `↩` characters left around footnotes.

Rule: never generate a citation you have not actually seen. Say what is unverified.

---

## 7. Comments and discussion posts

Beyond the general signs, people posting LLM-written comments tend to:

- Misquote policies and cite made-up shortcuts that lead nowhere.
- Post lengthy comments divided into titled sections and subheadings.
- Assure the reader that their content adheres to the rules, or that they are trying to make sure it does.
- Ask the reader to tell them exactly what they need to improve.
- When called out, accuse the accuser of speculating from writing style and demand stronger proof.

---

## 8. Edit summaries, commit messages, PR descriptions

The page treats edit summaries as their own category, and it transfers directly to commit messages, PR descriptions, and ticket comments. AI-written summaries are formal first-person paragraphs, avoid abbreviations, and echo the exact wording of the relevant policy or the tag they are addressing. They mention things they "ensured" or "avoided" and give verbose justifications for minor changes.

Four specific sub-tells:

1. **Canned assurance of compliance.** *ensured that... adheres to, improved, in compliance with, revised, verifiability, neutrality, neutral tone, encyclopedic tone.* A human citing a rule does it briefly and specifically with a link ("removed excessive links per MOS:OVERLINK"); the AI version is more verbose and less specific, because the person prompting it did not know which rule applied. The more assurances stacked into one summary, and the wider the variety of improvements claimed, the stronger the sign.
2. **Mentioning what was preserved.** *preserved/preserving, retained/retaining.* It is unusual for a human summary to mention material that was not touched. It is exactly what you get from a model told to change X while preserving Y. Usually paired with sub-tell 1: "Revised for neutrality while preserving the original meaning and technical details."
3. **Overemphasis on the presence of citations.** *added sourced content, added coverage/citations/references, improved attribution.* A human describes what the prose says ("added info about the artist's debut") rather than gesturing at the source it hangs off.
4. **Stating the obvious about review feedback.** "Addressed reviewer feedback by improving sourcing, formatting, and neutrality." A human would not feel the need to say it.

The page adds: an AI edit summary strongly implies the edit itself is AI, since nobody automates the one-line summary but hand-writes the hard part.

---

## 9. Signs of human writing

The positive half of the work. The page lists these as empirically **more common in human writing** than in AI output, because LLMs default to what they consider formal encyclopedic tone and avoid them. Reintroducing them matters as much as deleting the tells.

- **Simple is/has phrases:** *there is a, it has a.*
- **Plain words over stiff or euphemistic synonyms:** *wrote* not *authored*, *moved* not *relocated*, *used* not *utilized*, *tried* not *attempted*, *died* not *passed away*.
- **Superlative or definitive statements:** *one of the best, is the only, was the first.* Committing to a claim rather than hedging around it.
- **Hedging qualifiers and intensifiers:** *very, perhaps, tends to.* Note the direction here. These are a human trait, not an AI one. Do not strip them out.
- **Isolated wordy constructions:** *as a result of, in order to, all of the, a part of, the fact that.* Also human. Do not compress every one of these on reflex.

Two other human signals the page names:

- **Age.** Anything written before ChatGPT's public launch on 30 November 2022 is not AI, however much it resembles it.
- **Ability to explain one's own editorial choices.** A writer can say why they made a decision or how a mistake happened. If a URL looks fabricated, ask; a human can produce the right link or the relevant passage.

---

## 10. Ineffective indicators, do not over-correct

The page lists these as bad evidence. They matter here because avoiding them makes writing worse, not more human. False accusations drive people away, and the page warns against confirmation bias and the Dunning-Kruger effect in would-be detectors.

- **Perfect grammar.** Plenty of people write well.
- **Transition words in isolation.** *Additionally, Consequently, Notably* at the start of sentences were formulaically overused by older models, but only a few transitions are affected, the pattern predates LLMs in essay writing, and many style guides accept it. **Not a strong tell.** Do not purge every transition.
- **Mixed casual and formal register**, or prose that reads both clinical and emotional. Can indicate a technical writer, youth, playfulness, neurodivergence, or simply multiple authors.
- **"Bland" or "robotic" prose.** LLM output has specific traits and skews positive and verbose; it does not necessarily scan as robotic.
- **"Fancy", "academic", or "formal" prose.** LLMs overuse *specific words*. The correlation does not extend to formal register generally.
- **Unsourced content.** Over 570,000 Wikipedia articles are tagged as needing citations and most predate LLMs. Modern chatbots add citations readily; the citations are just often wrong.
- **Bizarre markup or, conversely, correct markup.** Random-seeming HTML tags and misplaced syntax usually indicate a browser extension or a visual editor. Getting complex formatting right is normal for someone using a preview button.

---

## 11. Historical indicators

Common in older models, much rarer now. Still worth avoiding, but they are dated tells rather than live ones.

- **Didactic disclaimers (Nov 2022 to 2024):** *it's important/critical/crucial to note/remember/consider, worth noting, may vary.* Advice to an imagined reader about safety, controversy, or jurisdictional variation. Appears in OpenAI's GPT-4 system card as an example of partial refusal.
- **Section summaries:** *In summary, In conclusion, Overall,* and "Conclusion" sections that restate what was just said.
- **Prompt refusal:** *as an AI language model, as a large language model, I cannot offer medical advice but I can..., I'm sorry.*
- **Abrupt cut offs** from hitting a token limit mid-sentence.
- **Outdated access-date parameters** on citations, older than the edit that added them.

---

## 12. Miscellaneous

- **Pronounced shift in writing style.** A sudden jump to flawless grammar relative to someone's other writing. Also a mismatch between the author's location, the topic's national ties, and the variety of English used: several LLMs default to American English unless prompted otherwise. The page cautions that non-native speakers mix varieties anyway, and that code switching between venues is normal. Only a dramatic, unexplainable shift counts. Note also that a long-time AI user's writing changes in parallel with the tools: their 2023 text reads like 2023 output, their 2025 text like 2025 output.
- **Canned user pages / about pages.** "Welcome To My User Page!", "About Me", "My Interests", "What I'm Working On", "Let's Connect!", with emoji headers and bolded bullets.
- **Submission statements.** Text addressed to a reviewer explaining why the work qualifies, which the reviewer did not ask for and which only reveals its origin.
- **Pre-placed maintenance templates**, including ones set to states that make no sense.
- **Differences between models.** Each model has an idiolect. Focusing on broader context is more ChatGPT and Grok than Gemini and Claude. Gemini and Claude responses tend to be more concise than ChatGPT and Grok. ChatGPT is probably the most widely used for Wikipedia edits.

---

## How to use this without wrecking the prose

1. Read for meaning first. Note the core facts and the author's stance.
2. Sweep for clusters, not single hits. Density is the signal.
3. Fix the cause, not the surface word: restore a specific fact, name a real source, cut an empty significance claim. The page warns that polishing the signs away without addressing the underlying problem just makes the real damage harder to find.
4. Preserve meaning, facts, figures, quotes, and voice.
5. Reintroduce section 9. Subtraction alone leaves the prose clean and dead.
6. Leave section 10 alone.
