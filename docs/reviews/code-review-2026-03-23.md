# Aerio — Full Codebase Code Review

**Date**: 2026-03-23
**Branch**: main
**Scope**: Full codebase (13,649 lines Swift)
**Reviewer**: Claude Opus 4.6

---

## Executive Summary

Aerio — качественное macOS-приложение с сильной архитектурой, хорошей типобезопасностью и продуманной клавиатурной навигацией. Основные замечания связаны с отсутствием шифрования локального кэша, потенциальными проблемами производительности при большом объёме почты и несколькими force unwrap, способными вызвать крэш.

**Общая оценка: 7.5/10**

---

## Critical Issues (4)

### 1. SwiftData — отсутствие шифрования данных в покое
**File**: `Aerio/Persistence/DataStore.swift`
**Impact**: Email-заголовки, тело письма, метаданные хранятся в незашифрованной SQLite БД (`~/Library/Application Support/default.store`).
**Risk**: Любой процесс с доступом к файловой системе пользователя может прочитать всю переписку.
**Recommendation**: Шифровать контент перед записью в SwiftData или использовать Core Data с SQLCipher. Как минимум — документировать ограничение для пользователей.

### 2. Force unwrap при инициализации ModelContainer
**File**: `Aerio/Persistence/DataStore.swift:87`
```swift
self.modelContainer = try! ModelContainer(for: schema, configurations: [fallbackConfig])
```
**Impact**: Если fallback in-memory контейнер не создаётся — неустранимый крэш без диагностики.
**Fix**: `do-catch` с `fatalError` и описательным сообщением, или graceful degradation.

### 3. Force unwrap URL-констант в OAuthManager
**File**: `Aerio/Services/OAuthManager.swift:60, 72, 111, 148, 182`
```swift
var components = URLComponents(string: OAuthConfig.authURL)!
let authURL = components.url!
var request = URLRequest(url: URL(string: OAuthConfig.tokenURL)!)
```
**Impact**: Crash при опечатке в OAuthConfig. Маловероятно, но fatal при возникновении.
**Fix**: `guard let` + `throw OAuthError.invalidConfiguration`.

### 4. Unbounded memory в incrementalSync
**File**: `Aerio/Services/GmailAPIManager.swift:316-329`
```swift
var allRecords: [GmailHistoryRecord] = []
// repeat-while пагинация — массив растёт без ограничений
allRecords.append(contentsOf: records)
```
**Impact**: У пользователя с тысячами изменений с последнего sync — потребление памяти может резко вырасти.
**Fix**: Обрабатывать записи потоково (stream), а не накапливать все перед обработкой.

---

## Warnings (12)

### Security

| # | Issue | File | Lines |
|---|-------|------|-------|
| 5 | **Error response bodies в исключениях** — OAuth/API ошибки могут раскрывать чувствительные данные | OAuthManager.swift, GmailAPIClient.swift | 127-128, 271, 290-291 |
| 6 | **Внешние изображения загружаются без opt-in** — tracking pixels раскрывают факт прочтения | MessageWebView.swift | 149-174 |
| 7 | **Нет валидации In-Reply-To/References** — потенциальный header injection | RFC2822Builder.swift | 24-28, 137-142 |
| 8 | **Нет очистки кэша при удалении аккаунта** — email'ы остаются в БД | DataStore.swift | — |

### Performance

| # | Issue | File | Lines |
|---|-------|------|-------|
| 9 | **O(n²) удаление email'ов** — два последовательных `removeAll` по одному массиву | GmailAPIManager.swift | 377, 383 |
| 10 | **Двойная сортировка** — `sortedByDate()` вызывается и в `rebuildEmails()` и в `emails()` | UnifiedMailbox.swift | 44, 99 |
| 11 | **Неатомарные транзакции** — delete старых + insert новых без rollback | DataStore.swift | 124-135 |
| 12 | **Линейный поиск selectedEmail** — вызывается многократно при обновлении view | MainView.swift | 387-393 |

### Code Quality

| # | Issue | File | Lines |
|---|-------|------|-------|
| 13 | **Тихое проглатывание ошибок Keychain** — `try?` при удалении токенов | GmailAPIManager.swift | 138 |
| 14 | **Search result injection обходит data flow** — ручное добавление в `emailsByAccount` | MainView.swift | 262-268 |
| 15 | **Cancellable leak** — если клиент пересоздаётся без `removeClient()`, старый sink остаётся | GmailAPIManager.swift | 115-121 |
| 16 | **SearchViewModel — нет deinit** — задачи могут пережить деаллокацию view | SearchOverlay.swift | 40-41, 70 |

---

## Suggestions (10)

| # | Issue | File | Lines |
|---|-------|------|-------|
| 17 | Добавить явный `script-src 'none'` в CSP | MessageWebView.swift | 611 |
| 18 | Redundant `name.isEmpty` assignment в ContactsCache | ContactsCache.swift | 115 |
| 19 | Результаты поиска не дедуплицируются между аккаунтами | GmailAPIManager.swift | 710 |
| 20 | 15 `@State` переменных в MainView — группировать в `@StateObject` | MainView.swift | 142-156 |
| 21 | SplitViewConfigurator: 20 retry × 0.1s — лучше fail fast | MainView.swift | 69-109 |
| 22 | JSON serialization overhead для headers/attachments в DataStore | DataStore.swift | 212-248 |
| 23 | Inefficient `onChange` для scroll detection в MessageList | MessageList.swift | 87-100 |
| 24 | Unread count пересчитывается для всех папок при изменении одного аккаунта | UnifiedMailbox.swift | 47-54 |
| 25 | NSEvent monitor в SearchPreviewWebView может утечь при пересоздании | SearchOverlay.swift | 475-497 |
| 26 | Inconsistent error logging: APIClient (хорошо) vs APIManager (иногда тихо) | — | — |

---

## Security Checklist

- [x] No hardcoded secrets (OAuth client ID — acceptable for native app, not a client_secret)
- [x] Input validation — header injection prevention in RFC2822Builder
- [x] Output encoding — HTML escaping for plain text emails
- [x] Authentication — proper PKCE implementation, secure token refresh
- [x] Authorization — Bearer token via Authorization header
- [x] CSP — strong Content Security Policy in WKWebView
- [x] JavaScript disabled in email rendering
- [x] Non-persistent WebView data store
- [x] Links open in system browser, not in WebView
- [x] No tokens/passwords in SwiftData
- [ ] **Data at rest encryption — MISSING**
- [ ] **External image privacy option — MISSING**

## Performance Checklist

- [x] Batch loading (50 per page)
- [x] Incremental sync via History API
- [x] Debounced search (300ms)
- [x] Token refresh coalescing
- [x] Exponential backoff for rate limits
- [ ] **Stream processing for history sync — needed**
- [ ] **O(n²) email removal — needs optimization**
- [ ] **Redundant sorting — needs caching**

## Maintainability Checklist

- [x] Code is readable — clear naming, good structure
- [x] Functions are focused — single responsibility
- [x] Types are complete — proper Codable/Sendable conformance
- [x] Tests exist — 390+ tests
- [x] Good separation of concerns (Models/Services/Views/Utilities)
- [x] Layout-independent keyboard shortcuts
- [ ] **Force unwraps in critical paths — need guards**
- [ ] **Inconsistent error handling patterns**

---

## Positive Highlights

1. **PKCE implementation** — корректная, полностью соответствует RFC 7636
2. **Header injection prevention** — `\r\n` удаляются из всех заголовков RFC2822
3. **WKWebView security** — JS отключён, CSP настроен, non-persistent store, ссылки открываются в системном браузере
4. **Token refresh coalescing** — предотвращает thundering herd при истечении токена
5. **Keyboard architecture** — layout-independent через keyCode, не `charactersIgnoringModifiers`
6. **KeychainStore protocol** — отличная абстракция для тестируемости
7. **ComposeWindowManager** — правильная очистка ресурсов через weak references
8. **Retry logic** — экспоненциальный backoff с поддержкой Retry-After

---

## Recommended Priority Actions

| Priority | Action |
|----------|--------|
| **P0** | Заменить force unwrap в DataStore.swift:87 и OAuthManager.swift |
| **P0** | Стримить history records вместо накопления в массив |
| **P1** | Добавить cascade delete email-кэша при удалении аккаунта |
| **P1** | Оптимизировать двойной `removeAll` → единый Set-based pass |
| **P1** | Логировать ошибки Keychain вместо `try?` |
| **P2** | Кэшировать sorted emails, убрать двойную сортировку |
| **P2** | Добавить опцию блокировки внешних изображений |
| **P2** | Валидировать Message-ID формат для In-Reply-To/References |
| **P3** | Группировать @State в MainView в StateObject |
| **P3** | Добавить deinit в SearchViewModel для отмены задач |
