import { cookies } from "next/headers";

export type Lang = "tk" | "ru";

export interface Dict {
  appName: string;
  dashboard: string;
  stores: string;
  logOut: string;
  email: string;
  password: string;
  signIn: string;
  signingIn: string;
  notAuthorized: string;
  signInFailed: string;
  invalidCredentials: string;
  ordersReport: string;
  ordersReportDesc: (days: number) => string;
  day: string;
  totalItems: string;
  noOrders: (days: number) => string;
  storesTitle: string;
  storesDesc: string;
  createStore: string;
  creating: string;
  name: string;
  phone: string;
  tagline: string;
  address: string;
  admins: string;
  status: string;
  active: string;
  inactive: string;
  noStoresYet: string;
  manageAdmins: string;
  failedCreateStore: string;
  storeAdminsTitle: (storeName: string) => string;
  storeAdminsDesc: string;
  promoteAdmin: string;
  phoneNumber: string;
  lookingUp: string;
  lookUp: string;
  noAccountFound: string;
  lookupFailed: string;
  promoting: string;
  promote: string;
  failedPromote: string;
  noAdminsYet: string;
  revoking: string;
  revoke: string;
  language: string;
  filterAll: string;
  filterShop: string;
  filterByPhone: string;
  allShops: string;
  searchPhonePlaceholder: string;
  date: string;
  store: string;
  quantity: string;
  noMatchingOrders: string;
}

// React Server Components can't serialize functions across the server/client
// boundary — passing the full Dict (which has 3 template-string functions)
// into any "use client" component throws "Functions cannot be passed
// directly to Client Components". Server Components call those functions
// directly and only ever need to hand *this* stripped-down type to their
// client children.
export type ClientDict = Omit<Dict, "ordersReportDesc" | "noOrders" | "storeAdminsTitle">;

export function toClientDict(t: Dict): ClientDict {
  const { ordersReportDesc: _ordersReportDesc, noOrders: _noOrders, storeAdminsTitle: _storeAdminsTitle, ...rest } = t;
  return rest;
}

// Super Admin web panel copy — Turkmen (default) and Russian only, matching
// the mobile app's language decision (docs/00_PROJECT_OVERVIEW.md §7.5).
// No English: this app never had English users in scope, it's the same
// scaffolding default the mobile app's globals.css dark-mode bug came from.
const dict: Record<Lang, Dict> = {
  tk: {
    appName: "SeMay Super Admin",
    dashboard: "Hasabat",
    stores: "Dükanlar",
    logOut: "Çykmak",
    email: "E-poçta",
    password: "Açar söz",
    signIn: "Gir",
    signingIn: "Girilýär...",
    notAuthorized: "Rugsat berilmedi — bu hasap Super Admin däl.",
    signInFailed: "Girip bolmady.",
    invalidCredentials: "E-poçta ýa-da açar söz nädogry.",
    ordersReport: "Sargytlar hasabaty",
    ordersReportDesc: (days: number) =>
      `Diňe okamak üçin. Soňky ${days} günüň sargyt edilen haryt sany. Her sargyt hasaba alynýar — status ýa-da tassyklama ýok.`,
    day: "Gün",
    totalItems: "Jemi harytlar",
    noOrders: (days: number) => `Soňky ${days} günde sargyt ýok.`,
    storesTitle: "Dükanlar",
    storesDesc: "Dükan dörediň we admin dolandyryň.",
    createStore: "Dükan döret",
    creating: "Döredilýär...",
    name: "Ady",
    phone: "Telefon",
    tagline: "Gysga beýany",
    address: "Salgy",
    admins: "Adminler",
    status: "Ýagdaýy",
    active: "aktiw",
    inactive: "aktiw däl",
    noStoresYet: "Häzirlikçe dükan ýok.",
    manageAdmins: "Adminleri dolandyr",
    failedCreateStore: "Dükan döredip bolmady",
    storeAdminsTitle: (storeName: string) => `${storeName} — Adminler`,
    storeAdminsDesc: "Dükan admin hukugyny beriň ýa-da aýryň.",
    promoteAdmin: "Admin belle",
    phoneNumber: "Telefon belgisi",
    lookingUp: "Gözlenýär...",
    lookUp: "Gözle",
    noAccountFound: "Bu telefon belgisi bilen hasap tapylmady.",
    lookupFailed: "Gözleg başa barmady.",
    promoting: "Bellenýär...",
    promote: "Belle",
    failedPromote: "Admin belläp bolmady",
    noAdminsYet: "Häzirlikçe admin ýok.",
    revoking: "Aýrylýar...",
    revoke: "Aýyr",
    language: "Dil",
    filterAll: "Ählisi",
    filterShop: "Dükan",
    filterByPhone: "Telefon belgisi boýunça",
    allShops: "Ähli dükanlar",
    searchPhonePlaceholder: "Telefon belgisini giriziň...",
    date: "Sene",
    store: "Dükan",
    quantity: "Sany",
    noMatchingOrders: "Gabat gelýän sargyt ýok.",
  },
  ru: {
    appName: "SeMay Супер Админ",
    dashboard: "Отчёт",
    stores: "Магазины",
    logOut: "Выйти",
    email: "Эл. почта",
    password: "Пароль",
    signIn: "Войти",
    signingIn: "Вход...",
    notAuthorized: "Доступ запрещён — этот аккаунт не Супер Админ.",
    signInFailed: "Не удалось войти.",
    invalidCredentials: "Неверная почта или пароль.",
    ordersReport: "Отчёт по заказам",
    ordersReportDesc: (days: number) =>
      `Только для чтения. Общее количество заказанных товаров за последние ${days} дней. Учитывается каждый заказ — статуса или подтверждения нет.`,
    day: "День",
    totalItems: "Всего товаров",
    noOrders: (days: number) => `Нет заказов за последние ${days} дней.`,
    storesTitle: "Магазины",
    storesDesc: "Создавайте магазины и управляйте их админами.",
    createStore: "Создать магазин",
    creating: "Создание...",
    name: "Название",
    phone: "Телефон",
    tagline: "Краткое описание",
    address: "Адрес",
    admins: "Админы",
    status: "Статус",
    active: "активен",
    inactive: "неактивен",
    noStoresYet: "Пока нет магазинов.",
    manageAdmins: "Управление админами",
    failedCreateStore: "Не удалось создать магазин",
    storeAdminsTitle: (storeName: string) => `${storeName} — Админы`,
    storeAdminsDesc: "Назначьте или отзовите права администратора магазина.",
    promoteAdmin: "Назначить админа",
    phoneNumber: "Номер телефона",
    lookingUp: "Поиск...",
    lookUp: "Найти",
    noAccountFound: "Аккаунт с этим номером не найден.",
    lookupFailed: "Поиск не удался.",
    promoting: "Назначение...",
    promote: "Назначить",
    failedPromote: "Не удалось назначить админа",
    noAdminsYet: "Пока нет админов.",
    revoking: "Отзыв...",
    revoke: "Отозвать",
    language: "Язык",
    filterAll: "Все",
    filterShop: "Магазин",
    filterByPhone: "По номеру телефона",
    allShops: "Все магазины",
    searchPhonePlaceholder: "Введите номер телефона...",
    date: "Дата",
    store: "Магазин",
    quantity: "Количество",
    noMatchingOrders: "Подходящих заказов нет.",
  },
};

export function translations(lang: Lang): Dict {
  return dict[lang];
}

const LANG_COOKIE = "lang";

export async function getLang(): Promise<Lang> {
  const value = (await cookies()).get(LANG_COOKIE)?.value;
  return value === "ru" ? "ru" : "tk";
}

export async function getTranslations(): Promise<Dict> {
  return translations(await getLang());
}
