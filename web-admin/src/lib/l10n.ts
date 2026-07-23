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
  broadcast: string;
  broadcastTitle: string;
  broadcastDesc: string;
  notificationTitle: string;
  notificationBody: string;
  send: string;
  sending: string;
  broadcastSentPrefix: string;
  broadcastFailed: string;
  leaderboard: string;
  leaderboardTitle: string;
  selectStoreForCampaign: string;
  campaignStartLabel: string;
  campaignStartDesc: string;
  saveDate: string;
  savingDate: string;
  saveDateFailed: string;
  dateSaved: string;
  giftImageLabel: string;
  giftImageDesc: string;
  upload: string;
  uploading: string;
  remove: string;
  removing: string;
  noImageUploaded: string;
  uploadFailed: string;
  storeOrderLabel: string;
  storeOrderDesc: string;
  noStoresForOrder: string;
  reorderFailed: string;
  dangerZone: string;
  deleteStoreTitle: string;
  deleteStoreDesc: string;
  deleteStoreConfirmLabel: (storeName: string) => string;
  deleteStore: string;
  deletingStore: string;
  deleteStoreFailed: string;
  notificationRequests: string;
  notificationRequestsTitle: string;
  notificationRequestsDesc: string;
  requestedBy: string;
  noPendingRequests: string;
  approve: string;
  approving: string;
  reject: string;
  rejecting: string;
  decideRequestFailed: string;
  requestApprovedSentPrefix: string;
  maintenance: string;
}

// React Server Components can't serialize functions across the server/client
// boundary — passing the full Dict (which has 3 template-string functions)
// into any "use client" component throws "Functions cannot be passed
// directly to Client Components". Server Components call those functions
// directly and only ever need to hand *this* stripped-down type to their
// client children.
export type ClientDict = Omit<
  Dict,
  "ordersReportDesc" | "noOrders" | "storeAdminsTitle" | "deleteStoreConfirmLabel"
>;

export function toClientDict(t: Dict): ClientDict {
  const {
    ordersReportDesc: _ordersReportDesc,
    noOrders: _noOrders,
    storeAdminsTitle: _storeAdminsTitle,
    deleteStoreConfirmLabel: _deleteStoreConfirmLabel,
    ...rest
  } = t;
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
    dangerZone: "Howply zolak",
    deleteStoreTitle: "Dükany poz",
    deleteStoreDesc:
      "Bu dükanyň ähli ýazgylaryny (posty, story, chat, sargyt) we ýüklenen suratlary hemişelik pozýar. Yzyna alyp bolmaýar.",
    deleteStoreConfirmLabel: (storeName: string) =>
      `Tassyklamak üçin "${storeName}" ýazyň:`,
    deleteStore: "Dükany hemişelik poz",
    deletingStore: "Pozulýar...",
    deleteStoreFailed: "Dükany pozup bolmady",
    notificationRequests: "Bildiriş soraglary",
    notificationRequestsTitle: "Bildiriş soraglary",
    notificationRequestsDesc:
      "Dükan adminleriniň iberen bildiriş soraglary. Tassyklasaňyz, ähli ulanyjylara iberiler.",
    requestedBy: "Dükan",
    noPendingRequests: "Garaşylýan sorag ýok",
    approve: "Tassykla",
    approving: "Tassyklanýar...",
    reject: "Ret et",
    rejecting: "Ret edilýär...",
    decideRequestFailed: "Amal ýerine ýetip bolmady",
    requestApprovedSentPrefix: "Iberildi:",
    maintenance: "Hyzmat",
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
    broadcast: "Bildiriş",
    broadcastTitle: "Bildiriş iber",
    broadcastDesc: "Ähli ulanyjylara push bildirişi iberiň.",
    notificationTitle: "Sözbaşy",
    notificationBody: "Tekst",
    send: "Iber",
    sending: "Iberilýär...",
    broadcastSentPrefix: "Iberildi:",
    broadcastFailed: "Bildiriş iberip bolmady",
    leaderboard: "Sanaw",
    leaderboardTitle: "Sanaw sazlamalary",
    selectStoreForCampaign: "Dükany saýlaň",
    campaignStartLabel: "Kampaniýanyň başlangyç senesi",
    campaignStartDesc:
      "Diňe şu senäden soň kabul edilen sargytlar saýlanan dükanyň sanawyna girer. Senäni üýtgetmek şol dükanyň sanawyny täzeden hasaplar.",
    saveDate: "Ýatda sakla",
    savingDate: "Ýatda saklanýar...",
    saveDateFailed: "Senäni ýatda saklap bolmady",
    dateSaved: "Sene ýatda saklandy",
    giftImageLabel: "Sowgat suraty (3x2)",
    giftImageDesc: "Saýlanan dükanyň sanawynyň astynda görkezilýär.",
    upload: "Ýükle",
    uploading: "Ýüklenýär...",
    remove: "Aýyr",
    removing: "Aýrylýar...",
    noImageUploaded: "Surat ýüklenmedi.",
    uploadFailed: "Surat ýüklenip bilmedi",
    storeOrderLabel: "Dükanlaryň tertibi",
    storeOrderDesc: "Sanaw sahypasyndaky dükan tablarynyň tertibini üýtgediň.",
    noStoresForOrder: "Häzirlikçe aktiw dükan ýok.",
    reorderFailed: "Tertibi ýatda saklap bolmady",
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
    dangerZone: "Опасная зона",
    deleteStoreTitle: "Удалить магазин",
    deleteStoreDesc:
      "Навсегда удаляет все данные этого магазина (посты, истории, чаты, заказы) и загруженные файлы. Это действие необратимо.",
    deleteStoreConfirmLabel: (storeName: string) =>
      `Введите "${storeName}" для подтверждения:`,
    deleteStore: "Удалить магазин навсегда",
    deletingStore: "Удаление...",
    deleteStoreFailed: "Не удалось удалить магазин",
    notificationRequests: "Запросы уведомлений",
    notificationRequestsTitle: "Запросы уведомлений",
    notificationRequestsDesc:
      "Запросы на уведомления от администраторов магазинов. Одобрение отправит уведомление всем пользователям.",
    requestedBy: "Магазин",
    noPendingRequests: "Нет запросов на рассмотрении",
    approve: "Одобрить",
    approving: "Одобрение...",
    reject: "Отклонить",
    rejecting: "Отклонение...",
    decideRequestFailed: "Не удалось выполнить действие",
    requestApprovedSentPrefix: "Отправлено:",
    maintenance: "Обслуживание",
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
    broadcast: "Уведомление",
    broadcastTitle: "Отправить уведомление",
    broadcastDesc: "Отправьте push-уведомление всем пользователям.",
    notificationTitle: "Заголовок",
    notificationBody: "Текст",
    send: "Отправить",
    sending: "Отправка...",
    broadcastSentPrefix: "Отправлено:",
    broadcastFailed: "Не удалось отправить уведомление",
    leaderboard: "Рейтинг",
    leaderboardTitle: "Настройки рейтинга",
    selectStoreForCampaign: "Выберите магазин",
    campaignStartLabel: "Дата начала кампании",
    campaignStartDesc:
      "В рейтинг выбранного магазина попадут только заказы, принятые после этой даты. Изменение даты пересчитает рейтинг этого магазина заново.",
    saveDate: "Сохранить",
    savingDate: "Сохранение...",
    saveDateFailed: "Не удалось сохранить дату",
    dateSaved: "Дата сохранена",
    giftImageLabel: "Изображение приза (3x2)",
    giftImageDesc: "Показывается под рейтингом выбранного магазина.",
    upload: "Загрузить",
    uploading: "Загрузка...",
    remove: "Удалить",
    removing: "Удаление...",
    noImageUploaded: "Изображение не загружено.",
    uploadFailed: "Не удалось загрузить изображение",
    storeOrderLabel: "Порядок магазинов",
    storeOrderDesc: "Измените порядок вкладок магазинов на странице рейтинга.",
    noStoresForOrder: "Пока нет активных магазинов.",
    reorderFailed: "Не удалось сохранить порядок",
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
