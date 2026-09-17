// The public share page's markup and copy. No DB, no Prisma import, no
// template engine, no JavaScript in the output — see routes.ts for why this
// surface is deliberately the dullest thing in the server.

export type ShareKind = "post" | "reel" | "store";
export type ShareLang = "tk" | "ru" | "en";

/** The path segment each kind is shared under (share_links.dart emits these). */
export const KIND_SEGMENT: Record<ShareKind, string> = {
  post: "p",
  reel: "r",
  store: "s",
};

/** HTML-escape every interpolated value. The page has no script-src at all
 * (routes.ts sets its own CSP), but escaping is the primary defense, not the
 * fallback: `"` and `'` are included because most of these land inside
 * attributes (href, content=). */
export function esc(value: string): string {
  return value
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;")
    .replace(/'/g, "&#39;");
}

type Strings = {
  readonly title: (k: ShareKind) => string;
  readonly description: (k: ShareKind) => string;
  readonly open: string;
  readonly noApp: string;
  readonly play: string;
  readonly appStore: string;
  readonly comingSoon: string;
  readonly notFoundTitle: string;
  readonly notFoundBody: string;
  readonly busyTitle: string;
  readonly busyBody: string;
};

// Turkmen is the default everywhere in this product (mobile/lib/core/l10n.dart);
// Russian is the second language. English exists only because a share link
// leaves the country the moment someone forwards it, and an English-speaking
// recipient landing on a page they cannot read still has to find the
// store buttons.
const STRINGS: Record<ShareLang, Strings> = {
  tk: {
    title: (k) =>
      k === "store" ? "SeMay-da dükan" : k === "reel" ? "SeMay-da reels" : "SeMay-da post",
    description: (k) =>
      k === "store"
        ? "Bu dükany SeMay programmasynda aç."
        : k === "reel"
          ? "Bu reelsi SeMay programmasynda aç."
          : "Bu posty SeMay programmasynda aç.",
    open: "SeMay-da aç",
    noApp: "Programma ýokmy? Ony gur:",
    play: "Google Play",
    appStore: "App Store",
    comingSoon: "Ýakynda",
    notFoundTitle: "Salgy tapylmady",
    notFoundBody: "Bu salgy nädogry ýa-da könelen. SeMay programmasyny açyp gözläň.",
    busyTitle: "Birsalym garaşyň",
    busyBody: "Şu wagt haýyş köp geldi. Birnäçe sekuntdan soň sahypany täzeläň.",
  },
  ru: {
    title: (k) =>
      k === "store" ? "Магазин в SeMay" : k === "reel" ? "Reels в SeMay" : "Пост в SeMay",
    description: (k) =>
      k === "store"
        ? "Откройте этот магазин в приложении SeMay."
        : k === "reel"
          ? "Откройте этот Reels в приложении SeMay."
          : "Откройте этот пост в приложении SeMay.",
    open: "Открыть в SeMay",
    noApp: "Нет приложения? Установите его:",
    play: "Google Play",
    appStore: "App Store",
    comingSoon: "Скоро",
    notFoundTitle: "Ссылка не найдена",
    notFoundBody: "Эта ссылка неверна или устарела. Откройте приложение SeMay и найдите нужное.",
    busyTitle: "Подождите немного",
    busyBody: "Сейчас слишком много запросов. Обновите страницу через несколько секунд.",
  },
  en: {
    title: (k) =>
      k === "store" ? "A store on SeMay" : k === "reel" ? "A reel on SeMay" : "A post on SeMay",
    description: (k) =>
      k === "store"
        ? "Open this store in the SeMay app."
        : k === "reel"
          ? "Open this reel in the SeMay app."
          : "Open this post in the SeMay app.",
    open: "Open in SeMay",
    noApp: "Don't have the app? Get it:",
    play: "Google Play",
    appStore: "App Store",
    comingSoon: "Coming soon",
    notFoundTitle: "Link not found",
    notFoundBody: "This link is wrong or has expired. Open the SeMay app and look there.",
    busyTitle: "One moment",
    busyBody: "Too many requests right now. Reload this page in a few seconds.",
  },
};

const SUPPORTED: readonly ShareLang[] = ["tk", "ru", "en"];

function isLang(value: string): value is ShareLang {
  return (SUPPORTED as readonly string[]).includes(value);
}

/** `?lang=` wins over Accept-Language; Turkmen when neither says anything we
 * speak. Quality values are honoured so a browser sending
 * `ru;q=0.9, en;q=0.8` gets Russian rather than whichever appeared first. */
export function pickLang(queryLang: unknown, acceptLanguage: string | undefined): ShareLang {
  if (typeof queryLang === "string") {
    const q = queryLang.trim().toLowerCase().slice(0, 5);
    const base = q.split("-")[0] ?? "";
    if (isLang(base)) return base;
  }
  if (!acceptLanguage) return "tk";
  const ranked = acceptLanguage
    .split(",")
    .map((part) => {
      const [tag = "", ...params] = part.trim().split(";");
      const qParam = params.find((p) => p.trim().startsWith("q="));
      const q = qParam ? Number.parseFloat(qParam.trim().slice(2)) : 1;
      return { tag: (tag.split("-")[0] ?? "").toLowerCase(), q: Number.isFinite(q) ? q : 0 };
    })
    .filter((e) => e.q > 0 && isLang(e.tag))
    .sort((a, b) => b.q - a.q);
  const best = ranked[0];
  return best && isLang(best.tag) ? best.tag : "tk";
}

/** Android's Chrome is the one browser that can hand an https page off to an
 * installed app with no App Links verification, via an intent: URL. Everything
 * else (iOS Safari included) gets the plain custom scheme, which the app
 * registers on both platforms. */
export function isAndroidUserAgent(ua: string | undefined): boolean {
  if (!ua) return false;
  return /android/i.test(ua) && !/windows phone/i.test(ua);
}

export function openAppHref(opts: {
  kind: ShareKind;
  id: string;
  android: boolean;
  canonicalUrl: string;
  androidPackage: string;
  playUrl: string;
}): string {
  const path = `open/${KIND_SEGMENT[opts.kind]}/${opts.id}`;
  if (!opts.android) return `semay://${path}`;
  // S.browser_fallback_url is where Chrome goes when it cannot resolve the
  // package — i.e. exactly the "recipient does not have the app" case, which
  // is the whole audience this page was built for. The owner decision for
  // that case is Google Play, so the fallback is SHARE_PLAY_URL whenever it
  // is configured. It previously pointed at this very page, which made the
  // primary button a silent reload.
  //
  // With SHARE_PLAY_URL empty ("no listing yet" — the page then renders
  // "Google Play · Ýakynda" instead of a link) there is nothing honest to
  // send them to, so keep the canonical URL: staying put beats Chrome's own
  // Play-Store-for-package redirect, which would land on a listing we have
  // not confirmed exists.
  const fallback = opts.playUrl !== "" ? opts.playUrl : opts.canonicalUrl;
  return (
    `intent://${path}#Intent;scheme=semay;package=${opts.androidPackage};` +
    `S.browser_fallback_url=${encodeURIComponent(fallback)};end`
  );
}

const STYLE = `
:root{color-scheme:light dark}
*{box-sizing:border-box}
body{margin:0;min-height:100vh;display:flex;align-items:center;justify-content:center;
padding:24px;font:16px/1.5 -apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,Helvetica,Arial,sans-serif;
background:#f7f5f2;color:#2e2d2a}
main{width:100%;max-width:420px;text-align:center}
.mark{font-size:28px;font-weight:700;letter-spacing:.5px;color:#934d8e;margin:0 0 24px}
h1{font-size:22px;margin:0 0 8px}
p{margin:0 0 24px;color:#636363}
a.open{display:block;padding:14px 20px;border-radius:12px;background:#934d8e;color:#fff;
text-decoration:none;font-weight:600}
.stores{display:flex;gap:12px;justify-content:center;flex-wrap:wrap;margin-top:12px}
.stores a,.stores span{display:inline-block;padding:10px 16px;border-radius:10px;
border:1px solid #cecece;text-decoration:none;color:#2e2d2a;font-size:15px}
.stores span{color:#9b9b9b}
.hint{margin:28px 0 8px;font-size:14px}
@media (prefers-color-scheme:dark){
body{background:#121212;color:#f2f0ee}
p{color:#b5b3b0}
.stores a,.stores span{border-color:#3a3a3a;color:#f2f0ee}
}
`.trim();

function storeLinks(s: Strings, playUrl: string, appStoreUrl: string): string {
  const cell = (label: string, url: string) =>
    url === ""
      ? `<span>${esc(label)} · ${esc(s.comingSoon)}</span>`
      : `<a href="${esc(url)}" rel="noopener noreferrer">${esc(label)}</a>`;
  return `<div class="stores">${cell(s.play, playUrl)}${cell(s.appStore, appStoreUrl)}</div>`;
}

function shell(opts: { lang: ShareLang; title: string; head: string; body: string }): string {
  return `<!doctype html>
<html lang="${opts.lang}">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>${esc(opts.title)}</title>
${opts.head}
<style>${STYLE}</style>
</head>
<body>
<main>
<p class="mark">SeMay</p>
${opts.body}
</main>
</body>
</html>
`;
}

export type SharePageOptions = {
  kind: ShareKind;
  id: string;
  lang: ShareLang;
  android: boolean;
  baseUrl: string;
  playUrl: string;
  appStoreUrl: string;
  androidPackage: string;
};

/** The generic share page: identical for every id of a given kind, so it
 * reveals nothing about whether that post or store exists (config.ts
 * SHARE_PAGE_MODE). */
export function renderSharePage(o: SharePageOptions): string {
  const s = STRINGS[o.lang];
  const canonical = `${o.baseUrl}/${KIND_SEGMENT[o.kind]}/${o.id}`;
  const image = `${o.baseUrl}/share-assets/semay.png`;
  const title = s.title(o.kind);
  const description = s.description(o.kind);
  const head = [
    `<link rel="canonical" href="${esc(canonical)}">`,
    // Every one of these pages is the same generic copy; letting a search
    // engine index one per post id would be thousands of duplicates.
    `<meta name="robots" content="noindex,follow">`,
    `<meta name="description" content="${esc(description)}">`,
    `<meta property="og:site_name" content="SeMay">`,
    `<meta property="og:type" content="website">`,
    `<meta property="og:title" content="${esc(title)}">`,
    `<meta property="og:description" content="${esc(description)}">`,
    `<meta property="og:url" content="${esc(canonical)}">`,
    `<meta property="og:image" content="${esc(image)}">`,
    `<meta property="og:image:width" content="1200">`,
    `<meta property="og:image:height" content="630">`,
    `<meta name="twitter:card" content="summary_large_image">`,
  ].join("\n");
  const href = openAppHref({
    kind: o.kind,
    id: o.id,
    android: o.android,
    canonicalUrl: canonical,
    androidPackage: o.androidPackage,
    playUrl: o.playUrl,
  });
  const body = [
    `<h1>${esc(title)}</h1>`,
    `<p>${esc(description)}</p>`,
    `<a class="open" href="${esc(href)}">${esc(s.open)}</a>`,
    `<p class="hint">${esc(s.noApp)}</p>`,
    storeLinks(s, o.playUrl, o.appStoreUrl),
  ].join("\n");
  return shell({ lang: o.lang, title, head, body });
}

/** The 429 body. Same reasoning as renderNotFoundPage: the reader is a person
 * in a browser, and Turkmen mobile traffic sits behind heavy carrier NAT, so a
 * link forwarded into a big group chat can put several genuine recipients into
 * one IP bucket within a minute. They must still get the store buttons rather
 * than the API's JSON error shape. */
export function renderTooManyPage(o: {
  lang: ShareLang;
  playUrl: string;
  appStoreUrl: string;
}): string {
  const s = STRINGS[o.lang];
  return shell({
    lang: o.lang,
    title: s.busyTitle,
    head: `<meta name="robots" content="noindex,nofollow">`,
    body: [
      `<h1>${esc(s.busyTitle)}</h1>`,
      `<p>${esc(s.busyBody)}</p>`,
      `<p class="hint">${esc(s.noApp)}</p>`,
      storeLinks(s, o.playUrl, o.appStoreUrl),
    ].join("\n"),
  });
}

/** A malformed id (or any share path we do not serve) gets HTML, not the
 * API's JSON error shape: the reader is a person in a browser. */
export function renderNotFoundPage(o: {
  lang: ShareLang;
  playUrl: string;
  appStoreUrl: string;
}): string {
  const s = STRINGS[o.lang];
  return shell({
    lang: o.lang,
    title: s.notFoundTitle,
    head: `<meta name="robots" content="noindex,nofollow">`,
    body: [
      `<h1>${esc(s.notFoundTitle)}</h1>`,
      `<p>${esc(s.notFoundBody)}</p>`,
      `<p class="hint">${esc(s.noApp)}</p>`,
      storeLinks(s, o.playUrl, o.appStoreUrl),
    ].join("\n"),
  });
}
