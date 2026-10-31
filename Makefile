# Trading Analytics Platform - commandes utiles
# Necessite GNU Make. Les lignes de commande doivent commencer par une TABULATION.

COMPOSE      = docker compose --env-file .env
SPARK        = $(COMPOSE) exec spark-master
SPARK_SUBMIT = /opt/spark/bin/spark-submit --master spark://spark-master:7077
METABASE_DRIVER_VERSION = 1.4.0

.PHONY: help up down clean restart ps logs topics init producer streaming streaming-bg silver gold batch count metabase-driver airflow-open superset-open metabase-open

help:
	@echo "Demarrage : make up | make ps | make logs | make down"
	@echo "Initialisation (une fois) : make init"
	@echo "Temps reel : make producer | make streaming | make count"
	@echo "Batch : make silver | make gold | make batch"
	@echo "UI : make metabase-open | make superset-open | make airflow-open"
	@echo "ATTENTION : make clean supprime TOUTES les donnees (volumes)"

# --- Cycle de vie ---
up:
	$(COMPOSE) up -d

down:
	$(COMPOSE) down --remove-orphans

# Supprime aussi les volumes : ClickHouse, Postgres, Metabase... (irreversible)
clean:
	$(COMPOSE) down -v --remove-orphans

restart:
	$(COMPOSE) restart

ps:
	$(COMPOSE) ps -a

logs:
	$(COMPOSE) logs -f --tail=200

topics:
	$(COMPOSE) exec kafka kafka-topics --bootstrap-server kafka:9092 --list

# --- Initialisation du lakehouse (Iceberg) ---
init:
	-$(COMPOSE) exec postgres psql -U airflow -c "CREATE DATABASE iceberg_catalog;"
	$(SPARK) /opt/spark/bin/spark-sql -e "CREATE NAMESPACE IF NOT EXISTS lakehouse.bronze; CREATE NAMESPACE IF NOT EXISTS lakehouse.silver; CREATE NAMESPACE IF NOT EXISTS lakehouse.gold; CREATE TABLE IF NOT EXISTS lakehouse.bronze.trades_raw (kafka_key STRING, raw_value STRING, kafka_topic STRING, kafka_partition INT, kafka_offset BIGINT, source_ts TIMESTAMP, ingestion_time TIMESTAMP) USING iceberg;"

# --- Temps reel : Kafka -> Spark -> Iceberg Bronze + ClickHouse ---
producer:
	$(SPARK) python3 /opt/spark-apps/scripts/trade_producer.py

streaming:
	$(SPARK) $(SPARK_SUBMIT) /opt/spark-apps/streaming/stream_trades_dual_sink.py

streaming-bg:
	$(COMPOSE) exec -d spark-master $(SPARK_SUBMIT) /opt/spark-apps/streaming/stream_trades_dual_sink.py

count:
	$(COMPOSE) exec clickhouse clickhouse-client --query "SELECT symbol, count() FROM realtime.trades_realtime GROUP BY symbol"

# --- Batch : Bronze -> Silver -> Gold ---
silver:
	$(SPARK) $(SPARK_SUBMIT) /opt/spark-apps/batch/BronzeToSilverDailyBatch.py

gold:
	$(COMPOSE) exec dbt bash -lc "dbt run --project-dir /usr/app --profiles-dir /usr/app --select gold.daily_trade_metrics"

batch: silver gold

# --- Metabase : driver ClickHouse (a telecharger une fois) ---
metabase-driver:
	curl -L -o metabase/plugins/clickhouse.metabase-driver.jar https://github.com/ClickHouse/metabase-clickhouse-driver/releases/download/$(METABASE_DRIVER_VERSION)/clickhouse.metabase-driver.jar

# --- Interfaces ---
airflow-open:
	@echo Airflow: http://localhost:8087 (admin / admin)

superset-open:
	@echo Superset: http://localhost:8088 (admin / admin)

metabase-open:
	@echo Metabase: http://localhost:3000 (base ClickHouse: host clickhouse, port 8123, db realtime, user default)