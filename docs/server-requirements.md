# Требования к серверу (EcoDB)

Краткая оценка ресурсов для размещения EcoDB: PostgreSQL 14 + PostGIS как служба Windows, Python ETL, Query Layer ArcGIS Enterprise. Установка — `docs/install-windows.md`.

## Программное обеспечение

| Компонент | Требование |
| --------- | ---------- |
| ОС | Windows Server. На Linux — тот же PostgreSQL 14 и PostGIS 3.4, схема через `sql/apply.sh` |
| СУБД | PostgreSQL 14, служба `postgresql-x64-14` |
| Расширение | PostGIS 3.4 (Stack Builder, для этой же версии PostgreSQL) |
| Клиент PostgreSQL | `psql`, `pg_isready`, `pg_dump` из `C:\Program Files\PostgreSQL\14\bin` |
| Схема | `scripts\init-db.ps1`, затем `sql\apply.ps1` |
| Python | 3.11+ |
| Зависимости ETL | `etl/requirements.txt` (`openpyxl`, `psycopg2-binary`, `pymupdf`) |
| ГИС-клиент | ArcGIS Enterprise — Query Layer по схеме `eco` (EPSG:4326) |
| Клиент SQL | pgAdmin 4 (ставится с PostgreSQL). Только из внутренней сети |

Docker не используется.

## Оборудование

Текущий объём данных невелик (импорт лабораторных Excel/PDF и около 50 МБ файлов автостанций Оскемена). Для выделенного узла БД и ETL:

| Ресурс | Минимум | Рекомендуется |
| ------ | ------- | ------------- |
| Процессор | 2 vCPU | 4 vCPU |
| Память | 4 ГБ | 8 ГБ |
| Диск | 40 ГБ | 100 ГБ SSD |
| Сеть | локальная сеть до ArcGIS и администраторов | устойчивая; порты ниже |

Если ArcGIS Enterprise работает на той же машине, добавьте его собственные память и процессор сверху (часто 16 ГБ и более). Когда ArcGIS уже нагружен, EcoDB лучше размещать на отдельном узле.

## Порты

| Порт | Служба | Примечание |
| ---- | ------ | ---------- |
| 5432 | PostgreSQL / PostGIS | нужен для ArcGIS и ETL. По умолчанию служба слушает только localhost; доступ с другого сервера — `docs/install-windows.md` |

Исходящий HTTPS нужен только при запуске `dataset/fetch_oskemen_raw.py` (AirData.kz, Open-Meteo).

## Подключение по умолчанию (стенд)

| | |
| --- | --- |
| База | `eco_monitoring` |
| Пользователь / пароль | `eco` / `eco` |

Учётные данные смените до любой промышленной публикации.

## Роли на сервере

1. Установить PostgreSQL 14 и PostGIS 3.4 — `docs/install-windows.md`
2. `scripts\init-db.ps1` — роль `eco` и база `eco_monitoring`
3. Применить схему — `sql\apply.ps1`
4. Запустить ETL — `python etl/phase2.py` … `phase4.py` по необходимости
5. Зарегистрировать Query Layer ArcGIS на представлениях, например `eco.vw_results_flat`, `eco.vw_latest_results`
