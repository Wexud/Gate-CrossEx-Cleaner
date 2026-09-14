# Gate CrossEx Cleaner

PowerShell-скрипт для очищення залишкових активів у Gate CrossEx:

1. читає поточні CrossEx-баланси;
2. отримує Gate Flash Swap котирування для доступних non-USDT активів;
3. конвертує підтримувані Gate активи у `CROSSEX USDT` із перевіркою котирування;
4. переводить доступний `CROSSEX USDT` на звичайний Gate `SPOT`.

Скрипт **не виконує blockchain withdrawal** і не виводить кошти на зовнішню адресу.

## Вимоги

- Gate CrossEx account;
- для повного cleaner-режиму: `account_mode = CROSS_EXCHANGE`;
- Gate API Key / Secret з необхідними CrossEx read/write permissions;
- Windows PowerShell 5.1 або PowerShell 7+;
- правильний системний час на ПК.

**Ніколи не додавайте API Key / Secret у репозиторій, Issue, скріншот або повідомлення.**

## Файли

```text
gate_crossex_cleaner.ps1   Основний скрипт
README.md                   Інструкція
.gitignore                  Захист від випадкового commit локальних secret/config файлів
```

## 1. Безпечна перевірка балансів

Цей режим нічого не конвертує і не переводить.

### Windows PowerShell 5.1

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\gate_crossex_cleaner.ps1 -BalancesOnly
```

### PowerShell 7

```powershell
pwsh -NoProfile -File .\gate_crossex_cleaner.ps1 -BalancesOnly
```

Скрипт попросить:

```text
Gate CrossEx API Key
Gate CrossEx API Secret (hidden)
```

Secret вводиться приховано.

## 2. Повний cleaner

### Windows PowerShell 5.1

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\gate_crossex_cleaner.ps1
```

### PowerShell 7

```powershell
pwsh -NoProfile -File .\gate_crossex_cleaner.ps1
```

Перед фінансовими операціями скрипт перевіряє, чи немає активної експозиції:

- `initial_margin`;
- `maintenance_margin`;
- `liability`;
- `upnl`;
- futures margin;
- borrowing margin;
- відкритих CrossEx orders.

Якщо щось із цього активне — повний cleaner зупиняється.

## Як працює Flash Swap

Скрипт:

1. знаходить доступні non-USDT активи на підтримуваних Flash Swap venues;
2. одразу пропускає `DERIBIT`, non-USDC активи `HYPERLIQUID` та non-USD активи `KRAKEN`, які не входять у документовані Gate маршрути до `CROSSEX USDT`;
3. для решти пробує отримати `POST /crossex/convert/quote` у USDT;
4. якщо Gate не підтримує конкретний asset — актив просто `SKIP`;
5. показує preview quote;
6. перед виконанням просить точне підтвердження `YES`;
7. бере **новий** короткоживучий quote;
8. порівнює його з preview quote;
9. якщо котирування погіршилось сильніше заданого ліміту — `SKIP`;
10. для `USDC`/`USD` додатково перевіряє втрату від 1:1;
11. відправляє Flash Swap один раз;
12. перевіряє `order_id` через `GET /crossex/orders/{order_id}` і чекає кінцевий стан;
13. після `FILLED` додатково підтверджує settlement через зменшення source balance та збільшення `CROSSEX USDT`.

Якщо Gate вже міг прийняти Flash Swap, але його стан неможливо однозначно підтвердити, скрипт **не повторює операцію** і блокує подальші фінансові дії.

## CROSSEX USDT -> SPOT

Після Flash Swap скрипт:

1. повторно читає `CROSSEX USDT available_balance`;
2. отримує параметри `GET /crossex/transfers/coin?coin=USDT`;
3. перевіряє:
   - `is_disabled`;
   - `min_trans_amount`;
   - `est_fee`;
   - `precision`;
4. округляє transfer amount **вниз** відповідно до Gate precision;
5. показує точну суму;
6. просить окреме підтвердження `YES`;
7. виконує `CROSSEX -> SPOT`;
8. перевіряє transfer status через `GET /crossex/transfers?order_id=<tx_id>`.

Статуси Gate:

```text
PENDING
SUCCESS
FAIL
```

Transfer після можливого прийняття Gate автоматично не повторюється.

## Ліміти котирувань

Gate документує ліміт Flash Swap quote:

```text
100 requests / day
```

Cleaner використовує:

- один preview quote;
- ще один fresh quote перед фактичним swap.

За замовчуванням `MaxCandidates = 40`, але повторні запуски протягом одного дня також використовують денний quote-limit Gate.

## Параметри

```powershell
.\gate_crossex_cleaner.ps1 `
    -MaxQuoteWorseningPercent 1.0 `
    -StablecoinMaxLossPercent 1.0 `
    -MaxCandidates 40
```

За замовчуванням:

```text
MaxQuoteWorseningPercent = 1.0%
StablecoinMaxLossPercent = 1.0%
MaxCandidates             = 40
```

## Запуск із CMD

Це PowerShell-скрипт, але його можна запустити безпосередньо з `cmd.exe`.

Тільки баланси:

```cmd
powershell -NoProfile -ExecutionPolicy Bypass -File gate_crossex_cleaner.ps1 -BalancesOnly
```

Повний режим:

```cmd
powershell -NoProfile -ExecutionPolicy Bypass -File gate_crossex_cleaner.ps1
```

Python не потрібен.

## Gate API endpoints

```text
GET  /api/v4/crossex/accounts
GET  /api/v4/crossex/open_orders
GET  /api/v4/crossex/orders/{order_id}
POST /api/v4/crossex/convert/quote
POST /api/v4/crossex/convert/orders
GET  /api/v4/crossex/transfers/coin
POST /api/v4/crossex/transfers
GET  /api/v4/crossex/transfers
```

Офіційна документація Gate CrossEx API:

https://www.gate.com/docs/developers/crossex/
