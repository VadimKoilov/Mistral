# DEVELOPMENT.md — внутреннее устройство Mistral

Документ для будущих доработок: как устроен проект, почему именно так, где какие
грабли лежат, и что можно улучшить. Пользовательская документация — в [README.md](README.md).

---

## 1. Архитектура в двух словах

```
┌────────────────────────────┐        UNIX-сокет          ┌──────────────────────┐
│  Mistral.app (ваш юзер)    │  /var/run/mistralctl.sock  │  mistrald (root)     │
│                            │ PING/BEAT/SETT/MODE/RESET  │  launchd-демон из    │
│  • чтение SMC — напрямую   ├───────────────────────────>│  /Library/LaunchDaemons
│    (temperatures, RPM)     │   ответы: OK… / ERR …      │  • записи в SMC:     │
│  • регулятор, UI, меню     │<───────────────────────────┤    F0Tg, F0Md, Ftst  │
└────────────────────────────┘                            └──────────┬───────────┘
        │ чтение (root не нужен)                                     │ запись
        v                                                            v
┌──────────────────────────── AppleSMC.kext ────────────────────────────────┐
│              вентиляторы (F0Ac/F0Tg/F0Md…), датчики (Tp01…)               │
└───────────────────────────────────────────────────────────────────────────┘
```

Ключевой факт macOS: **чтение SMC доступно обычному пользователю, запись — только
root**. Поэтому чтение (датчики, обороты) приложение делает само и без прав, а все
записи идут через root-демон `mistrald`. Это ровно та же схема, что у Macs Fan
Control и Stats (privileged helper).

---

## 2. Модули

| Путь | Что это |
|---|---|
| `Sources/SMCCore/SMC.swift` | Swift-обёртка над AppleSMC user client: открытие соединения, чтение/запись ключей, перечисление, декодирование типов, API вентиляторов (`fanCount`, `fanInfo`, `setFanTarget`, `setFanManual`, `setFanAuto`, `restoreSystemControl`) |
| `Sources/Mistrald/main.swift` | root-хелпер: UNIX-сокет-сервер, 4 команды, проверка uid клиента |
| `Sources/Mistral/main.swift` | точка входа AppKit (`NSApplication.shared.run()`), без SwiftUI @main |
| `Sources/Mistral/AppDelegate.swift` | lifecycle: старт контроллера, статус-меню, режимы отладки, возврат вентиляторов системе при выходе |
| `Sources/Mistral/FanController.swift` | мозг: опрос каждые 2 с, авто-регулятор, режимы (system/auto/manual), профили, бусты, watchdog, сон/пробуждение, автозапуск, `CPULoad` |
| `Sources/Mistral/StatusMenuController.swift` | `NSStatusItem` + `NSMenu` (меню как у Macs Fan Control), перестраивается при каждом открытии |
| `Sources/Mistral/PanelView.swift` | окно панели (SwiftUI) + `MainWindow` + snapshot-режим для тестов UI |
| `Sources/Mistral/PrivilegedControl.swift` | клиент сокета хелпера + установка/удаление через нативный диалог пароля (osascript) |
| `Sources/Probe/main.swift` | CLI-диагностика SMC (дамп ключей, температуры, `--testwrite`, `--watch`) |
| `scripts/build-app.sh` | релиз-сборка → иконка → `dist/Mistral.app` → ad-hoc codesign |
| `scripts/makeicon.swift` | генерация иконки (AppKit, CGPath) |
| `scripts/Info.plist` | бандл-плvist: `LSUIElement`, минимум macOS 13 |

---

## 3. Слой SMCCore — самое важное знать

### 3.1 Структура обмена (и главные грабли проекта)

Обмен с `AppleSMC.kext` идёт через `IOConnectCallStructMethod(conn, 2, in, 80, out, 80)`
структурой из 80 байт (описана в открытом коде Apple PowerManagement `PrivateLib.c`):

```
key:4 | vers:6 | pLimitData:16 | keyInfo: {dataSize:4, dataType:4, attr:1}
| padding:2 | result:1 | status:1 | data8:1 | data32:4 | bytes:32
```

**ГРАБЛЯ №1: структура должна быть объявлена в Swift, не в C.**
Pure-Swift структура даёт `MemoryLayout.stride == 80` (Swift пакует поля плотнее),
а та же структура в C на arm64 даёт **84 байта** → ядро отвечает
`kIOReturnBadArgument (0xe00002c2)`. Не пытайтесь «улучшить» — проверить можно так:

```bash
swiftc /tmp/layouttest.swift -o /tmp/lt && /tmp/lt   # должно быть 80
```

Поля `key` и `dataType` — FourCC (4 символа = UInt32 big-endian: `"F0Tg"` → 0x46305467).

### 3.2 Команды (поле data8, передаётся через user client с индексом 2)

| data8 | Команда | Что делает |
|---|---|---|
| 5 | readKey | прочитать bytes (нужен `keyInfo.dataSize`) |
| 6 | writeKey | записать bytes (нужен `keyInfo.dataSize`) |
| 8 | getKeyFromIndex | ключ по индексу (для перечисления; `data32` = индекс) |
| 9 | readKeyInfo | размер и тип ключа |

Коды результата в поле `result`: `0` — успех, `0x84` (132) — ключ не существует.

### 3.3 Типы данных и кодирование (`SMCCodec`)

Значения SMC приходят как байты + тип. Реализованы:

- `flt ` — Float32, little-endian (температуры и обороты на Apple Silicon!)
- `fpe2` — UInt16 BE / 4 (обороты на Intel)
- `sp78`, `fp88`, `fp79` и остальные fp/sp — Int16 BE / 2^n (температуры Intel)
- `ui8/ui16/ui32/ui64`, `si8/si16`, `flag` — UInt BE

**Кодирование при записи всегда подбирается по фактическому типу ключа** — сначала
`keyInfo(key)`, потом `SMCCodec.encode(value:size:type:)`. Это позволяет не зависеть
от того, какой у данной машины тип оборотов (`flt ` на M1 vs `fpe2` на Intel).

### 3.4 Ключи SMC, используемые в проекте

| Ключ | Тип | Смысл |
|---|---|---|
| `FNum` | ui8 | число вентиляторов |
| `F<i>Ac` | flt | текущие обороты |
| `F<i>Tg` | flt | целевые обороты (запись = установка скорости) |
| `F<i>Mn` / `F<i>Mx` | flt | min/max диапазон (на MBP 14 M1 Pro: 1200 / 5779 и 6241) |
| `F<i>Id` | — | имя вентилятора (на M1 Pro ключа нет, поэтому «Вентилятор 1/2») |
| `F<i>Md` / `F<i>md` | ui8 | режим: **0 = системный авто, 1 = ручной** |
| `Ftst` | ui8 | глобальный флаг тест-режима SMC; **запись 0 = вернуть всё системе** |
| `#KEY` | ui32 | общее число ключей (для перечисления через команду 8) |
| `Tp01, Tp05, Tp0D, Tp0H, Tp0L, Tp0P, Tp0X, Tp0b` | flt | P-ядра CPU (M1-семейство) |
| `Tp09, Tp0T` | flt | E-ядра CPU |
| `Tg05, Tg0D, …` | flt | GPU |

Таблицы ключей температур **зависят от чипа**. Источник для новых чипов (M2/M3/M4/M5):
[narugit/smctemp `smctemp.cc`](https://github.com/narugit/smctemp) и
[exelban/stats `values.swift`](https://github.com/exelban/stats). Дамп всех ключей
этой машины: `swift build --target Probe && .build/debug/Probe --all`.

### 3.5 API SMCCore (кратко)

```swift
let smc = SMC.shared
try smc.open()                       // IOServiceOpen("AppleSMC")
smc.readValueOpt("F0Ac")             // Double? — чтение с декодированием, nil при ошибке
try smc.writeValue("F0Tg", 3000)     // запись с кодированием по типу ключа
smc.readRawByte("F0Md")              // UInt8? — сырой байт (флаги Ftst/F0Md)
try smc.writeRawByte("F0Md", 1)
try smc.keyInfo("F0Tg")              // KeyInfo(size:type:)
try smc.keyCount(); try smc.allKeys()// перечисление (медленно, для диагностики)
smc.restoreSystemControl(fans: 2)    // Ftst=0 + F<i>Md=0 для всех
```

`infoCache` кеширует типы ключей — сбрасывается в `close()`.

---

## 4. Хелпер mistrald

### 4.1 Почему root и как он изолирован

- Все записи SMC под обычным пользователем дают `kIOReturnNotPrivileged` — проверено
  на этой машине (`Probe --testwrite`).
- Хелпер ставится в `/usr/local/mistral/mistrald`, запуск — launchd-демон
  `/Library/LaunchDaemons/app.mistral.helper.plist` (`KeepAlive`, `RunAtLoad`).
- Сокет `/var/run/mistralctl.sock`, права 0666, но `getpeereid()` сверяет uid клиента
  с `/usr/local/mistral/owner.uid` (uid записывается при установке) — чужие
  пользователи не могут крутить ваши вентиляторы.
- Хелпер принимает ограниченный набор команд, обороты клампятся в [Mn…Mx].

### 4.2 Протокол (строка + `\n`, ответ + `\n`)

```
PING              -> OK mistrald <версия> <uid-хелпера>
BEAT              -> OK                    (хартбит живого клиента, раз в тик)
SETT <fan> <rpm>  -> OK <rpm> <min> <max>   | ERR <текст>
MODE <fan> <0|1>  -> OK | ERR              (0=системный авто, 1=ручной)
RESET             -> OK | ERR              (Ftst=0 + все F<i>Md=0)
```

**Watchdog хелпера** (с версии 1.1): клиент шлёт `BEAT` раз в тик, пока управляет.
Если ручной режим включён, а `BEAT` не приходил 20 с (краш/kill приложения), хелпер
сам возвращает вентиляторы системе (CLOCK_MONOTONIC — сон не считается простоем).
То же — при старте демона, если вентиляторы остались ручными от прошлого запуска.

Ручная проверка (подходит и для отладки):

```bash
printf 'PING\n' | python3 -c "import socket,sys;s=socket.socket(socket.AF_UNIX,socket.SOCK_STREAM);s.connect('/var/run/mistralctl.sock');s.sendall(sys.stdin.buffer.read());print(s.recv(256).decode())"
```

Лог хелпера: `/usr/local/mistral/helper.log` (перенаправлен в plist'е).

### 4.3 Установка/удаление

Кнопка в приложении вызывает `/usr/bin/osascript` (отдельным процессом —
**NSAppleScript нельзя дёргать вне main-потока**, мы на этом обжигались) с
`do shell script … with administrator privileges`. Сами команды — из
`PrivilegedControl.install()`. Удаление: `launchctl bootout` + `rm`.

---

## 5. Регулятор (FanController)

### 5.1 Тик (каждые 2 с, main thread)

1. температуры: max по `Thermals.cpuKeys` (валидные 5…120°C), max по GPU-ключам
2. обороты каждого вентилятора (`F<i>Ac`, `F<i>Tg`)
3. нагрузка CPU (`host_statistics64`, доля user+sys+nice)
4. если режим `.auto` → `regulate()`
5. самолечение (раз в 5 тиков): `F<i>Md` сброшен — возвращаем; в `.manual` —
   цель не применилась (Tg не совпал) — повторяем запись
6. запись точки в историю (120 точек ≈ 4 мин)
7. в режиме `.system` — лёгкий PING хелпера; в остальных — хартбит `BEAT` и
   контроль доступности

### 5.2 Формула целевых оборотов

```
frac = кривая(профиль, Tcpu)                    // кусочно-линейная, см. Profile.points
     + 0.12  если dT/dt > 0.25 °C/с             // предиктивный буст
     + 0.10  если load > 0.6 два тика подряд    // буст по нагрузке (отключаемый)
     = 1.0   если Tcpu >= 92                    // защита
frac = min(frac, 1.0)
frac = max(frac, lastFrac - 0.06)               // спуск не быстрее 6%/тик (анти-«пила»)

rpm = floor((Mn + frac * (Mx - Mn)) / 50) * 50  // шаг 50 об/мин
запись через хелпер — только если |rpm - прошлые записанные| >= 30
```

Кривые профилей задаются в `FanController.Profile.points` — правятся одним местом.
«Турбо» стартует с 45% и выходит на 100% уже при 60°C; «Производительность» —
дефолт (45°C старт, 100% при 80°C).

### 5.3 Состояния и переходы

- `system` — никаких записей (штатное управление macOS)
- `auto` — MODE 1 всем + постоянная запись Tg
- `manual` — MODE 1 + ручные Tg (слайдеры в панели, пункты меню)

Переходы: выход/сон/«Система» → `restoreSystemQuiet()` (RESET хелперу);
просыпание → повторный вход в сохранённый режим; 3 подряд ошибки хелпера →
авто-возврат в `system` с предупреждением в UI. Режим/профиль/буст хранятся в
UserDefaults (`mode`, `profile`, `loadBoost`) и восстанавливаются при старте.

---

## 6. UI

- **Меню** (`StatusMenuController`): `NSStatusItem` (иконка `fan` + температура,
  обновление через Combine-подписку на `objectWillChange`), `NSMenu` пересобирается
  в `menuNeedsUpdate` при каждом открытии — просто и всегда актуально.
  Грабля: элементы-«заголовки» секций делаем `isEnabled = false`, а **родителей
  подменю — `isEnabled = true`** (иначе подменю не открывается).
- **Панель** (`PanelView`): SwiftUI, хостится в `NSWindow` через `NSHostingView`
  (`MainWindow.show()`), открывается из меню. Кнопка «Выйти» = `NSApp.terminate` →
  `applicationWillTerminate` возвращает вентиляторы системе.
- **Threading**: таймер и весь UI — main thread; установка/удаление хелпера и
  autostart-fallback — в background queue с колбэком на main; сокет — блокирующий
  с таймаутами 0.5 с (SO_RCVTIMEO/SO_SNDTIMEO).

---

## 7. Сборка, запуск, отладка

```bash
cd /Users/vadimkojlov/StudioProjects/Mistral
./scripts/build-app.sh          # → dist/Mistral.app (build + icon + bundle + codesign)
open dist/Mistral.app           # обычный запуск (иконка в меню-баре)

# отладочные режимы запуска:
open dist/Mistral.app --args --debugwindow            # панель отдельным окном
open dist/Mistral.app --args --snapshot /tmp/p.png    # PNG панели + выход (для тестов UI)

# диагностика SMC:
swift build --target Probe
.build/debug/Probe            # вентиляторы + температуры + CPU/GPU ключи
.build/debug/Probe --all      # дамп ВСЕХ ключей T* с типами
.build/debug/Probe --watch 30 # монитор 30 сек
.build/debug/Probe --testwrite# тест записи оборотов (+500 RPM, затем возврат системе)

# переменные окружения для разработки:
MISTRAL_DEMO=1     # фейковый «установленный» хелпер без записей (для UI)
MISTRAL_SOCKET=/tmp/x.sock  # другой путь сокета
```

`swift build` после переноса папки частично пересобирается — норма (в `.build`
зашиты абсолютные пути).

### Снапшоты UI: известный артефакт

Offscreen-рендер панели (`--snapshot`) рисует **заглушки вместо picker/toggle/button
и чёрные прямоугольники вместо текста в `.primary`** — это артефакт рендера SwiftUI
вне экрана, в живом приложении всё корректно (проверено). Структуру/компоновку он
показывает верно.

---

## 8. Идеи для доработок (roadmap)

1. **Подписание и notarization** (Developer ID): уберёт страшное окно «Apple could
   not verify…» при установке хелпера и позволит распространять сборку. С нормальной
   подписью можно перейти с osascript на `SMAppService.daemon` (нативное системное
   окно одобрения вместо ввода пароля).
2. **Кастомная кривая**: редактор точек в панели (профиль хранить в UserDefaults).
3. **Датчик на выбор**: сейчас берётся max CPU-ключей; можно дать выбор «сенсора
   привязки» (GPU/SOC/макс-всё) и/или усреднение как в smctemp.
4. **Уведомления о перегреве**: `UNUserNotificationCenter` при T > 90°C.
5. **Имена вентиляторов** «Left side/Right side» — хардкод по модели (`hw.model`)
   либо словарь, т.к. ключа `F<i>ID` на M1 Pro нет.
6. **Экспорт истории** (CSV) и окно со статистикой за день.
7. **Тесты**: SMCCore хорошо тестируется — SMCCodec.decode/encode как unit-тесты,
   регулятор — чистая функция (вынести `curveFrac(profile, t, rate, load)` отдельно).
8. **Локализация**: строки сейчас в коде по-русски; при желании вынести в
   `Localizable.strings` (RU + EN).

### Известные компромиссы (осознанные)

- В режиме `.auto` один вентилятор можно вернуть «Системному авто» из подменю;
  регулятор исключает его из повторных включений (`engagedFans`), но кривую на него
  всё равно посчитает — при `F0Md=0` SMC запись `F0Tg` игнорирует, так что вреда нет.
- Автозапуск через `SMAppService.mainApp` работает надёжнее для приложения из
  /Applications.

### Грабли SMC на живой железке (MacBookPro18,3, измерено)

Это самое неочевидное в проекте, при доработках держать в голове:

1. **SMC коммитит записи пакетно, своим внутренним циклом.** Чтение `F#Md`/`F#Tg`
   сразу после записи может до ~0.7 с (иногда дольше) отдавать старое значение —
   это НЕ значит, что запись не прошла (проверено сэмплером 4 Гц: MODE+SETT
   применились вместе, читатель увидел их одновременно позже).
2. **`SETT` при `F#Md=0` отбрасывается молча** — хелпер отвечает `OK`, но Tg не
   меняется. Отсюда классический симптом «включил профиль, а обороты стоят»:
   запись цели, попавшая в окно до коммита ручного режима, теряется. Лечится
   verify-and-reassert в `writeTargets()`/самолечении тика (сверка Tg и повтор).
3. **`MODE 1` сам по себе держится** (цель замирает на последнем значении), но
   системный термоагент изредка пишет `F#Md` сам — поэтому самолечение раз в 10 с.
4. **Ключа `Ftst` на этой модели нет** — `restoreSystemControl` его просто
   пропускает, работает возврат `F#Md=0`.
5. **Чтение SMC доступно обычному юзеру, запись — только root** (весь смысл хелпера).

---

## 9. Диагностика проблем

| Симптом | Что смотреть |
|---|---|
| «Хелпер не отвечает» | `pgrep -fl mistrald`, `/usr/local/mistral/helper.log`, сокет `ls -la /var/run/mistralctl.sock` |
| Пункты меню недоступны | хелпер не установлен — «Ещё → установить» или кнопка в панели |
| Вентиляторы «залипли» на ручных оборотах | с watchdog'ом (v1.1) хелпер сам вернёт их системе через ~20 с после смерти приложения; при старте демона тоже чистит |
| `Probe` пишет not privileged на запись | ожидаемо без root — записи только через хелпер |
| Температуры n/a | новые ключи чипа — дамп `Probe --all`, добавить в `Thermals.cpuKeys` |

---

## 10. Благодарности и лицензии

Логика SMC основана на открытых реализациях (все MIT, лежали в `refs/` рабочей папки):

- [beltex/SMCKit](https://github.com/beltex/SMCKit) — каноническая Swift-структура обмена
- [narugit/smctemp](https://github.com/narugit/smctemp) — ключи температур Apple Silicon
- [exelban/stats](https://github.com/exelban/stats) — механика `Ftst`/`F0Md`, privileged helper

Для личного использования ограничений нет; при публикации исходников — указать
авторов упомянутых проектов (MIT требует сохранения копирайт-строк).
