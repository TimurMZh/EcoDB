# Резервные копии

Еженедельная логическая копия `eco_monitoring`, копии хранятся вне сервера базы, проверка восстановления — раз в квартал.

База — служба Windows **PostgreSQL 14** с PostGIS 3.4 (`docs/install-windows.md`). Каталог данных службы резервной копией не является: при порче диска он портится вместе с базой. Нужен дамп на другом сервере.

В `docs/data-requirements.md` ежедневный дамп и хранение копий 30 дней всё ещё помечены как не согласованные. Эта записка — еженедельный порядок.

## Что сохраняется

| Файл | Команда | Содержимое |
| --- | --- | --- |
| `eco_monitoring_YYYYMMDD.dump` | `pg_dump -Fc` | База `eco_monitoring` (схема `eco`, данные, представления) |
| `eco_globals_YYYYMMDD.sql` | `pg_dumpall --globals-only` | Логины и роли (`eco_admin`, `eco_etl`, `eco_gis` и остальные) |

Пользовательский формат (`-Fc`) восстанавливается через `pg_restore`. Без файла глобальных объектов у восстановленной базы нет логинов.

`pg_dump` не включает файлы вне базы. Если `DB_input\` (исходные Excel и PDF) есть только на этом сервере, копируйте эту папку тем же еженедельным заданием.

## Где лежат копии

| Место | Роль | Как долго |
| --- | --- | --- |
| `D:\eco-backups\staging` на сервере базы | свежий дамп, пока копия вне сервера не проверена | удалить после успешного копирования |
| Файловый ресурс, NAS или второй сервер (не этот узел) | копии, которые хранятся | 12 еженедельных дампов (около одного квартала) |

Срок в двенадцать недель нужен, чтобы квартальная проверка всегда имела настоящий дамп. Нижняя граница в 30 дней из `docs/data-requirements.md` короче.

## Пароль для дампа

Скрипт подключается к `localhost` как `eco` и пароль в файл скрипта не пишет. Один раз создайте `D:\eco-backups\pgpass.conf` — одну строку, без кавычек:

```
localhost:5432:*:eco:ПАРОЛЬ
```

`localhost` должно совпадать с `PGHOST` в `scripts/backup.bat` (по умолчанию `localhost`). Звёздочка нужна, потому что `pg_dumpall` подключается не только к `eco_monitoring`.

Файл читает учётная запись `SYSTEM`. Ограничьте его администраторами и `SYSTEM`:

```bat
icacls D:\eco-backups\pgpass.conf /inheritance:r /grant:r SYSTEM:R Administrators:R
```

Если в пароле есть `\` или `:`, поставьте перед каждым таким символом `\`.

## Еженедельный дамп

Задание — `scripts/backup.bat`. Оно выполняется на сервере базы от пользователя `eco`. Воскресенье, 02:00, когда ETL ничего не загружает.

`pg_dump -Fc` пишет файл сам, ключом `-f`. В Windows не перенаправляйте этот вывод через PowerShell: `>` считает поток текстом и портит файл. Метка даты берётся из PowerShell; сам дамп — нет.

Перед первым запуском задайте `SHARE` в начале `scripts/backup.bat`: это папка вне сервера. Утилиты по умолчанию ищутся в `C:\Program Files\PostgreSQL\14\bin`. Другой каталог — переменная `PGBIN`.

Зарегистрируйте задание один раз на сервере из командной строки администратора:

```bat
scripts\install-backup-task.bat
```

Создаётся задача **EcoDB weekly backup**: каждое воскресенье в 02:00, учётная запись `SYSTEM`, в том числе когда никто не вошёл в систему. `SYSTEM` должна запускать `pg_dump`, читать `D:\eco-backups\pgpass.conf` и писать в `D:\eco-backups`. Если в 02:00 сервер выключен, задача стартует, когда он снова доступен. Неудачный запуск завершается с кодом 1, оставляет файлы в staging и дописывает строку в `D:\eco-backups\backup.log`.

## Копия вне сервера базы

После контрольной суммы скрипт копирует дамп этой недели, файл глобальных объектов и файлы `.sha256` в `SHARE`. Он заново считает SHA256 на ресурсе и сравнивает с файлом `.sha256`. При совпадении удаляет копии в staging. При расхождении удаляет копии этой недели на ресурсе и оставляет staging на месте.

Затем удаляет на ресурсе файлы старше 84 дней (12 недель): `eco_monitoring_*.dump`, `eco_globals_*.sql` и их файлы `.sha256`.

## Проверка восстановления, раз в квартал

Делайте это в первую неделю каждого квартала на машине, которая не является промышленным сервером базы. На ней тоже PostgreSQL 14 и PostGIS 3.4. Берите самый новый дамп с ресурса. Не восстанавливайте поверх промышленной `eco_monitoring`.

1. Скопируйте `.dump`, `.sql` и `.sha256` этой недели на тестовую машину и проверьте контрольную сумму (`certutil -hashfile файл SHA256` и строка из `.sha256`).
2. Пустая база. Подставьте пароль суперпользователя тестовой машины. Пароль `restore-test` — только для этого прогона:

```bat
set PGPASSWORD=postgres-password
"C:\Program Files\PostgreSQL\14\bin\psql.exe" -h localhost -U postgres -d postgres -v ON_ERROR_STOP=1 -c "CREATE ROLE eco LOGIN SUPERUSER PASSWORD 'restore-test';"
"C:\Program Files\PostgreSQL\14\bin\psql.exe" -h localhost -U postgres -d postgres -v ON_ERROR_STOP=1 -c "CREATE DATABASE eco_restore WITH OWNER = eco ENCODING 'UTF8' TEMPLATE = template0;"
```

Если роль `eco` на тестовой машине уже есть, пропустите `CREATE ROLE`.

3. Загрузите роли, затем базу. `--exit-on-error` останавливается на первой ошибке восстановления. В `pgpass` тестовой машины или в `PGPASSWORD` — пароль `eco` этого прогона (`restore-test`):

```bat
set PGPASSWORD=restore-test
"C:\Program Files\PostgreSQL\14\bin\psql.exe" -h localhost -U eco -d eco_restore -v ON_ERROR_STOP=1 -f eco_globals_YYYYMMDD.sql
"C:\Program Files\PostgreSQL\14\bin\pg_restore.exe" -h localhost -U eco -d eco_restore --exit-on-error eco_monitoring_YYYYMMDD.dump
```

`pg_dumpall --globals-only` пытается создать роли. На пустой тестовой машине это нормально. На промышленном сервере этот файл не выполняйте.

4. Проверьте схему, числа строк, представление ArcGIS и PostGIS. Числа должны совпасть с промышленной базой на момент дампа:

```bat
"C:\Program Files\PostgreSQL\14\bin\psql.exe" -h localhost -U eco -d eco_restore -c "SELECT version FROM eco.schema_migrations ORDER BY version;"
"C:\Program Files\PostgreSQL\14\bin\psql.exe" -h localhost -U eco -d eco_restore -c "SELECT COUNT(*) FROM eco.results;"
"C:\Program Files\PostgreSQL\14\bin\psql.exe" -h localhost -U eco -d eco_restore -c "SELECT COUNT(*) FROM eco.vw_results_flat;"
"C:\Program Files\PostgreSQL\14\bin\psql.exe" -h localhost -U eco -d eco_restore -c "SELECT PostGIS_Version();"
```

5. Допишите одну строку в журнал рядом с копиями: дата, имя файла, контрольная сумма, число `eco.results`, успех или неудача, кто проверял.
6. Удалите тестовую базу:

```bat
"C:\Program Files\PostgreSQL\14\bin\psql.exe" -h localhost -U postgres -d postgres -c "DROP DATABASE eco_restore;"
```

Неудачная проверка означает, что подтверждённой копии ещё нет. Исправьте дамп или шаги восстановления и повторите проверку до следующего еженедельного задания.

## Учёт

| Пункт | Значение |
| --- | --- |
| Расписание | еженедельно, воскресенье 02:00, задача **EcoDB weekly backup** (`scripts/install-backup-task.bat`) |
| Скрипт | `scripts/backup.bat` |
| База | `eco_monitoring` |
| Формат | `pg_dump -Fc` и `pg_dumpall --globals-only` |
| Срок хранения | 12 еженедельных копий на именованном ресурсе, который не является сервером базы |
| Staging | `D:\eco-backups\staging`, удаляется после проверенной копии |
| Проверка восстановления | первая неделя каждого квартала, отдельная база `eco_restore` на PostgreSQL 14 + PostGIS 3.4, строка журнала как выше |
| Сбой | тому, кто ведёт сервер, сообщают, когда плановая задача завершилась с ошибкой |
