# Gmail Multi-Account Client для macOS (AgMail)

## Overview

Нативное macOS-приложение на Swift/SwiftUI для работы с несколькими Gmail-аккаунтами через Gmail
Basic HTML mode. Вместо Google API/IMAP используется WKWebView с JS-инъекциями для парсинга и управления
почтой. 4-панельный интерфейс с объединенным просмотром писем из всех аккаунтов.

## Context

- Files involved: проект создается с нуля, структура описана в PLAN.md
- Related patterns: нет существующего кода, greenfield проект
- Dependencies: macOS SDK (WKWebView, SwiftUI, SwiftData), без внешних зависимостей

## Development Approach

- **Testing approach**: Regular (code first, then tests) - для WebView/UI-heavy приложения TDD ограничен; тестируемая логика (парсинг, модели, merge) покрывается unit-тестами
- Complete each task fully before moving to the next
- Xcode project (macOS, SwiftUI App, Swift 6.2+)
- JS-скрипты как bundled resources
- **CRITICAL: every task MUST include new/updated tests**
- **CRITICAL: all tests must pass before starting next task**

## Implementation Steps

### Task 1: Xcode project scaffold + Models

**Files:**
- Create: `AgMail.xcodeproj` (via xcodebuild/Xcode CLI)
- Create: `AgMail/AgMailApp.swift`
- Create: `AgMail/Models/Account.swift`
- Create: `AgMail/Models/Email.swift`
- Create: `AgMail/Models/Folder.swift`
- Create: `AgMailTests/` target

- [x] создать Xcode проект macOS SwiftUI App с target AgMail и AgMailTests
- [x] реализовать модель Folder (enum: inbox, archive, trash, spam, drafts)
- [x] реализовать модель Email (from, subject, date, snippet, msgId, isRead, accountId, folder)
- [x] реализовать модель Account (id, email, displayName, color, avatarLetter)
- [x] написать тесты для моделей (инициализация, Equatable, сортировка Email по дате)
- [x] run project test suite - must pass before task 2

### Task 2: AccountManager + WebView isolation

**Files:**
- Create: `AgMail/Services/AccountManager.swift`
- Create: `AgMail/Services/WebViewPool.swift`

- [x] реализовать AccountManager - добавление/удаление аккаунтов, хранение списка в UserDefaults/SwiftData
- [x] реализовать WebViewPool - создание WKWebView с изолированным WKWebsiteDataStore per account (hidden + visible)
- [x] написать тесты для AccountManager (add/remove/list аккаунтов)
- [x] написать тесты для WebViewPool (изоляция DataStore, создание hidden/visible WebView)
- [x] run project test suite - must pass before task 3

### Task 3: Gmail Basic HTML парсер (JS + Swift bridge)

**Files:**
- Create: `AgMail/Scripts/gmail_parser.js`
- Create: `AgMail/Services/GmailScraper.swift`

- [x] написать gmail_parser.js - парсинг таблицы писем Gmail Basic HTML (from, subject, date, snippet, msgId, isRead, unreadCount)
- [x] реализовать GmailScraper - загрузка Basic HTML Gmail в hidden WKWebView, инъекция JS, извлечение данных в Swift-модели
- [x] реализовать навигацию по папкам через URL-параметры Gmail
- [x] реализовать периодический poll (перезагрузка страницы каждые 30-60 сек)
- [x] написать тесты для парсинга JS (mock HTML -> parsed Email array)
- [x] написать тесты для GmailScraper (загрузка, callback, error handling)
- [x] run project test suite - must pass before task 4

### Task 4: GmailScraperManager + UnifiedMailbox

**Files:**
- Create: `AgMail/Services/GmailScraperManager.swift`
- Create: `AgMail/Services/UnifiedMailbox.swift`

- [x] реализовать GmailScraperManager - управление GmailScraper per account, параллельный опрос через async/await
- [x] реализовать UnifiedMailbox - merge писем из всех аккаунтов, сортировка по дате, суммарные счетчики непрочитанных per folder
- [x] написать тесты для UnifiedMailbox (merge из нескольких аккаунтов, сортировка, счетчики)
- [x] написать тесты для GmailScraperManager (параллельный опрос, добавление/удаление скраперов)
- [x] run project test suite - must pass before task 5

### Task 5: UI - 4-панельный layout + AccountSidebar + FolderList

**Files:**
- Create: `AgMail/Views/MainView.swift`
- Create: `AgMail/Views/AccountSidebar.swift`
- Create: `AgMail/Views/FolderList.swift`

- [x] реализовать MainView - HSplitView с 4 панелями
- [x] реализовать AccountSidebar - иконки аккаунтов (48px), иконка "Все", бейджи непрочитанных
- [x] реализовать FolderList - Inbox/Archive/Trash/Spam/Drafts со счетчиками
- [x] написать UI тесты (ViewInspector или preview-based): sidebar отображает аккаунты, folder list показывает счетчики
- [x] run project test suite - must pass before task 6

### Task 6: UI - MessageList + MessageWebView

**Files:**
- Create: `AgMail/Views/MessageList.swift`
- Create: `AgMail/Views/MessageWebView.swift`
- Create: `AgMail/Views/AccountSetupView.swift`

- [x] реализовать MessageList - нативный SwiftUI список писем (from, subject, date, snippet, цветной индикатор аккаунта в режиме "Все")
- [x] реализовать MessageWebView - NSViewRepresentable обертка WKWebView для полного Gmail (не Basic HTML), JS-навигация к письму по msgId
- [x] реализовать AccountSetupView - WKWebView для логина в Gmail с изолированным DataStore
- [x] написать тесты для MessageList (отображение данных, фильтрация по аккаунту/папке)
- [x] run project test suite - must pass before task 7

### Task 7: Действия + Compose

**Files:**
- Create: `AgMail/Scripts/gmail_actions.js`
- Create: `AgMail/Services/ComposeService.swift`
- Create: `AgMail/Views/ComposeWebView.swift`

- [x] написать gmail_actions.js - архивировать, удалить, пометить спамом через JS-клики по кнопкам Basic HTML
- [x] реализовать ComposeService - построение Gmail compose URL (новое письмо, ответ, ответить всем, пересылка)
- [x] реализовать ComposeWebView - модальное окно с Gmail compose WebView
- [x] написать тесты для ComposeService (URL-генерация для всех типов compose)
- [x] написать тесты для gmail_actions.js (вызовы корректных действий)
- [x] run project test suite - must pass before task 8

### Task 8: Горячие клавиши + SwiftData кеш

**Files:**
- Create: `AgMail/Utilities/KeyboardShortcuts.swift`
- Create: `AgMail/Persistence/DataStore.swift`

- [x] реализовать KeyboardShortcuts - обработка j/k, e, #, r, Shift+R, f, c, Cmd+1-9, Cmd+0, /, Cmd+Enter
- [x] реализовать DataStore - SwiftData кеш писем для мгновенного отображения при запуске
- [x] интегрировать кеш в GmailScraperManager (сохранение при получении, загрузка при старте)
- [x] написать тесты для KeyboardShortcuts (маппинг клавиш к действиям)
- [x] написать тесты для DataStore (сохранение/загрузка/очистка кеша)
- [x] run project test suite - must pass before task 9

### Task 9: Verify acceptance criteria

- [x] run full test suite (xcodebuild test) - 140 tests pass, 0 failures
- [x] run SwiftLint (если настроен) или проверить warnings в Xcode - no warnings, SwiftLint not configured
- [x] verify test coverage meets 80%+ для тестируемых модулей (Models, Services, Utilities) - Models 100%, Utilities 100%, Persistence 91%, Services ~80%

### Task 10: Update documentation

- [x] update README.md - описание проекта, как собрать, как использовать
- [x] update CLAUDE.md - внутренние паттерны, команды сборки/тестирования
- [x] move this plan to `docs/plans/completed/`
