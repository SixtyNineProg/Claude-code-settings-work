# Зачистка следов Workfusion в мигрированном процессе

Правило: миграция считается завершённой не тогда, когда код работает, а когда в проекте не
осталось ссылок на исходный WF-процесс. Миграционные комментарии — временный scaffolding: после
переноса они вводят в заблуждение и мешают читать Sherpa-код как нативный.

## Когда запускать

- После того как Step-классы, конфигурация и `README.md` финальны (конец Phase 5).
- До Semantic Equivalence Gate: гейт должен видеть финальный текст кода, а не промежуточный.
- До коммита/мержа; отдельным проходом, когда структура кода уже не меняется.
- Если следов не найдено — зафиксируйте 0 в отчёте/описании MR и переходите к коммиту.

## Что считается следом WF

### Явные упоминания

`WF`, `Workfusion`, `work fusion`, `WF-` (например, `WF-путь`), `[WF]`.

### Косвенные артефакты

Имена WF-классов, процессоров, датасторов, модулей и путей — даже без слова «WF»:

| Категория | Примеры |
|---|---|
| Processor / Supplier | `PrepareSapProcessor`, `UpdateDocProcessor`, `DocumentProcessor`, `JoinProcessor`, `InfrastructureSupplier` |
| Datastore / JDBC | `AccountsDatastore`, `PostingsRunsDatastore`, `AppTransaction`, `AppDoc`, `insertRow`, `delete from @this`, `update @this set`, `select * from @this` |
| Сервисы / модули | `S3Service`, `S3Bucket`, `CurrencyRateUtil`, `CurrencyRateDto`, `SharePointUnifiedFolders`, `SapQueueManager`, `SapExpectantDTO`, `SapRobotModule`, `CurrencyRateModule`, `S3Module`, `HumanTask`, `SystemNotificationService`, `EmailSendInfoDTO` |
| Конфиги / исключения / секреты | `AppInitParams`, `AppConfigParams`, `AppProcessException`, `SVMimCredentials`, `SVSharePointCredentials` |
| Пути и библиотеки | `mt/mt_01/...`, `mt/mt_02/...`, `join_intake`, `powershell/`, `lib_a1`, `by.a1.lib.*` |

### Поиск

Из корня `rpa-suite`:

```bash
cd {rpa-suite-directory}

# 1. Явные упоминания. \bWF\b — без -i, чтобы не ловить случайный lowercase "wf";
#    (?i) применяется только к полным названиям.
rg -n --no-heading \
  -g '!**/build/**' -g '!**/.gradle/**' -g '!**/.backup/**' \
  -g '!**/out/**' -g '!**/bin/**' -g '!**/target/**' \
  -g '!*.process' -g '!*.sherpa' -g '!*.sherpax' -g '!*.robot' \
  -g '!*.png' -g '!*.jpg' -g '!*.jpeg' -g '!*.xlsx' -g '!*.xls' \
  -g '!*.jar' -g '!*.class' -g '!*.zip' \
  -e '(?i)workfusion' -e '(?i)work fusion' -e '(?i)воркфьюжн' \
  -e '\bWF\b' -e 'WF-' \
  "{process-dir}"

# 2. Косвенные legacy-артефакты
rg -n --no-heading \
  -g '!**/build/**' -g '!**/.gradle/**' -g '!**/.backup/**' \
  -g '!**/out/**' -g '!**/bin/**' -g '!**/target/**' \
  -g '!*.process' -g '!*.sherpa' -g '!*.sherpax' -g '!*.robot' \
  -e 'AppProcessException|AppInitParams|AppTransaction|AppDoc|DataStoreField' \
  -e '\b[A-Z][A-Za-z0-9_]*(Processor|Supplier|Datastore)\b' \
  -e 'SVMimCredentials|SVSharePointCredentials|S3Module|SapRobotModule|CurrencyRateModule|SapQueueManager|SapExpectantDTO|SharePointUnifiedFolders|S3Service|S3Bucket|HumanTask|SystemNotificationService|EmailSendInfoDTO' \
  -e '(?i)датастор|datastore' \
  -e 'mt/mt_[0-9]+|join_intake|lib_a1|by\.a1\.lib|powershell/' \
  "{process-dir}"

# 3. Только комментарии (если поиск по косвенным именам даёт шум в коде)
rg -n -g '*.java' '^\s*(?:\*|//|/\*)' "{process-dir}/src" \
  | rg -e '(?i)workfusion' -e '\bWF\b' -e 'WF-' \
       -e 'Processor|Supplier|Datastore|AppInitParams|AppTransaction|AppProcessException'
```

> Совпадение в комментарии — кандидат на переписывание. Совпадение в коде или конфиге сначала
> проверьте: если это функциональное имя или runtime-строка — не трогайте.
>
> Список намеренно широкий: `datastore`, `UnifiedFoldersUtil`, `*Processor` могут быть текущими
> именами Sherpa или строками логов. Просматривайте каждое совпадение вручную, а не удаляйте по
> шаблону. Например, `UnifiedFoldersUtil` — актуальный класс `rpa-core`, его трогать нельзя.

PowerShell-эквивалент:

```powershell
Get-ChildItem <process-dir> -Recurse -File -Include *.java,*.js,*.json,*.md,*.gradle |
  Where-Object { $_.FullName -notmatch '\\(build|\.gradle|\.backup|out|bin|target)\\' } |
  Select-String -Pattern '(?i)workfusion', '\bWF\b', 'WF-'
```

### Ложные срабатывания

- `build/**`, `.gradle/**`, `out/**`, `bin/**`, `target/**` — сгенерированные/скомпилированные копии.
- `.backup/**` — автосохранения Designer (`*.sherpa [1]`); не редактировать.
- `.process`, `.sherpa`, `.sherpax`, `.robot` — сгенерированные файлы; в `.process` base64
  скриншотов может случайно содержать `WF`.
- `*.png`, `*.jpg`, `*.xlsx`, `*.jar`, `*.class`, `*.zip` — бинарные данные.
- `work_start`, `work_end`, `WORKFLOW_STATUS`, `workflow` — не Workfusion.
- Слова в контрактах с внешними системами: адреса и идентификаторы вида `...WorkFusion@a1.by`,
  `systemName: "WorkFusion"`, `srv-wf-*` — это данные интеграции, а не след миграции.

## Что нельзя менять

Зачистка — это работа с комментариями и Javadoc, а не рефакторинг. Не переименовывайте:

- функциональные ключи init params (`spVactproBase`, `spVactproProject`, `spVactproPath` и т.п.) —
  они приходят из конфигурации Orchestrator;
- имена ассетов, очередей, тегов, шаблонов и поля `@SerializedName` — это контракты данных;
- текущие классы, методы и константы Sherpa, даже если имя совпадает с WF-именем
  (`SharePointModule`, `SapRobotMock`): переписывайте только окружающий комментарий;
- SQL, регулярки и имена полей в рабочем коде: правки допустимы только в комментариях;
- runtime-строки логов и сообщений об ошибках (`to s3`, `S3 folder structure…`) — их текст
  наблюдаем в проде; менять только отдельной задачей с согласованием;
- историю git и сообщения существующих коммитов;
- сгенерированные `README.md` и docs: при следах WF перегенерируйте `write-readme` /
  `write-documentation`, а не правьте вручную.

Если сомневаетесь, функциональное это имя или историческое, — оставьте и отметьте в отчёте.

## Правила переписывания

Смысл сохраняем, историю убираем. Миграционная фраза почти всегда несёт две вещи: (1) откуда
взялся код и (2) почему он отличается от исходника. Первое не нужно, второе — часто единственное
объяснение неочевидного решения.

| Было | Стало |
|---|---|
| `Перенесён из WF {@code entity/Account.java} дословно.` | Удалить фразу и дать описание сущности по факту. Если Javadoc состоял только из неё — написать краткое назначение класса, но не оставлять Javadoc пустым у public-класса. |
| `Соответствует WF {@code processor/PrepareSapProcessor}: создаёт …` | `Создаёт …` — оставить только описание поведения. |
| `Заменяет WF {@code service/S3Service}` | `Обёртка над файловым хранилищем оркестратора. Файлы процесса лежат в Orchestrator Storage …` |
| `<p><b>Platform-forced отклонения от WF:</b>` | `<p><b>Ограничения платформы:</b>` — пункты переписать как ограничения Sherpa, без «в WF было иначе». Чисто исторические пункты (переименование классов) удалить. |
| `WF-путь`, `WF-датасторы`, `WF-задача MT №2` | `исходный путь`, `ассеты`, `задача MT №2` |
| `TODO: перенести из WF mt/mt_02/review_postings.js загрузку вложения` | `TODO: прикладывать вложение через ShadowCore.uploadFile …` — актуальная задача без legacy-ссылки. |
| `TODO: перенести проверки из WF …` (логика уже реализована ниже) | Удалить TODO целиком. |
| `WF {@code S3Bucket.putToFile} перезаписывал объект безусловно` | `upload() запрещает перезапись занятого имени` — оставить причину текущего поведения. |
| `Имена полей оставлены как в WF` | `Имена полей совпадают с кодами ответов формы` |
| `Платформенно-вынужденные отличия:` / `Отличия вынуждены платформой:` | `Ограничения платформы:` (или `Особенности реализации:`, если это не ограничение) |
| `в WF было …` / `как в WF` | Удалить историческую часть; оставить поведение Sherpa и причину отличия |
| `(WF {@code spVactproPath})` у `@param` | `(ключ {@code spVactproPath} в init params)` — функциональный ключ остаётся. |

После удаления фразы проверьте Javadoc: не должно остаться `/** */`, строк только с `<p>`/`</p>`,
висячих `*` и заголовков «Ограничения платформы:» без пунктов. Если Javadoc public-класса
состоял только из миграционной фразы — напишите краткое назначение класса, а не оставляйте
пустой блок.

Не переносите в новый код WF-специфичные объяснения (регулярки окон `REGEXPTITLE`, имена
датасторов, SQL). Оставляйте только то, что объясняет поведение Sherpa-реализации.

## Верификация

1. Повторите оба поиска: явный — **0** совпадений; косвенный — каждое совпадение либо
   переписано, либо осознанно оставлено (функциональное имя/строка). Список исключений —
   в описании MR.
2. Пустые Javadoc:
   `rg -n -U '/\*\*\s*\*/|/\*\*\s*\n(?:\s*\*\s*\n)+\s*\*/' <process-dir>/src` → 0;
   плюс глазами: `<p>` без текста, висячие `*`.
3. Diff:
   `git diff -U0 -- '*.java' '*.js' '*.md' | rg '^[+-]' | rg -v '^(\+\+\+|---)'`
   → каждая строка — комментарий/Javadoc; если попал код, строка лога или имя поля — откатите.
4. Скомпилируйте и прогоните тесты:
   `gradle :<module>:compileJava :<module>:compileTestJava` и `gradle :<module>:test`.
5. Просмотрите `{@link}` — все ссылки должны указывать на существующие классы Sherpa, а не на
   удалённые legacy-имена.

## Git: не смешивать с чужим WIP

Если в рабочем дереве есть незакоммиченные изменения, не связанные с зачисткой, и они пересекаются
в тех же файлах:

1. Сохраните текущие версии файлов во временный каталог.
2. `git checkout HEAD -- <files>` — верните файлы к последнему коммиту.
3. Повторно примените только правки комментариев.
4. `git commit -- <cleanup-paths>` — commit только этих путей; не используйте `git add -A`
   (в индекс могут попасть чужие новые файлы). Проверьте `git show --stat HEAD`, что WIP-файлов
   в коммите нет.
5. Восстановите сохранённые версии файлов — WIP останется в рабочем дереве нетронутым.

## Чек-лист

- [ ] Явные `WF`/`Workfusion` — 0 совпадений в `src/` и документации.
- [ ] Косвенные legacy-имена (`*Processor`, `*Datastore`, `S3Service`, `mt/mt_0*`, `join_intake`)
      удалены или переписаны.
- [ ] Функциональные ключи, имена ассетов/полей и runtime-строки не изменены.
- [ ] Javadoc public-классов не пустые; у отклонений сохранено объяснение «почему».
- [ ] Diff содержит только комментарии/Javadoc.
- [ ] Оставшиеся косвенные совпадения — только функциональные имена/строки; список в описании MR.
- [ ] README/docs при необходимости перегенерированы, а не отредактированы вручную.
- [ ] Компиляция и тесты зелёные.
- [ ] Коммит зачистки отделён от несвязанного WIP.
