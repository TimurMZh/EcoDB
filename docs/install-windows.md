# Установка на Windows Server

EcoDB работает на PostgreSQL 14 и PostGIS 3.4, установленных как служба Windows. Docker не используется.

Служба, база и схема:

1. Установить PostgreSQL 14 и PostGIS 3.4.
2. `scripts\init-db.ps1` — роль `eco` и база `eco_monitoring`.
3. `sql\apply.ps1` — схема `eco`.
4. ETL и Query Layer ArcGIS, как в `docs/loading-data.md` и `docs/ops-handover.md`.

## PostgreSQL 14

Установщик EDB, бесплатный: [PostgreSQL 14 для Windows](https://www.enterprisedb.com/downloads/postgres-postgresql-downloads). Берите ветку 14, не 15 и не 16: миграции и ArcGIS проверены на 14.

В мастере установки:

| Параметр | Значение |
| --- | --- |
| Компоненты | PostgreSQL Server, Command Line Tools, pgAdmin 4 |
| Каталог данных | `C:\Program Files\PostgreSQL\14\data` или отдельный диск, например `D:\PostgreSQL\14\data` |
| Пароль | пароль суперпользователя `postgres`. Храните его отдельно. В репозиторий он не входит |
| Порт | `5432` |
| Служба | `postgresql-x64-14`, запуск автоматический |

Командные утилиты лежат в `C:\Program Files\PostgreSQL\14\bin` (`psql`, `pg_dump`, `pg_isready`). Скрипты ищут их там. Другой каталог задаётся переменной `PGBIN`.

## PostGIS 3.4

Stack Builder ставится вместе с PostgreSQL (меню «PostgreSQL 14»). В нём: Spatial Extensions → PostGIS 3.4 для PostgreSQL 14.

Галочка «Create spatial database» не нужна: базу создаёт `scripts\init-db.ps1`, расширение включает миграция `001_init.sql`.

Проверка, что файлы расширения на месте (подключение ещё может быть к базе `postgres`):

```powershell
& "C:\Program Files\PostgreSQL\14\bin\psql.exe" -h localhost -U postgres -d postgres -c "SELECT name, default_version FROM pg_available_extensions WHERE name = 'postgis';"
```

Строка `postgis` должна быть. Версия — 3.4.

## База eco_monitoring

Из каталога проекта, в PowerShell:

```powershell
powershell -ExecutionPolicy Bypass -File scripts\init-db.ps1
```

Скрипт спрашивает пароль пользователя `postgres` (или берёт его из переменной `PG_SUPER_PASSWORD`, не из аргумента командной строки). Дальше он:

- создаёт роль `eco` с правом суперпользователя, если её ещё нет;
- создаёт базу `eco_monitoring` (UTF-8, локаль `C`, как раньше в контейнере);
- проверяет, что PostgreSQL не старше 14 и что PostGIS доступен.

Пароль стенда у `eco` — `eco`. Свой пароль:

```powershell
powershell -ExecutionPolicy Bypass -File scripts\init-db.ps1 -EcoPassword 'длинный-пароль'
```

Повторный запуск не меняет пароль уже существующей роли `eco` и не пересоздаёт базу. Если на сервере нет локали `C`, скрипт создаёт базу с локалью кластера и кодировкой UTF-8.

Другой каталог программ или другой хост: `-PgBin`, `-SuperUser`, `-PgHost`, `-Port`.

## Схема

```powershell
powershell -ExecutionPolicy Bypass -File sql\apply.ps1
```

Уже применённые миграции пропускаются. Подключение по умолчанию: `localhost`, порт `5432`, база `eco_monitoring`, пользователь `eco`, пароль `eco`. Переопределение: `PGHOST`, `PGPORT`, `PGUSER`, `PGDATABASE`, `PGPASSWORD`. Если `PGBIN` не задан, берётся `C:\Program Files\PostgreSQL\14\bin`.

Сброс схемы `eco` и повторное применение:

```powershell
powershell -ExecutionPolicy Bypass -File sql\apply.ps1 -Reset
```

Проверка PostGIS уже в базе `eco_monitoring`:

```powershell
& "C:\Program Files\PostgreSQL\14\bin\psql.exe" -h localhost -U eco -d eco_monitoring -c "SELECT PostGIS_Version();"
```

Дальше — роли (`docs/roles.md`) и загрузка (`docs/loading-data.md`).

На машине с bash и уже установленным PostgreSQL тот же порядок выполняет `sql/apply.sh`. Скрипт подключается к локальному серверу и Docker не вызывает.

## Доступ с другого компьютера

Сразу после установки PostgreSQL слушает только `localhost`. ArcGIS на другой машине до порта `5432` не дойдёт.

1. В `postgresql.conf` (каталог data): `listen_addresses = '*'`.
2. В `pg_hba.conf` — строка только для адреса ArcGIS, не для всей сети:

    ```
    host  eco_monitoring  eco_gis  10.1.1.20/32  scram-sha-256
    ```

    Подставьте адрес сервера ArcGIS. Отдельная строка нужна и для ETL, если он на другой машине.
3. Брандмауэр Windows: входящий TCP `5432` только с этих адресов.
4. Перезапуск службы: `Restart-Service postgresql-x64-14`.

Пароль `eco_gis` смените до публикации. На стенде он равен имени пользователя (`docs/roles.md`).

## Клиент SQL

pgAdmin 4 ставится вместе с PostgreSQL и открывается из меню Пуск. Сервер `localhost`, порт `5432`, пользователь `eco`. Отдельный веб-интерфейс на порту `8080` не нужен.

## Резервное копирование

Еженедельное задание описано в `docs/backups.md`. Ему нужен файл `D:\eco-backups\pgpass.conf`, потому что служба Windows, в отличие от контейнера, не пускает `eco` без пароля.
