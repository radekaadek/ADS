FROM postgres:17
RUN apt-get update \
 && apt-get install -y --no-install-recommends postgresql-17-cron postgresql-17-tds-fdw \
 && rm -rf /var/lib/apt/lists/*
