# Briefly Capture Capabilities Audit

Tested 28 July 2026 against `Tools/extractor/extract.mjs`, the extraction path
used by Briefly. The audit used public, signed-out requests with no workspace
input extensions and no authenticated transcription fallback. The 18 native
failure/partial cases were then retested after adding the Firecrawl fallback.

## Native baseline

| Verdict | Count | Share |
|---|---:|---:|
| Success | 35 | 66.0% |
| Partial | 1 | 1.9% |
| Failure | 17 | 32.1% |
| **Total** | **53** | **100%** |

“Success” means the extracted text meaningfully represents the linked primary
content. “Partial” means the result is useful but materially incomplete.
“Failure” includes thrown errors and false successes where only an interstitial,
login shell, or generic platform title was returned.

## Current result with Firecrawl

| Verdict | Count | Share |
|---|---:|---:|
| Success | 40 | 75.5% |
| Partial | 2 | 3.8% |
| Failure | 11 | 20.8% |
| **Total** | **53** | **100%** |

Firecrawl recovered five former failures and made the Cloudflare result useful
but incomplete. The fallback also rejects its own 404, gateway, verification,
and other error shells instead of turning them into false captures.

## Detailed matrix

| # | Content type | Tested link | Verdict | Extractor | Words | Observation |
|---:|---|---|---|---|---:|---|
| 1 | Static HTML | [Example Domain](https://example.com/) | Success | generic-html | 19 | Complete visible page text. |
| 2 | English article | [Wikipedia: Web scraping](https://en.wikipedia.org/wiki/Web_scraping) | Success | generic-html | 4,041 | Main article body retrieved. |
| 3 | Japanese article | [Wikipedia: ウェブスクレイピング](https://ja.wikipedia.org/wiki/%E3%82%A6%E3%82%A7%E3%83%96%E3%82%B9%E3%82%AF%E3%83%AC%E3%82%A4%E3%83%94%E3%83%B3%E3%82%B0) | Success | generic-html | 69 | Main body retrieved; whitespace word counts undercount Japanese. |
| 4 | API documentation | [MDN Promise reference](https://developer.mozilla.org/en-US/docs/Web/JavaScript/Reference/Global_Objects/Promise) | Success | generic-html | 3,655 | Main documentation retrieved cleanly. |
| 5 | Technical specification | [RFC 9110 HTML](https://www.rfc-editor.org/rfc/rfc9110.html) | Success | generic-html | 64,004 | Full specification retrieved. |
| 6 | Programming tutorial | [Python tutorial](https://docs.python.org/3/tutorial/index.html) | Success | generic-html | 884 | Landing-page tutorial content retrieved. |
| 7 | Government guidance | [GOV.UK Netherlands travel advice](https://www.gov.uk/foreign-travel-advice/netherlands) | Success | generic-html | 166 | Primary landing-page guidance retrieved; detailed sections remain separate links. |
| 8 | Company blog article | [GitHub availability update](https://github.blog/news-insights/company-news/an-update-on-github-availability/) | Success | generic-html | 1,288 | Full article body retrieved. |
| 9 | JavaScript-rendered documentation | [React Learn](https://react.dev/learn) | Success | generic-html | 1,797 | Server-rendered primary content retrieved. |
| 10 | Bot-protected explainer | [Cloudflare learning center](https://www.cloudflare.com/learning/what-is-cloudflare/) | Failure | — | 0 | HTTP 403. |
| 11 | Repository page | [Node.js repository](https://github.com/nodejs/node) | Success | generic-html | 2,768 | README and useful repository content retrieved. |
| 12 | Pull request / issue | [nodejs/node #1](https://github.com/nodejs/node/issues/1) | Success | generic-html | 171 | Primary discussion metadata and events retrieved. |
| 13 | Q&A page | [How do I exit Vim?](https://stackoverflow.com/questions/11828270/how-do-i-exit-vim) | Success | generic-html | 308 | Useful answer body retrieved. |
| 14 | Discussion thread | [Original Dropbox Hacker News thread](https://news.ycombinator.com/item?id=8863) | Success | generic-html | 4,095 | Full comment discussion retrieved. |
| 15 | Bot-protected discussion | [Reddit Downing Street memo post](https://www.reddit.com/r/reddit.com/comments/87/the_downing_street_memo/) | Failure | generic-html | 6 | False success: only “Please wait for verification.” |
| 16 | Hosted blog article | [Medium article](https://medium.com/@ev/why-medium-notes-are-different-and-how-to-use-them-849280191b0d) | Failure | — | 0 | HTTP 403. |
| 17 | Newsletter article | [Substack article](https://on.substack.com/p/welcome-to-substack) | Failure | — | 0 | Source URL currently returns HTTP 404; not an extractor defect. |
| 18 | Public cloud document | [Public Google Doc](https://docs.google.com/document/d/1h0gcE1TTF06rckYJQvKlsJrylDn2n7fVxR31JfJAAwM/mobilebasic) | Success | generic-html | 5,724 | Document body retrieved. |
| 19 | Raw Markdown | [Node.js README.md](https://raw.githubusercontent.com/nodejs/node/main/README.md) | Success | generic-html | 3,174 | Raw Markdown preserved as readable text. |
| 20 | CSV dataset | [Countries CSV](https://raw.githubusercontent.com/cs109/2014_data/master/countries.csv) | Success | generic-html | 279 | Raw rows retrieved, without table formatting. |
| 21 | JSON response | [JSONPlaceholder todo](https://jsonplaceholder.typicode.com/todos/1) | Success | generic-html | 12 | Raw JSON retrieved as readable text. |
| 22 | Plain text | [RFC 9110 text](https://www.rfc-editor.org/rfc/rfc9110.txt) | Success | generic-html | 68,746 | Full plain-text document retrieved. |
| 23 | RSS feed | [BBC News RSS](https://feeds.bbci.co.uk/news/rss.xml) | Success | generic-html | 689 | Feed content retrieved, but raw XML markers remain. |
| 24 | Atom feed | [Node.js releases Atom feed](https://github.com/nodejs/node/releases.atom) | Success | generic-html | 17,589 | Feed entries retrieved, but as flattened XML text. |
| 25 | Research paper page | [arXiv 1706.03762 abstract](https://arxiv.org/abs/1706.03762) | Success | arxiv | 5,898 | Full paper converted through Markxiv. |
| 26 | Research paper PDF URL | [arXiv 1706.03762 PDF](https://arxiv.org/pdf/1706.03762) | Success | arxiv | 5,898 | Same full Markxiv conversion as the abstract URL. |
| 27 | Text PDF on blocking host | [W3C dummy PDF](https://www.w3.org/WAI/ER/tests/xhtml/testfiles/resources/pdf/dummy.pdf) | Failure | — | 0 | HTTP 403 from this host; not a PDF parser failure. |
| 28 | OCR-demo PDF with text layer | [Scanned PDF sample](https://scandocword.com/assets/sample-scanned-pdf.pdf) | Success | pdf | 28 | Selectable embedded text retrieved; this was not truly image-only. |
| 29 | Confirmed image-only PDF | [PyMuPDF issue attachment](https://github.com/user-attachments/files/21309481/testpdf_image1.pdf) | Failure | pdf | 0 | Explicitly rejected because scanned PDFs have no OCR fallback. |
| 30 | Normal text PDF | [Orimi PDF test](https://www.orimi.com/pdf-test.pdf) | Success | pdf | 57 | Text and PDF metadata retrieved. |
| 31 | Biomedical abstract | [PubMed 25414315](https://pubmed.ncbi.nlm.nih.gov/25414315/) | Failure | generic-html | 21 | False success: reCAPTCHA page, not the abstract. |
| 32 | Biomedical full text | [PMC4366388](https://pmc.ncbi.nlm.nih.gov/articles/PMC4366388/) | Failure | generic-html | 21 | False success: reCAPTCHA page, not the paper. |
| 33 | Captioned YouTube video | [Never Gonna Give You Up](https://www.youtube.com/watch?v=dQw4w9WgXcQ) | Success | youtube | 488 | Published caption transcript retrieved. |
| 34 | Short captioned YouTube video | [Me at the zoo](https://www.youtube.com/watch?v=jNQXAC9IVRw) | Success | youtube | 40 | Complete short transcript retrieved. |
| 35 | YouTube video without captions | [Big Buck Bunny](https://www.youtube.com/watch?v=aqz-KE-bpKQ) | Partial | youtube | 36 | Title, channel, and description retrieved; transcript unavailable. |
| 36 | Short social post | [First X post](https://x.com/jack/status/20) | Success | x | 27 | Post text and engagement metadata retrieved. |
| 37 | Long-form social article | [Cerebras X Article](https://x.com/cerebras/status/2077822555159945507) | Success | x | 2,698 | Full article body retrieved. |
| 38 | Federated social post | [Bluesky release post](https://bsky.app/profile/bsky.app/post/3kh5rbndrjd2x) | Success | bluesky | 73 | Post, reply context, and engagement retrieved. |
| 39 | Social post | [Threads launch post](https://www.threads.com/@threads/post/CwVVlQlOe53) | Success | threads | 12 | Complete short post text retrieved. |
| 40 | Short-video social post | [TikTok sample post](https://www.tiktok.com/@scout2015/video/6718335390845095173) | Failure | generic-html | 5 | False success: only “TikTok - Make Your Day.” |
| 41 | Podcast platform episode | [Spotify podcast episode](https://open.spotify.com/episode/5XAz6Zpv64FcxGn1gRdH54) | Failure | generic-html | 4 | False success: only “Spotify – Web Player.” |
| 42 | Podcast RSS with transcript | [Podigee podcast feed](https://podcastd45a61.podigee.io/feed/mp3) | Success | podcast | 18,007 | Latest episode’s published Podcasting 2.0 transcript retrieved. |
| 43 | Podcast platform show | [The Daily on Apple Podcasts](https://podcasts.apple.com/us/podcast/the-daily/id1200361736) | Success | generic-html | 444 | Show description and episode listing retrieved; this show URL is not an episode transcript. |
| 44 | Direct audio file | [MP3 sample](https://www.soundhelix.com/examples/mp3/SoundHelix-Song-1.mp3) | Failure | — | 0 | `audio/mpeg` intentionally rejected. |
| 45 | Direct image | [JPEG flower](https://upload.wikimedia.org/wikipedia/commons/3/3f/JPEG_example_flower.jpg) | Failure | — | 0 | `image/jpeg` intentionally rejected; no OCR or captioning. |
| 46 | Direct video file | [MP4 sample](https://samplelib.com/lib/preview/mp4/sample-5s.mp4) | Failure | — | 0 | `video/mp4` intentionally rejected. |
| 47 | Archive | [Node.js source ZIP](https://github.com/nodejs/node/archive/refs/heads/main.zip) | Failure | — | 0 | Rejected after exceeding 20 MB; detection took about 65 seconds. |
| 48 | Word document | [DOCX demo](https://calibre-ebook.com/downloads/demos/demo.docx) | Failure | — | 0 | Unsupported binary content. |
| 49 | E-book | [Pride and Prejudice EPUB](https://www.gutenberg.org/ebooks/1342.epub3.images) | Failure | — | 0 | Unsupported/oversize binary content. |
| 50 | Paywalled article | [New York Times interactive](https://www.nytimes.com/interactive/2014/09/14/sunday-review/unscaling-fish.html) | Failure | — | 0 | HTTP 403. |
| 51 | Professional-network index | [LinkedIn topics](https://www.linkedin.com/pulse/topics/home/) | Success | generic-html | 251 | Public editor picks and topic descriptions retrieved. |
| 52 | Dynamic help index | [Notion guides](https://www.notion.com/help/guides) | Success | generic-html | 117 | Primary guide-category index retrieved. |
| 53 | App-store listing | [Apple Podcasts App Store page](https://apps.apple.com/us/app/apple-podcasts/id525463029) | Success | generic-html | 1,003 | Full product description and listing details retrieved. |

## Firecrawl fallback retest

The 35 native successes were left on their cheaper, higher-quality built-in
paths. These are the 18 cases that were previously failures or partial.

| Content | Current verdict | Route | Words | Retest observation |
|---|---|---|---:|---|
| Cloudflare learning center | Partial | firecrawl | 715 | Recovers a useful Learning Center index, but not the requested “What is Cloudflare?” article body. |
| Reddit post | Failure | — | 0 | Firecrawl explicitly does not support Reddit. |
| Medium article | Failure | — | 0 | The tested URL is now a genuine Medium 404; the error shell is rejected. |
| Substack article | Failure | — | 0 | The tested URL remains a genuine 404; the recommendations shell is rejected. |
| W3C text PDF | Success | firecrawl | 4 | Recovers the PDF text despite the W3C response blocking the native fetch. |
| Confirmed image-only PDF | Success | firecrawl | 421 | Firecrawl OCR retrieves the screenshot text. |
| PubMed abstract | Failure | — | 0 | Firecrawl also receives reCAPTCHA; the interstitial is rejected. |
| PubMed Central full text | Success | firecrawl | 8,584 | Full article body retrieved. |
| YouTube without captions | Partial | youtube | 36 | Native metadata remains useful; no transcript exists and Firecrawl is not invoked after a valid native result. |
| TikTok post | Failure | — | 0 | Firecrawl explicitly does not support TikTok. |
| Spotify podcast episode | Success | firecrawl | 1,833 | Episode title, date, duration, and description retrieved; surrounding Spotify navigation adds noise. |
| Direct MP3 | Failure | — | 0 | Firecrawl explicitly rejects `audio/mpeg`. |
| Direct JPEG | Failure | — | 0 | Firecrawl explicitly rejects `image/jpeg`. |
| Direct MP4 | Failure | — | 0 | Firecrawl explicitly rejects `video/mp4`. |
| ZIP archive | Failure | — | 0 | Firecrawl explicitly rejects archives; native size detection still takes about 65 seconds. |
| DOCX file | Success | firecrawl | 2,047 | Full document converted to Markdown. |
| EPUB file | Failure | — | 0 | Firecrawl returns a gateway timeout/error page, which is rejected. |
| New York Times article | Failure | — | 0 | The tested URL now returns 404 and Firecrawl does not support the site. |

## What works now

- Ordinary public HTML is strong across articles, documentation, repositories,
  discussions, public Google Docs, store listings, and non-English content.
- Raw Markdown, CSV, JSON, plain text, RSS, and Atom all produce usable text,
  although feeds are not formatted as feeds.
- The dedicated arXiv, X, Bluesky, Threads, YouTube, PDF, and podcast paths work
  well when the source exposes public text or a published transcript.
- PDF parsing works for PDFs with a text layer. The W3C failure above is a host
  response; Firecrawl now supplies OCR for confirmed image-only PDFs.
- Firecrawl adds useful coverage for blocked HTML, public cloud-rendered pages,
  PDF OCR, and DOCX without replacing successful native extraction.

## Improvement order

1. **Add structured fallbacks for remaining high-value platforms.** Reddit JSON,
   NCBI APIs, and TikTok oEmbed remain the clearest gaps because Firecrawl does
   not cover them reliably.
2. **Route direct audio/video through the existing transcription service.**
   The app already has this capability for YouTube and podcast media; direct
   `audio/*` and `video/*` links currently stop at the binary guard.
3. **Fail oversized downloads earlier.** The ZIP case spent about 65 seconds
   downloading before the 20 MB limit fired. Stream-counting and aborting at
   the limit would preserve the same behavior with a much faster failure.
4. **Use source-specific extraction where Firecrawl is noisy.** Spotify is now
   useful, but an oEmbed/feed path would avoid its navigation and related-item
   text. Cloudflare similarly returns a broader index for the tested old URL.

EPUB, arbitrary images, and archives can remain intentionally unsupported until
real capture demand justifies their parsers.
