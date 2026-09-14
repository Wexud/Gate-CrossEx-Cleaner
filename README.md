# Gate CrossEx Cleaner

Скрипт допомагає забрати залишки з Gate CrossEx:

1. знаходить доступні активи в CrossEx;
2. пробує обміняти підтримувані активи в **USDT** через Gate Flash Swap;
3. збирає отримані USDT у `CROSSEX USDT`;
4. переводить USDT з CrossEx на звичайний **Gate Spot**.

Скрипт **не виводить кошти з Gate на зовнішній гаманець**.

---

## Що потрібно

- Windows 10/11;
- Gate CrossEx API Key і API Secret;
- API-ключ повинен мати права читання і виконання потрібних CrossEx операцій;
- на CrossEx не повинно бути відкритих ордерів або активних futures/margin позицій.

> **API Secret нікому не надсилайте.** Він вводиться тільки у вашому PowerShell і на екрані не показується.

---

# Як користуватись

## Крок 1. Скачайте скрипт

На цій сторінці GitHub натисніть:

**Code → Download ZIP**

Розпакуйте ZIP у будь-яку папку, наприклад:

```text
Downloads\Gate-CrossEx-Cleaner
```

У папці має бути файл:

```text
gate_crossex_cleaner.ps1
```

---

## Крок 2. Відкрийте PowerShell ПРЯМО в папці зі скриптом

Це важливо.

1. Відкрийте папку `Gate-CrossEx-Cleaner` у Провіднику Windows.
2. Клікніть по рядку адреси зверху.
3. Введіть:

```text
powershell
```

4. Натисніть **Enter**.

Відкриється PowerShell уже в правильній папці.

Перед запуском подивіться на початок рядка PowerShell. Він повинен бути приблизно таким:

```text
PS C:\Users\ВашеІм'я\Downloads\Gate-CrossEx-Cleaner>
```

або:

```text
PS E:\Downloads\Gate-CrossEx-Cleaner>
```

**Якщо бачите:**

```text
PS C:\Windows\System32>
```

ви відкрили PowerShell не в тій папці. Не запускайте скрипт звідти.

---

## Крок 3. Спочатку тільки перевірте баланс

У PowerShell, відкритому в папці зі скриптом, виконайте:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\gate_crossex_cleaner.ps1 -BalancesOnly
```

Скрипт попросить:

```text
Gate CrossEx API Key:
Gate CrossEx API Secret (hidden):
```

Введіть ваш API Key.

Потім введіть API Secret. Під час введення Secret символи **не відображаються — це нормально**.

Після цього скрипт покаже ненульові CrossEx-баланси.

Наприклад:

```text
ACCOUNT         COIN        BALANCE        AVAILABLE
HYPERLIQUID     USDC        12.23          12.23
CROSSEX         USDT        5.00           5.00
```

У режимі `-BalancesOnly` скрипт **нічого не обмінює і нікуди не переводить**.

Якщо баланс показався без помилки — можна переходити до повного запуску.

---

## Крок 4. Запустіть повний режим

У тому ж PowerShell виконайте:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\gate_crossex_cleaner.ps1
```

Знову введіть API Key і API Secret.

Спочатку скрипт перевірить:

- баланси;
- відкриті ордери;
- futures позиції;
- margin позиції;
- борги/liability.

Якщо є активна позиція або відкритий ордер, скрипт зупиниться і нічого не конвертуватиме.

---

# Що відповідати під час роботи

## 1. Preview котирувань

З'явиться питання:

```text
Request preview quotes now? Type YES
```

Введіть:

```text
YES
```

На цьому етапі **гроші ще не обмінюються**.

Скрипт лише запитує у Gate, скільки USDT можна отримати за кожен актив.

Наприклад:

```text
HYPERLIQUID USDC 12.23 -> USDT ... OK: 12.20 USDT
```

Якщо конкретний актив Gate не підтримує для Flash Swap, буде:

```text
SKIP
```

Такий актив просто не чіпається.

---

## 2. Реальний обмін активів у USDT

Після preview з'явиться:

```text
Execute accepted Flash Swaps? Type YES
```

Якщо котирування вас влаштовують, введіть:

```text
YES
```

**Ось тут уже виконується реальний Flash Swap.**

Перед кожним обміном скрипт бере нове свіже котирування. Якщо ціна стала гіршою більше допустимого ліміту, цей актив буде пропущений.

За замовчуванням допустиме погіршення — **1%**.

Для `USDC` і `USD` також перевіряється відхилення від 1:1.

Після прийнятого swap скрипт перевіряє фактичні баланси: вихідний актив повинен зменшитися, а `CROSSEX USDT` — збільшитися.

---

## 3. Переведення USDT на Gate Spot

Після обмінів скрипт покаже приблизно таке:

```text
CROSSEX USDT -> SPOT:
  available=12.21
  transfer amount=12.21
  estimated fee=0
```

Потім запитає:

```text
Transfer 12.21 USDT to SPOT? Type YES
```

Для переказу введіть:

```text
YES
```

Це внутрішній переказ:

```text
CrossEx USDT -> Gate Spot USDT
```

Після успіху буде повідомлення:

```text
Transfer SUCCESS
```

Після цього перевірте USDT на Gate у звичайному **Spot Account**.

---

# Якщо бачите помилку: file does not exist

Наприклад:

```text
The argument '.\gate_crossex_cleaner.ps1' to the -File parameter does not exist
```

Це означає, що PowerShell відкритий не в папці зі скриптом.

Якщо бачите:

```text
PS C:\Windows\System32>
```

закрийте це вікно.

Потім:

1. відкрийте папку `Gate-CrossEx-Cleaner` у Провіднику;
2. клікніть по адресному рядку;
3. введіть `powershell`;
4. натисніть Enter;
5. повторіть команду запуску.

Або можна вручну перейти в папку командою:

```powershell
cd "E:\Downloads\Gate-CrossEx-Cleaner"
```

Шлях у вас може бути інший.

Перевірити, що файл видно:

```powershell
Get-ChildItem .\gate_crossex_cleaner.ps1
```

Якщо файл показався — можна запускати скрипт.

---

# Якщо скрипт пише STOP, SKIP або AMBIGUOUS

### `SKIP`

Gate не підтримує цей актив для потрібного Flash Swap або котирування не пройшло перевірку. Актив не чіпається.

### `STOP`

Скрипт знайшов умову, за якої продовжувати небезпечно: наприклад відкритий ордер, позицію, борг або неправильний режим CrossEx.

### `AMBIGUOUS`

Gate міг уже прийняти фінансову операцію, але скрипт не зміг однозначно підтвердити її результат.

**Не запускайте скрипт повторно одразу.** Спочатку зайдіть у Gate і перевірте фактичні баланси/історію операцій.

---

# Які біржі підтримуються

Gate Flash Swap API зараз підтримує:

- Binance;
- OKX;
- Gate;
- Bybit;
- Hyperliquid;
- Kraken.

`DERIBIT` через цей Flash Swap endpoint не підтримується і буде пропущений.

Скрипт пробує обміняти доступний non-USDT актив у USDT. Якщо саме цей актив Gate не дозволяє обміняти — він буде `SKIP`.

---

# Важливо про ліміт Gate

Gate обмежує Flash Swap quote до:

```text
100 запитів на день
```

Тому не запускайте повний cleaner багато разів підряд без потреби.

---

# PowerShell 7

Якщо у вас встановлений PowerShell 7, можна використовувати `pwsh` замість `powershell`.

Найпростіше відкрити PowerShell 7 прямо в папці зі скриптом:

1. відкрийте папку у Провіднику;
2. клікніть по адресному рядку;
3. введіть `pwsh`;
4. натисніть Enter.

Перевірка балансу:

```powershell
pwsh -NoProfile -File .\gate_crossex_cleaner.ps1 -BalancesOnly
```

Повний запуск:

```powershell
pwsh -NoProfile -File .\gate_crossex_cleaner.ps1
```

Звичайний Windows PowerShell 5.1 також підтримується.

---

# Що скрипт НЕ робить

Скрипт не:

- виводить криптовалюту на зовнішню адресу;
- просить seed phrase;
- зберігає API Secret у файл;
- повторює автоматично операцію, якщо Gate міг уже її прийняти, але результат незрозумілий.

Python та інші програми не потрібні.

---

Офіційна документація Gate CrossEx API:

https://www.gate.com/docs/developers/crossex/
