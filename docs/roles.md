# Роли базы данных

Миграция `011_roles.sql` создаёт три групповые роли. Они не могут входить в систему и только держат права. Люди и службы получают собственный логин, который добавляется в одну группу. Пароли в репозитории не хранятся.

| Группа | Что может | Типичные логины |
| --- | --- | --- |
| `eco_read` | `SELECT` по всем таблицам и представлениям схемы `eco` | аналитики, пользователи блокнота |
| `eco_edit` | `eco_read` + `INSERT` / `UPDATE` / `DELETE` по данным, справочникам (точки, показатели, синонимы, лаборатории), staging и прогонам QA; выполняет функции ETL. DDL нет. | `eco_etl` (загрузчики), операторы лаборатории |
| `eco_admin` | `eco_edit` + владеет базой и схемой `eco`: миграции, значения нормативов, коды QC, правила QA | 1–2 именных администратора |

Отдельно от групп:

- `eco_gis` — логин ArcGIS (миграция `010`). `SELECT` только по четырём представлениям Query Layer, `statement_timeout = 60s`. Не входит ни в одну группу.
- `eco` — начальный суперпользователь, созданный Docker (`POSTGRES_USER`). Только для создания логинов и аварийных случаев, не для повседневной работы.
- У `PUBLIC` нет доступа к базе и к схеме `eco`.

Таблицы, которые может менять только `eco_admin`: `ref_media_types`, `ref_qc_codes`, `guideline_standards`, `guideline_values`, `qa_rules`, `schema_migrations`. Изменение значения норматива меняет каждое превышение, поэтому это задача администратора.

## После установки на сервере

Один раз, после `docker compose up -d` и `./sql/apply.sh`.

1. Откройте `psql` под начальным суперпользователем:
  ```bash
   docker exec -it eco-postgis psql -U eco -d eco_monitoring
  ```
2. Создайте логины. `\password` запрашивает пароль интерактивно, поэтому он не попадает в историю оболочки и в журналы. Используйте 20 и более случайных символов.
  ```sql
   -- администратор (подставьте настоящее имя)
   CREATE ROLE admin LOGIN IN ROLE eco_admin;
   \password admin

   -- служебная учётная запись ETL
   CREATE ROLE eco_etl LOGIN IN ROLE eco_edit;
   \password eco_etl

   -- пользователь только на чтение (повторить для каждого человека)
   CREATE ROLE analyst LOGIN IN ROLE eco_read;
   \password analyst

   -- заменить стендовый пароль логина ArcGIS
   \password eco_gis

   -- в конце: заменить пароль начального суперпользователя и хранить его в надёжном месте
   \password eco
  ```
3. Проверьте результат:
  ```bash
   psql -h localhost -U eco -d eco_monitoring -v ON_ERROR_STOP=1 -f sql/verify_roles.sql
  ```
   Скрипт печатает `Roles OK` и список логинов с их группами. Любая проблема останавливает скрипт ошибкой, в которой названы роль и объект.

## Какой логин что запускает

| Задача | Логин |
| --- | --- |
| `./sql/apply.sh`, `./sql/apply.sh --reset` | логин администратора (скрипт сам переключается на `eco_admin`) |
| `python etl/phase2.py seed`, `python etl/phase3.py seed` (пишет значения нормативов) | логин администратора |
| `python etl/phase2.py air`, `python etl/phase3.py water`, `python etl/phase4.py` | `eco_etl` |
| Query Layer в ArcGIS | `eco_gis` |
| Блокнот и разовые запросы | участник `eco_read` |

Без аргумента `phase2.py` и `phase3.py` сначала выполняют `seed`. Под `eco_etl` это завершается ошибкой `permission denied for table guideline_standards`. Указывайте `air` / `water` явно.

Учётные данные передаются переменными окружения (`PGUSER`, `PGPASSWORD`, …) или файлом `pgpass`, например:

```powershell
$env:PGUSER = "eco_etl"; $env:PGPASSWORD = "<from password manager>"
python etl/phase2.py air
```

## Повседневные команды

Выполняйте под начальным суперпользователем.

```sql
-- новый пользователь
CREATE ROLE <name> LOGIN IN ROLE eco_read;      -- или eco_edit / eco_admin
\password <name>

-- перевести пользователя в другую группу
REVOKE eco_read FROM <name>;
GRANT eco_edit TO <name>;

-- сразу запретить вход (роль и её история сохраняются)
ALTER ROLE <name> NOLOGIN;

-- временный доступ
ALTER ROLE <name> VALID UNTIL '2026-12-31';

-- удалить пользователя
DROP ROLE <name>;
```

`DROP ROLE` не выполняется, если пользователь владеет объектами. Логины не должны ничем владеть: объекты принадлежат `eco_admin`. Если так случилось, сначала выполните `REASSIGN OWNED BY <name> TO eco_admin; DROP OWNED BY <name>;`.

## Новые таблицы и миграции

Новые миграции выполняются от имени `eco_admin`, поэтому новые таблицы автоматически получают `SELECT` для `eco_read` и право записи для `eco_edit`. Если новая таблица — справочник, который должны менять только администраторы, добавьте в ту же миграцию `REVOKE INSERT, UPDATE, DELETE ON <table> FROM eco_edit;` и включите её в `admin_only` в `sql/verify_roles.sql`. Новые представления не видны `eco_gis`, пока права не выданы явно.
