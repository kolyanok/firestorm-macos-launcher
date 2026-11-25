# Firestorm macOS 12.0.7.68974 — комплексный bypass сертификатов (x86_64 / Intel)

Это x86_64-версия комплексного патча. Она делает то же, что arm64-версия,
но для Intel-среза универсального клиента.

## Что найдено в x86_64-клиенте

| Путь | Адрес | Что проверяет |
|---|---|---|
| Blizzard DarwinSSL wrapper | `0x1026BC3C0` | SecureTransport + `SecTrustEvaluate`; возвращает 0/0x3FE/0x3FD |
| DarwinSSL verify bool | `0x1026BCDF0` | `SSLCopyPeerTrust` + `SecTrustEvaluate` |
| OpenSSL `ssl_verify_internal` | `0x1029A5690` | verify callback OpenSSL |
| OpenSSL chain verifier | `0x1029A69C0` | вызывается из `tls_post_process_server_certificate` |
| cross_ssl | `SecTrustEvaluate` | отдельная SecureTransport-реализация |

Адреса получены из runtime-дампа x86_64-среза: on-disk `__text` защищён,
поэтому статически найти функции нельзя. Дамп снят через SIGTRAP-обработчик,
который пропускает anti-tamper `int3` и даёт игре расшифровать код.

## Что делает патч

1. **Interpose Security framework:** `SecTrustEvaluate`, `SecTrustEvaluateWithError`,
   `SecTrustGetTrustResult`, `SecTrustEvaluateAsync*` — всегда успех.
2. **SecureTransport:** `SSLCreateContext`/`SSLSetSessionOption` включают
   `BreakOnServerAuth`, `SSLHandshake` продолжается после `errSSLServerAuthCompleted`.
3. **DarwinSSL wrapper `0x1026BC3C0`:**
   ```asm
   xor eax, eax
   ret
   ```
   Это аналог Windows-патча `0x2641250` и arm64-патча `0x1023BF420`.
4. **OpenSSL verify callback `0x1029A5690`:**
   ```asm
   mov eax, 1
   ret
   ```
5. **OpenSSL chain verifier `0x1029A69C0`:**
   ```asm
   mov eax, 1
   ret
   ```
6. **Anti-tamper:** x86_64-срез содержит `int3`, который срабатывает при
   изменении бинарника. SIGTRAP-обработчик пропускает его (RIP уже указывает
   на следующую инструкцию), поэтому игра продолжает работать.

## Установка

```bash
bash apply.sh "/path/to/World of Warcraft.app"
```

Скрипт добавит `LC_LOAD_DYLIB` в **x86_64-срез**, положит dylib в
`Contents/MacOS` и переподпишет app. Откат — `revert.sh`.

В исходниках репозитория собранная dylib отсутствует. Перед ручным запуском
`apply.sh` скопируйте `libFirestormCertBypassX86.dylib` из
`Contents/MacOS` подготовленного `World of Warcraft.app`, включённого в
релиз лаунчера, в папку рядом с `apply.sh`. В лаунчере патч уже входит в клиент.

Лог: `/tmp/FirestormCertBypassX86.log`. В нём должны быть:
```
DarwinSSL_wrapper status=...
antitamper_int3_skipped status=...
OpenSSL_verify_callback status=...
OpenSSL_chain_verifier status=...
```

## Проверка

На тестовой копии под Rosetta все три внутренних патча применились,
anti-tamper `int3` был пропущен. Полноценный GUI-запуск в этом окружении
не проверен: игра, запущенная из headless-сессии, падает в AppKit/HIServices.
Проверяйте в обычной графической сессии на Intel или через Rosetta.

## Ограничения

- Это bypass **клиентской** проверки серверного сертификата. Он не меняет
  сертификат/ключ, который клиент предъявляет серверу.
- Если после патча остаётся `BLZ51900003`, сервер отклоняет logon по другой
  причине: auth-сертификат/ключ клиента, версия протокола, build или учётные
  данные. В логах это видно как `Front disconnected result="3"`.
- Патч предназначен для x86_64-среза. На Apple Silicon без Rosetta клиент
  запускает arm64-срез — используйте arm64-версию патча.

## Файлы

- `FirestormCertBypassX86.c` — исходник dylib.
- `libFirestormCertBypassX86.dylib` — собранный x86_64 dylib.
- `apply.sh` — установка.
- `revert.sh` — откат.
- `add_dependency_x86_64.py` — добавление `LC_LOAD_DYLIB` в x86_64-срез.
- `Entitlements.plist` — entitlements для повторной подписи.
