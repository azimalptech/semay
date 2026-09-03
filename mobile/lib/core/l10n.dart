import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/auth_service.dart';

/// App copy in the two supported languages — Turkmen (default) and Russian.
/// There is deliberately no English: the product ships tk/ru only (Settings
/// screen Figma + explicit product decision). Selection persists on
/// `users/{uid}.language` ("tk" | "ru").
class S {
  const S(this.isRu);

  final bool isRu;

  // Auth
  String get enterPhone =>
      isRu ? 'Введите номер телефона' : 'Telefon belgiňizi giriziň';
  String get welcomeGreeting =>
      isRu ? 'Добро пожаловать 👋' : 'Hoş geldiňiz 👋';
  String get enterPhoneToStart => isRu
      ? 'Введите номер телефона, чтобы начать.'
      : 'Başlamak üçin telefon belgiňizi giriziň.';
  String get privacyPolicyAgreement => isRu
      ? 'Входя в аккаунт, вы принимаете нашу '
      : 'Hasabyňyza girmek bilen, siz ';
  String get privacyPolicyAgreementSuffix => isRu ? '.' : ' kabul edýärsiňiz.';
  String get sendCode => isRu ? 'Отправить код' : 'Kod ugrat';
  String get verificationTitle => isRu ? 'Подтверждение 🔒' : 'Tassyklama 🔒';
  String get codeSentToGeneric => isRu
      ? 'Введите код, отправленный на ваш телефон.'
      : 'Telefonyňyza ugradylan kody giriziň.';
  String codeSentTo(String phone) => isRu
      ? 'Введите код, отправленный на $phone'
      : '$phone belgisine ugradylan kody giriziň';
  String get verify => isRu ? 'Подтвердить' : 'Tassykla';
  String get whatsYourName => isRu ? 'Как вас зовут?' : 'Adyňyz näme?';
  String get yourName => isRu ? 'Ваше имя' : 'Adyňyz';
  String get continueLabel => isRu ? 'Продолжить' : 'Dowam et';
  String get missingPhoneGoBack =>
      isRu ? 'Номер не указан — вернуться' : 'Belgi girizilmedi — yza dolan';
  String get invalidPhoneLength =>
      isRu ? 'Введите ровно 8 цифр номера' : 'Belginiň 8 sanyny doly giriziň';
  String get resendCode =>
      isRu ? 'Отправить код повторно' : 'Kody gaýtadan ugrat';
  String resendCodeIn(int seconds) => isRu
      ? 'Повторная отправка через $secondsс'
      : '$seconds sek. soň gaýtadan ugradyp bolar';
  String get incorrectCode => isRu ? 'Неверный код' : 'Kod nädogry';
  String attemptsRemaining(int count) =>
      isRu ? 'Осталось попыток: $count' : 'Galan synanyşyk: $count';
  String get numberLockedTitle =>
      isRu ? 'Номер временно заблокирован' : 'Belgi wagtlaýyn petiklendi';
  String lockedTryAgainIn(String duration) => isRu
      ? 'Слишком много попыток. Попробуйте снова через $duration'
      : 'Synanyşyk gaty köp. $duration soň gaýtadan synanyşyň';
  String get devCodeLabel => isRu ? 'DEV: код —' : 'DEV: kod —';
  String get change => isRu ? 'Изменить' : 'Üýtget';

  // Feed / posts
  String get noPostsYet => isRu ? 'Пока нет постов' : 'Häzirlikçe post ýok';
  String get failedToLoad => isRu ? 'Не удалось загрузить' : 'Ýüklenmedi';
  String get noActiveStories =>
      isRu ? 'Нет активных историй' : 'Aktiw story ýok';
  String get noConnection => isRu ? 'Нет соединения' : 'Internet ýok';
  String get checkConnection => isRu
      ? 'Проверьте подключение к интернету'
      : 'Internet baglanyşygyňyzy barlaň';
  String get tryAgain => isRu ? 'Повторить' : 'Gaýtadan synanyş';

  // Store profile
  String get posts => isRu ? 'Посты' : 'Postlar';
  String get reels => 'Reels';

  /// Store header total-likes stat ("Halananlar" = likes RECEIVED, Figma
  /// 223:5365). Distinct from `likes` further down, which is the profile's
  /// "my liked posts" list ("Halanlarym" = likes I GAVE).
  String get storeLikes => isRu ? 'Лайки' : 'Halananlar';
  String get videos => isRu ? 'Видео' : 'Post';
  String get editProfile => isRu ? 'Редактировать' : 'Profili üýtget';
  String get share => isRu ? 'Поделиться' : 'Paýlaş';
  String get message => isRu ? 'Написать' : 'Habar ýaz';
  String messageStore(String storeName) =>
      isRu ? 'Написать в $storeName' : '$storeName ýaz';
  String get call => isRu ? 'Позвонить' : 'Jaň et';
  String get storeLinkCopied =>
      isRu ? 'Ссылка скопирована' : 'Salgy kopiýalandy';
  String get sendToChat => isRu ? 'Отправить в чат' : 'Çata ugrat';
  String get messageSent => isRu ? 'Сообщение отправлено' : 'Habar ugradyldy';
  String get addedToSaved =>
      isRu ? 'Добавлено в сохранённые' : 'Ýatda saklananlara goşuldy';
  String get removedFromSaved =>
      isRu ? 'Удалено из сохранённых' : 'Ýatda saklananlardan aýryldy';
  String get postShared => isRu ? 'Поделились' : 'Paýlaşyldy';
  String get deletePostTitle => isRu ? 'Удалить пост?' : 'Post pozulsynmy?';
  String get deletePostBody => isRu
      ? 'Вы действительно хотите навсегда удалить этот пост?'
      : 'Bu posty hemişelik pozmak isleýäňizmi?';
  String get deleteStoryTitle =>
      isRu ? 'Удалить историю?' : 'Story pozulsynmy?';
  String get deleteStoryBody => isRu
      ? 'Вы действительно хотите навсегда удалить эту историю?'
      : 'Bu storyni hemişelik pozmak isleýäňizmi?';
  String get repliedToStory => isRu ? 'Ответ на историю' : 'Story-a jogap';
  String get editCaption => isRu ? 'Изменить подпись' : 'Ýazgyny üýtget';
  String get reply => isRu ? 'Ответить' : 'Jogap ber';
  String get you => isRu ? 'Вы' : 'Siz';

  // Settings
  String get settings => isRu ? 'Настройки' : 'Sazlamalar';
  String get profile => isRu ? 'Профиль' : 'Profil';
  String get notifications => isRu ? 'Уведомления' : 'Bildirişler';
  String get likes => isRu ? 'Понравившиеся' : 'Halanlarym';
  String get saved => isRu ? 'Сохранённые' : 'Ýatda saklananlar';
  String get quickReplies => isRu ? 'Быстрые ответы' : 'Çalt jogaplar';
  String get orders => isRu ? 'Заказы' : 'Sargytlar';
  String get language => isRu ? 'Язык' : 'Dil';
  String get darkMode => isRu ? 'Тёмная тема' : 'Garaňky tema';
  String get privacyPolicy =>
      isRu ? 'Политика конфиденциальности' : 'Gizlinlik syýasaty';
  String get contactUs => isRu ? 'Связаться с нами' : 'Biz bilen habarlaşyň';
  String get logout => isRu ? 'Выйти' : 'Çykmak';
  String get appVersion =>
      isRu ? 'Версия приложения 1.0' : 'Programma wersiýasy 1.0';
  String get logoutConfirm => isRu
      ? 'Вы уверены, что хотите выйти? Чтобы увидеть свои заказы, нужно будет войти снова.'
      : 'Çykmak isleýändigiňize ynanýarsyňyzmy? Sargytlaryňyzy görmek üçin täzeden girmeli bolarsyňyz.';
  String get cancel => isRu ? 'Отмена' : 'Ýatyr';
  String get deleteAccount => isRu ? 'Удалить аккаунт' : 'Hasaby pozmak';
  String get deleteAccountConfirm => isRu
      ? 'Удалить аккаунт навсегда? Ваше имя, номер, чаты, сохранённые и понравившиеся посты будут удалены. Это действие нельзя отменить.'
      : 'Hasabyňyzy hemişelik pozmakçymy? Adyňyz, belgiňiz, söhbetdeşlikleriňiz, ýatda saklananlar we halanlar pozulýar. Bu yzyna alynmaýar.';
  String get deleteAccountConfirmAction => isRu ? 'Удалить' : 'Poz';
  String get deleteAccountStoreOwner => isRu
      ? 'Аккаунты владельцев магазинов нельзя удалить здесь. Свяжитесь с поддержкой.'
      : 'Dükan eýeleriniň hasaplary bu ýerde pozulmaýar. Goldaw bilen habarlaşyň.';
  String get deleteAccountFailed => isRu
      ? 'Не удалось удалить аккаунт. Попробуйте позже.'
      : 'Hasap pozulmady. Soňra synanyşyň.';
  String get selectLanguage => isRu ? 'Выберите язык' : 'Dil saýlaň';
  String get noNotificationsYet =>
      isRu ? 'Пока нет уведомлений' : 'Häzirlikçe bildiriş ýok';
  String get noLikedYet =>
      isRu ? 'Пока нет понравившихся постов' : 'Häzirlikçe halanan post ýok';
  String get noSavedYet => isRu
      ? 'Пока нет сохранённых постов'
      : 'Häzirlikçe ýatda saklanan post ýok';
  String get myStore => isRu ? 'Мой магазин' : 'Meniň dükanym';
  String get noStoreAssigned => isRu
      ? 'Этому аккаунту не назначен магазин'
      : 'Bu hasaba dükan bellenilmedi';

  // Quick replies
  String get quickRepliesHelp => isRu
      ? 'Добавляйте или редактируйте быстрые ответы. Перетаскивайте для изменения порядка.'
      : 'Çalt jogaplary goşuň ýa-da üýtgediň. Tertibi süýräp üýtgedip bilersiňiz.';
  String get noQuickRepliesYet =>
      isRu ? 'Пока нет быстрых ответов' : 'Häzirlikçe çalt jogap ýok';
  String get addQuickReply =>
      isRu ? 'Добавить быстрый ответ' : 'Çalt jogap goş';
  String get editQuickReply =>
      isRu ? 'Изменить быстрый ответ' : 'Çalt jogaby üýtget';
  String get add => isRu ? 'Добавить' : 'Goş';
  String get save => isRu ? 'Сохранить' : 'Ýatda sakla';
  String get delete => isRu ? 'Удалить' : 'Poz';

  // Orders
  String get noOrdersYet => isRu ? 'Пока нет заказов' : 'Häzirlikçe sargyt ýok';
  String orderedItems(int n) =>
      isRu ? 'Заказано: $n шт.' : '$n haryt sargyt etdi';

  // Edit store
  String get storeName => isRu ? 'Название магазина' : 'Dükanyň ady';
  String get shortDescription => isRu ? 'Краткое описание' : 'Gysga beýany';
  String get address => isRu ? 'Адрес' : 'Salgy';
  String get phoneNumber => isRu ? 'Номер телефона' : 'Telefon belgisi';
  String get couldNotOpenDialer =>
      isRu ? 'Не удалось открыть набор номера' : 'Nomer ýygnaýjy açylmady';

  // Chat
  String get chat => isRu ? 'Чат' : 'Çat';
  String get deleteChatTitle =>
      isRu ? 'Удалить чат?' : 'Söhbetdeşlik pozulsynmy?';
  String get deleteChatBody => isRu
      ? 'Чат исчезнет из вашего списка. Он появится снова, если придёт новое сообщение.'
      : 'Söhbetdeşlik siziň sanawyňyzdan aýrylar. Täze habar gelse, ýene peýda bolar.';
  String get noConversationsYet =>
      isRu ? 'Пока нет переписок' : 'Häzirlikçe söhbetdeşlik ýok';
  String get noMessagesYetTitle =>
      isRu ? 'Пока нет сообщений' : 'Entek gepleşik ýok';
  String get typeMessageToStart => isRu
      ? 'Напишите сообщение, чтобы начать переписку'
      : 'Gepleşik başlamak üçin habar ýazyň';
  String get typeMessage => isRu ? 'Введите сообщение' : 'Habar ýazyň';
  String get typing => isRu ? 'печатает…' : 'ýazýar…';
  String get today => isRu ? 'Сегодня' : 'Şu gün';
  String get yesterday => isRu ? 'Вчера' : 'Düýn';
  String seenAt(String time) => isRu ? 'Прочитано: $time' : 'Okaldy: $time';
  String get muteNotifications =>
      isRu ? 'Отключить уведомления' : 'Bildirişleri öçür';
  String get unmuteNotifications =>
      isRu ? 'Включить уведомления' : 'Bildirişleri açyk et';
  String get notificationsMuted =>
      isRu ? 'Уведомления отключены' : 'Bildirişler öçürildi';
  String get notificationsUnmuted =>
      isRu ? 'Уведомления включены' : 'Bildirişler açyldy';
  /// Under the chat title while the realtime socket is down/reconnecting —
  /// the same caption WhatsApp/Telegram show, so a quiet thread reads as "no
  /// network" rather than "broken app".
  String get connecting => isRu ? 'Подключение…' : 'Baglanýar…';
  /// Under a bubble the outbox has failed to send a few times; the bubble
  /// itself is tappable to retry.
  String get notSentTapToRetry => isRu
      ? 'Не отправлено. Нажмите, чтобы повторить'
      : 'Ugradylmady. Gaýtalamak üçin basyň';

  // Composer / story
  String get newPost => isRu ? 'Новый пост' : 'Täze post';
  String get post => isRu ? 'Пост' : 'Post';
  String get story => 'Story';
  String get image => isRu ? 'Фото' : 'Surat';
  String get carousel => isRu ? 'Карусель' : 'Karusel';
  String get reel => 'Reel';
  String get video => isRu ? 'Видео' : 'Wideo';
  String get pickMedia => isRu ? 'Выберите медиа' : 'Media saýlaň';
  String filesSelected(int n) =>
      isRu ? 'Выбрано файлов: $n' : '$n faýl saýlandy';
  String get caption => isRu ? 'Подпись' : 'Ýazgy';
  String get postStory => isRu ? 'Опубликовать историю' : 'Story paýlaş';
  String get pickMediaFirst =>
      isRu ? 'Сначала выберите медиа' : 'Ilki media saýlaň';
  String get newStory => isRu ? 'Новая история' : 'Täze story';
  String get addContent => isRu ? 'Добавить' : 'Goş';
  String get fill => isRu ? 'Заполнить' : 'Doldur';
  String get fit => isRu ? 'Вместить' : 'Sygdyr';
  String get price => isRu ? 'Цена' : 'Baha';
  String get priceEmptyTitle =>
      isRu ? 'Вы не указали цену' : 'Baha girizilmedi';
  String get priceEmptyBody => isRu
      ? 'Вы не указали цену для этого товара. Продолжить без цены?'
      : 'Bu haryt üçin baha girizmediňiz. Bahasyz dowam etmeli?';
  String get skip => isRu ? 'Пропустить' : 'Geç';
  String get goBack => isRu ? 'Назад' : 'Yza';

  // Store-requested broadcast notifications
  String get requestNotification =>
      isRu ? 'Запросить уведомление' : 'Bildiriş sora';
  String get requestNotificationDesc => isRu
      ? 'Отправьте текст уведомления Супер Админу. Если он одобрит, оно будет отправлено всем пользователям.'
      : 'Bildiriş tekstini Super Admin\'e iberiň. Ol tassyklasa, ähli ulanyjylara iberiler.';
  String get notificationMessageHint =>
      isRu ? 'Текст уведомления' : 'Bildiriş teksti';
  String get sendRequest => isRu ? 'Отправить запрос' : 'Sorag iber';
  String get sendingRequest => isRu ? 'Отправка...' : 'Iberilýär...';
  String get requestSent => isRu ? 'Запрос отправлен' : 'Sorag iberildi';
  String get requestFailed =>
      isRu ? 'Не удалось отправить запрос' : 'Sorag iberip bolmady';
  String get yourRequests => isRu ? 'Ваши запросы' : 'Siziň soraglaryňyz';
  String get noRequestsYet =>
      isRu ? 'Пока нет запросов' : 'Häzirlikçe sorag ýok';
  String get statusPending => isRu ? 'На рассмотрении' : 'Garaşylýar';
  String get statusApproved => isRu ? 'Одобрено' : 'Tassyklandy';
  String get statusRejected => isRu ? 'Отклонено' : 'Ret edildi';

  // Search
  String get search => isRu ? 'Поиск' : 'Gözleg';
  String get searchHint =>
      isRu ? 'Поиск по описанию...' : 'Beýany boýunça gözle...';
  String get noSearchResults =>
      isRu ? 'Ничего не найдено' : 'Hiç zat tapylmady';
  String get takePhoto => isRu ? 'Сделать фото' : 'Surata düşür';
  String get recordVideo => isRu ? 'Записать видео' : 'Wideo ýazgy et';
  String get chooseFromGallery =>
      isRu ? 'Выбрать из галереи' : 'Galereýadan saýla';
  String get publish => isRu ? 'Опубликовать' : 'Çap et';

  // Reels feed
  String get noReelsYet => isRu ? 'Пока нет Reels' : 'Häzirlikçe Reels ýok';

  // Leaderboard
  String get leaderboardSoon => isRu ? 'Рейтинг — скоро' : 'Sanaw — tiz wagtda';
  String get topUsers => isRu ? 'Топ пользователей' : 'Iň gowy ulanyjylar';
  String get noLeaderboardYet =>
      isRu ? 'Пока нет данных.' : 'Häzirlikçe maglumat ýok.';

  // Accept order
  String get acceptOrder => isRu ? 'Принять заказ' : 'Sargydy kabul et';
  String get quantity => isRu ? 'Количество' : 'Sany';
  String get phoneLabel => isRu ? 'Телефон' : 'Telefon';
  String get orderAccepted => isRu ? 'Заказ принят' : 'Sargyt kabul edildi';

  // Post detail
  String get postNotFound => isRu ? 'Пост не найден' : 'Post tapylmady';
}

/// Current language strings — follows `users/{uid}.language`, Turkmen before
/// login and for any unset/unknown value.
final l10nProvider = Provider<S>((ref) {
  final lang = ref.watch(userProfileProvider).value?['language'] as String?;
  return S(lang == 'ru');
});
