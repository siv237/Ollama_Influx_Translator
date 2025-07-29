#!/usr/bin/env python3
"""
Ollama to InfluxDB Log Translator

Reads logs from systemd-journal for the ollama service and sends them to InfluxDB.
Deduplication is handled server-side by InfluxDB using a hash tag.
"""

import os
import json
import subprocess
import logging
import re
import time
import hashlib
import socket
from datetime import datetime, timezone, timedelta
from influxdb_client import InfluxDBClient, Point, WritePrecision
from influxdb_client.client.write_api import SYNCHRONOUS
from dotenv import load_dotenv

class OllamaInfluxTranslator:
    def __init__(self):
        # 1. Setup Logging
        self.logger = logging.getLogger(__name__)
        logging.basicConfig(
            level=logging.INFO,
            format='%(asctime)s - %(levelname)s - %(message)s',
            handlers=[
                logging.FileHandler('translator.log'),
                logging.StreamHandler()
            ]
        )

        # 2. Determine host name for tagging
        self.host = os.getenv('OLLAMA_HOST') or socket.gethostname()

        # 3. Load Environment Variables
        load_dotenv(dotenv_path='config.env')
        self.influx_url = os.getenv('INFLUXDB_URL')
        self.influx_token = os.getenv('INFLUXDB_TOKEN')
        self.influx_org = os.getenv('INFLUXDB_ORG')
        self.influx_bucket = os.getenv('INFLUXDB_BUCKET')

        if not all([self.influx_url, self.influx_token, self.influx_org, self.influx_bucket]):
            self.logger.critical("CRITICAL ERROR: InfluxDB environment variables are not set in config.env. Check INFLUXDB_URL, INFLUXDB_TOKEN, INFLUXDB_ORG, INFLUXDB_BUCKET.")
            raise ValueError("Missing InfluxDB environment variables.")

        # 3. Initialize in-memory state
        self.last_processed_timestamp = None
        self.manifests_path = None

        # 4. Connect to InfluxDB
        try:
            self.client = InfluxDBClient(url=self.influx_url, token=self.influx_token, org=self.influx_org)
            self.write_api = self.client.write_api(write_options=SYNCHRONOUS)
            self.logger.info("✅ Successfully connected to InfluxDB.")
        except Exception as e:
            self.logger.critical(f"CRITICAL ERROR: Could not connect to InfluxDB: {e}", exc_info=True)
            raise



    def _find_manifests_path(self):
        """Finds the OLLAMA_MODELS path from the ollama.service journal logs."""
        self.logger.info("Attempting to find OLLAMA_MODELS path from journal logs...")
        try:
            result = subprocess.run(
                ['sudo', 'journalctl', '--unit=ollama.service', '-n', '200', '--no-pager'],
                capture_output=True, text=True, check=True
            )
            for line in reversed(result.stdout.splitlines()):
                # New log format search
                if 'OLLAMA_MODELS:' in line:
                    match = re.search(r'OLLAMA_MODELS:([^\s\]]+)', line)
                    if match:
                        models_path = match.group(1)
                        manifests_path = os.path.join(models_path, 'manifests')
                        self.logger.info(f"✅ Found OLLAMA_MODELS path: {models_path}")
                        self.logger.info(f"Manifests path set to: {manifests_path}")
                        return manifests_path
        except (subprocess.CalledProcessError, FileNotFoundError) as e:
            self.logger.error(f"Error reading journal for ollama.service: {e}")
        except Exception as e:
            self.logger.error(f"An unexpected error occurred while finding manifests path: {e}", exc_info=True)

        self.logger.warning("Could not find OLLAMA_MODELS path in recent journal logs.")
        return None

    def _collect_models(self, manifests_path):
        """Collects a list of all Ollama models from the manifests directory."""
        if not manifests_path or not os.path.isdir(manifests_path):
            self.logger.error(f"Manifests path '{manifests_path}' is invalid or not a directory.")
            return []

        self.logger.info(f"Scanning for models in {manifests_path}...")
        models = []
        for root, _, files in os.walk(manifests_path):
            for fname in files:
                fpath = os.path.join(root, fname)
                try:
                    rel_path = os.path.relpath(fpath, manifests_path)
                    parts = rel_path.split(os.sep)
                    if len(parts) >= 3:
                        model_name = f"{parts[-2]}:{parts[-1]}"
                    else:
                        model_name = f"{os.path.basename(os.path.dirname(fpath))}:{fname}"

                    with open(fpath, 'r', encoding='utf-8') as f:
                        data = json.load(f)
                    
                    for layer in data.get('layers', []):
                        if layer.get('mediaType', '').endswith('model') and 'sha256:' in layer.get('digest', ''):
                            sha = layer['digest'].split('sha256:')[-1]
                            size = layer.get('size')
                            models.append({
                                'name': model_name,
                                'sha256': sha,
                                'size': size
                            })
                            break
                except (json.JSONDecodeError, IndexError) as e:
                    self.logger.warning(f"Could not parse manifest file {fpath}: {e}")
                except Exception as e:
                    self.logger.error(f"Unexpected error processing manifest {fpath}: {e}", exc_info=True)
        
        self.logger.info(f"Found {len(models)} models.")
        return models

    def update_model_inventory(self):
        """Collects the current model inventory and overwrites the data in InfluxDB for the current host."""
        self.logger.info("Starting model inventory update...")
        if not self.manifests_path:
            self.manifests_path = self._find_manifests_path()

        if not self.manifests_path:
            self.logger.warning("Skipping model inventory update: manifests path not set.")
            return

        # 1. Collect current models from disk
        models = self._collect_models(self.manifests_path)
        self.logger.info(f"Found {len(models)} models on disk.")

        # 2. Delete all previous inventory records for this host to ensure data is fresh
        try:
            self.logger.info(f"Deleting existing model inventory for host '{self.host}'...")
            start = "1970-01-01T00:00:00Z"
            stop = datetime.now(timezone.utc).isoformat()
            predicate = f'_measurement=\"ollama_model_inventory\" AND host=\"{self.host}\"'
            self.client.delete_api().delete(start, stop, predicate, self.influx_bucket, self.influx_org)
            self.logger.info("✅ Successfully deleted old inventory data.")
        except Exception as e:
            self.logger.error(f"Failed to delete old inventory data: {e}. New data will still be written.", exc_info=True)

        # 3. Write the new, current inventory
        if not models:
            self.logger.info("No models found on disk. Inventory for this host is now empty.")
            return

        points_batch = []
        for model in models:
            point = Point("ollama_model_inventory") \
                .tag("host", self.host) \
                .tag("model_name", model['name']) \
                .field("sha256", model['sha256']) \
                .field("size", model.get('size', 0) or 0) \
                .field("manifests_path", self.manifests_path) \
                .time(datetime.now(timezone.utc), WritePrecision.S)
            points_batch.append(point)

        if points_batch:
            try:
                self.logger.info(f"Writing {len(points_batch)} model inventory entries to InfluxDB...")
                self.write_api.write(bucket=self.influx_bucket, record=points_batch)
                self.logger.info("✅ Successfully updated model inventory with fresh data.")
            except Exception as e:
                self.logger.error(f"Failed to write new model inventory to InfluxDB: {e}", exc_info=True)

    def get_logs_from_journal(self):
        """Fetches logs from journalctl since the last processed timestamp."""
        if self.last_processed_timestamp:
            # Subsequent run: get logs since the last timestamp (+1 microsecond to avoid overlap)
            since_time = self.last_processed_timestamp + timedelta(microseconds=1)
            # Convert the UTC timestamp to local time for journalctl
            local_tz = datetime.now().astimezone().tzinfo
            since_time_local = since_time.astimezone(local_tz)
            since_str = since_time_local.strftime('%Y-%m-%d %H:%M:%S.%f')
            self.logger.info(f"🕒 Requesting new logs since {since_str}")
        else:
            # First run: get logs for the last 24 hours
            since_time = datetime.now() - timedelta(hours=24)
            since_str = since_time.strftime('%Y-%m-%d %H:%M:%S')
            self.logger.info(f"🚀 First run. Requesting logs for the last 24 hours since {since_str}")

        cmd = ['sudo', 'journalctl', '--unit=ollama', f'--since={since_str}', '--output=json', '--no-pager']
        
        try:
            result = subprocess.run(cmd, capture_output=True, text=True, check=True)
            if not result.stdout:
                return []
            return result.stdout.strip().split('\n')
        except subprocess.CalledProcessError as e:
            self.logger.error(f"journalctl command failed: {e.stderr}")
            return []
        except Exception as e:
            self.logger.error(f"An unexpected error occurred while fetching logs: {e}", exc_info=True)
            return []

    def process_logs(self):
        """Main log processing logic."""
        log_lines = self.get_logs_from_journal()
        if not log_lines:
            self.logger.info("No new logs found.")
            return

        points_batch = []
        latest_ts_in_batch = self.last_processed_timestamp


        for line in log_lines:
            try:
                log_entry = json.loads(line)
                timestamp_us = int(log_entry.get('__REALTIME_TIMESTAMP', 0))
                # Split into whole seconds + microseconds to avoid float rounding
                sec, micros = divmod(timestamp_us, 1_000_000)
                message = log_entry.get('MESSAGE')
                if not message:
                    # If MESSAGE is missing, use the full JSON object as the message.
                    # This ensures no logs are dropped.
                    message = json.dumps(log_entry)
                    self.logger.warning(f"'MESSAGE' not found, using full JSON log entry as message.")
                entry_timestamp = datetime.fromtimestamp(sec, tz=timezone.utc) + timedelta(microseconds=micros)



                # Create a hash for server-side deduplication
                msg_hash = hashlib.sha256(f"{timestamp_us}:{message}".encode()).hexdigest()

                point = Point("ollama_logs") \
                    .tag("source", "systemd") \
                     .tag("host", self.host) \
                    .tag("msg_hash", msg_hash) \
                    .field("message", message) \
                    .time(entry_timestamp, WritePrecision.US)
                
                points_batch.append(point)

                if latest_ts_in_batch is None or entry_timestamp > latest_ts_in_batch:
                    latest_ts_in_batch = entry_timestamp



            except (json.JSONDecodeError, KeyError) as e:
                self.logger.warning(f"Could not process log line: {line}. Error: {e}")

        if points_batch:
            try:
                self.logger.info(f"Writing {len(points_batch)} new log entries to InfluxDB...")
                self.write_api.write(bucket=self.influx_bucket, record=points_batch)
                self.last_processed_timestamp = latest_ts_in_batch
                self.logger.info(f"Updated in-memory timestamp to: {self.last_processed_timestamp}")

            except Exception as e:
                self.logger.error(f"Failed to write batch to InfluxDB: {e}", exc_info=True)
        else:
            self.logger.info("No new valid logs to write after filtering.")
            # If no new logs were found, update the timestamp to the current time 
            # to avoid re-querying the same old time window.
            self.last_processed_timestamp = datetime.now(timezone.utc)
            self.logger.info(f"No new logs. In-memory timestamp updated to current time: {self.last_processed_timestamp}")

    def start_monitoring(self):
        """Starts the continuous monitoring loop."""
        self.logger.info("🎯 Starting Ollama log monitoring...")
        
        # Initial inventory update on startup
        self.update_model_inventory()
        
        inventory_update_counter = 0
        # Update every hour (360 * 10 seconds)
        inventory_update_interval = 360 

        try:
            while True:
                self.process_logs()

                inventory_update_counter += 1
                if inventory_update_counter >= inventory_update_interval:
                    self.logger.info("Hourly model inventory update triggered.")
                    self.update_model_inventory()
                    inventory_update_counter = 0

                self.logger.info("Pausing for 10 seconds...")
                time.sleep(10)
        except KeyboardInterrupt:
            self.logger.info("🛑 Monitoring stopped by user.")
        except Exception as e:
            self.logger.critical(f"A critical error occurred in the monitoring loop: {e}", exc_info=True)
        finally:
            self.client.close()
            self.logger.info("🔌 InfluxDB connection closed.")

if __name__ == "__main__":
    try:
        translator = OllamaInfluxTranslator()
        translator.start_monitoring()
    except ValueError:
        # Error is already logged in __init__
        pass
    except Exception as e:
        logging.getLogger().critical(f"Top-level critical error: {e}", exc_info=True)