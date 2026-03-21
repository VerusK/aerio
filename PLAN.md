# Gmail Multi-Account Client для macOS

## Context

Нативное macOS-приложение для работы с несколькими Gmail-аккаунтами. **Полностью через Gmail Web Interface** — без Google API, без IMAP, без SMTP. Никаких протоколов, которые могут блокироваться провайдерами/VPN. Работает везде, где работает браузер.

"Общий вид" объединяет письма из всех аккаунтов через парсинг Gmail Basic HTML mode с помощью JS-инъекций в скрытые WKWebView.

## Стек технологий

- **Swift 6.2+ / SwiftUI** — UI приложения, нативный macOS
- **WKWebView** — каждый аккаунт в изолированном `WKWebsiteDataStore`
- **Gmail Basic HTML mode** (`mail.google.com/mail/?ui=html`) — упрощённый DOM для парсинга
- **JavaScript injection** (`WKUserScript` / `evaluateJavaScript`) — извлечение данных из Gmail
- **SwiftData** — локальный кеш извлечённых данных
- **async-await / Structured Concurrency** — параллельный опрос аккаунтов

## Архитектура

### 1. Модуль авторизации

Каждый аккаунт — это отдельный WKWebView с **изолированным** `WKWebsiteDataStore`:
1. Открытие `https://accounts.google.com` в WebView
2. Пользователь логинится как обычно (2FA поддерживается)
3. Куки сохраняются в изолированном DataStore — каждый аккаунт в своей "песочнице"
4. Никаких App Passwords — просто веб-логин

### 2. Модуль данных (Gmail Basic HTML Scraper)

```
GmailScraperManager
├── GmailScraper (per account)
│   ├── Hidden WKWebView (Basic HTML mode)
│   ├── JS-инъекции для извлечения:
│   │   ├── Список писем (from, subject, date, snippet, msgId)
│   │   ├── Счётчики непрочитанных
│   │   └── Содержимое выбранного письма
│   └── Периодический poll (перезагрузка страницы каждые N секунд)
├── UnifiedMailbox (все папки merged из всех аккаунтов)
│   ├── Inbox — merged, sorted by date
│   ├── Archive — merged
│   ├── Trash — merged
│   ├── Spam — merged
│   └── Drafts — merged
```

**Как это работает:**

1. Для каждого аккаунта создаётся **скрытый WKWebView** с URL:
   `https://mail.google.com/mail/?ui=html&zy=e` (Basic HTML Gmail)

2. После загрузки страницы — JS-скрипт парсит таблицу писем:
   - Gmail Basic HTML отображает письма в простой `<table>` структуре
   - Извлекаем: отправитель, тема, дата, snippet, ID письма, статус прочитано/нет
   - Извлекаем счётчик непрочитанных

3. Для навигации по папкам — JS кликает по ссылкам Gmail:
   - Inbox: `?s=a&q=is:inbox`
   - Archive: всё, кроме inbox/trash/spam
   - Trash: `?s=a&q=in:trash`
   - Spam: `?s=a&q=in:spam`
   - Drafts: `?s=a&q=in:drafts`

4. Для обновлений — периодическая перезагрузка скрытого WebView (каждые 30-60 сек)

**Действия через Gmail WebView:**
- Архивировать, удалить, пометить спамом — JS-инъекция кликает по соответствующим кнопкам в Basic HTML
- Это эквивалент того, что пользователь сам нажимает кнопки в браузере

**Отправка писем через Gmail WebView compose:**
- Новое письмо (`c`) — открывает Gmail compose в видимом WebView:
  `https://mail.google.com/mail/?view=cm&fs=1`
- Ответ (`r`) — `...?view=cm&fs=1&to=...&su=Re:...&body=...`
- Ответить всем (`⇧R`) — аналогично, с CC
- Пересылка (`f`) — `...?view=cm&fs=1&su=Fwd:...&body=...`
- В объединённом виде: compose открывается в WebView аккаунта-получателя
- Compose — модальное окно поверх основного UI

**Надёжность:**
- Работает через HTTPS (порт 443) — никогда не блокируется
- Gmail Basic HTML — стабильный режим, Google поддерживает его для accessibility
- Риск: Google может изменить структуру HTML. Митигация: JS-парсер вынесен в отдельный модуль, легко обновлять

### 3. Режимы просмотра

**Режим "Конкретный аккаунт":**
- Панели 2-4 показывают данные из парсера этого аккаунта
- При клике на письмо — открывается **полный Gmail WebView** (не Basic HTML) для просмотра
- Полноценный Gmail UX для чтения и взаимодействия

**Режим "Общий вид" (All):**
- Панель 3 показывает merged список из всех аккаунтов
- Цветной индикатор аккаунта рядом с каждым письмом
- При клике на письмо — переключается на WebView соответствующего аккаунта

### 4. Модуль UI (SwiftUI)

4-панельный layout:

```
┌──────┬──────────┬──────────────┬─────────────────────┐
│Icons │ Folders  │ Message List │ Message Content      │
│      │          │              │ (Gmail WebView)      │
│ All  │ Inbox    │ [a1] Subj 1  │                      │
│ acc1 │ Archive  │ [a2] Subj 2  │ Full Gmail WebView   │
│ acc2 │ Trash    │ [a1] Subj 3  │ for selected email   │
│ acc3 │ Spam     │ ...          │                      │
│      │ Drafts   │              │                      │
└──────┴──────────┴──────────────┴─────────────────────┘
```

**Панель 1 — Иконки аккаунтов (48px sidebar):**
- Иконка "Все" (объединённый вид)
- Иконка каждого аккаунта (аватар/первая буква)
- Бейдж с количеством непрочитанных

**Панель 2 — Папки:**
- Inbox, Archive, Trash, Spam, Drafts
- Счётчики непрочитанных (суммарные в режиме "Все")

**Панель 3 — Список писем (нативный SwiftUI):**
- Данные из JS-парсера Basic HTML
- Отправитель, тема, дата, snippet
- Цветной индикатор аккаунта (в режиме "Все")
- Сортировка по дате

**Панель 4 — Содержимое (Gmail WebView):**
- Полный Gmail WebView (не Basic HTML) для выбранного письма
- JS-навигация к конкретному письму по msgId
- Все Gmail-действия доступны нативно в WebView

### 5. Горячие клавиши

| Клавиша | Действие |
|---------|----------|
| `j` / `k` | Следующее / предыдущее письмо |
| `e` | Архивировать |
| `#` | В корзину |
| `r` | Ответить |
| `⇧R` | Ответить всем |
| `f` | Переслать |
| `c` | Новое письмо |
| `⌘1-9` | Переключение между аккаунтами |
| `⌘0` | Общий вид |
| `/` | Поиск |
| `⌘Enter` | Отправить |

### 6. Структура проекта

```
AgMail/
├── AgMailApp.swift                  # Entry point
├── Models/
│   ├── Account.swift                # Модель аккаунта (email, color, dataStore)
│   ├── Email.swift                  # Модель письма (parsed from Gmail HTML)
│   └── Folder.swift                 # Enum: inbox, archive, trash, spam, drafts
├── Services/
│   ├── GmailScraper.swift           # JS-инъекция + парсинг Gmail Basic HTML
│   ├── GmailScraperManager.swift    # Управление скраперами всех аккаунтов
│   ├── ComposeService.swift         # Gmail compose URL builder
│   ├── AccountManager.swift         # Добавление/удаление аккаунтов
│   ├── WebViewPool.swift            # Пул WKWebView (hidden + visible per account)
│   └── UnifiedMailbox.swift         # Merge данных из всех аккаунтов
├── Views/
│   ├── MainView.swift               # 4-панельный layout (HSplitView)
│   ├── AccountSidebar.swift         # Панель 1 — иконки аккаунтов
│   ├── FolderList.swift             # Панель 2 — папки
│   ├── MessageList.swift            # Панель 3 — список писем
│   ├── MessageWebView.swift         # Панель 4 — Gmail WebView для чтения
│   ├── ComposeWebView.swift         # Модальное окно — Gmail compose
│   └── AccountSetupView.swift       # WebView для логина в Gmail
├── Scripts/
│   ├── gmail_parser.js              # JS-скрипт парсинга Gmail Basic HTML
│   └── gmail_actions.js             # JS-скрипт действий (archive, delete, etc.)
├── Persistence/
│   └── DataStore.swift              # SwiftData: кеш писем для мгновенного отображения
└── Utilities/
    └── KeyboardShortcuts.swift      # Обработка горячих клавиш
```

## Поэтапный план реализации

### Фаза 1: WebView + Auth
1. Создать Xcode-проект (macOS, SwiftUI App, Swift 6.2+)
2. Реализовать `AccountSetupView` — WKWebView с изолированным DataStore для логина в Gmail
3. Реализовать `AccountManager` — хранение аккаунтов (email + DataStore persistence)
4. Реализовать `WebViewPool` — создание и управление hidden/visible WebView per account

### Фаза 2: Gmail Scraper
5. Написать `gmail_parser.js` — парсинг таблицы писем Gmail Basic HTML
6. Реализовать `GmailScraper` — загрузка Basic HTML Gmail, инъекция JS, извлечение данных
7. Реализовать `GmailScraperManager` — параллельный опрос всех аккаунтов
8. Реализовать `UnifiedMailbox` — merge данных, сортировка по дате

### Фаза 3: UI
9. Создать `MainView` с 4-панельным HSplitView
10. Реализовать `AccountSidebar` с иконками и бейджами
11. Реализовать `FolderList` со счётчиками
12. Реализовать `MessageList` (нативный SwiftUI из данных парсера)
13. Реализовать `MessageWebView` — полный Gmail WebView для чтения письма

### Фаза 4: Действия и отправка
14. Написать `gmail_actions.js` — архивировать, удалить, пометить спамом через JS
15. Реализовать `ComposeService` + `ComposeWebView` — отправка через Gmail compose URL
16. Горячие клавиши

### Фаза 5: Полировка
17. SwiftData кеш для мгновенного отображения при запуске
18. Уведомления macOS о новых письмах
19. Автоматический poll (30-60 сек) для обновления данных

## Верификация

- Добавить 2+ Gmail аккаунта через WebView логин
- Проверить парсинг Gmail Basic HTML — список писем корректно извлекается
- Проверить объединённый вид — письма из всех аккаунтов отсортированы по дате
- Проверить переключение папок: Inbox, Archive, Trash, Spam, Drafts
- Проверить клик на письмо — открывается в полном Gmail WebView
- Проверить действия: архивировать, удалить (через JS в Basic HTML)
- Проверить compose: новое письмо, ответ, ответить всем, пересылка
- Проверить горячие клавиши
- Проверить периодическое обновление — новое письмо появляется через 30-60 сек
