"""
DAG: whitegoods_dbt_pipeline
Runs the full dbt build + Great Expectations data quality checks for the
whitegoods_inventory data product.

Schedule: daily at 06:00 AEST (20:00 UTC)

Pipeline:
  start
  → dbt_source_freshness
  → dbt_run_staging
  → dbt_run_intermediate
  → dbt_run_marts
  → [gx_checkpoint, dbt_test]  (parallel — GX validates marts, dbt tests run schema tests)
  → dbt_docs_generate
  → upload_dbt_artifacts        (manifest + catalog to S3 for DataHub lineage)
  → end
"""

from datetime import datetime, timedelta
from airflow import DAG
from airflow.operators.bash import BashOperator
from airflow.operators.empty import EmptyOperator
from airflow.utils.dates import days_ago
from airflow.utils.trigger_rule import TriggerRule

DBT_PROJECT_DIR = "/opt/airflow/dbt/whitegoods_inventory"
DBT_PROFILES_DIR = "/home/airflow/.dbt"
DBT_BIN = "/home/airflow/.local/bin/dbt"
GX_DIR = "/opt/airflow/great_expectations/whitegoods_inventory"

default_args = {
    "owner": "data-platform",
    "depends_on_past": False,
    "email_on_failure": False,
    "email_on_retry": False,
    "retries": 1,
    "retry_delay": timedelta(minutes=5),
}

with DAG(
    dag_id="whitegoods_dbt_pipeline",
    default_args=default_args,
    description="Runs dbt build for the whitegoods inventory data platform",
    schedule_interval="0 20 * * *",  # 06:00 AEST = 20:00 UTC
    start_date=days_ago(1),
    catchup=False,
    tags=["dbt", "whitegoods", "snowflake"],
) as dag:

    start = EmptyOperator(task_id="start")

    # --- Source freshness check ---
    dbt_source_freshness = BashOperator(
        task_id="dbt_source_freshness",
        bash_command=(
            f"{DBT_BIN} source freshness "
            f"--project-dir {DBT_PROJECT_DIR} "
            f"--profiles-dir {DBT_PROFILES_DIR} "
            f"--target dev "
        ),
    )

    # --- Staging layer (views) ---
    dbt_run_staging = BashOperator(
        task_id="dbt_run_staging",
        bash_command=(
            f"{DBT_BIN} run "
            f"--project-dir {DBT_PROJECT_DIR} "
            f"--profiles-dir {DBT_PROFILES_DIR} "
            f"--target dev "
            f"--select staging "
        ),
    )

    # --- Intermediate layer (tables) ---
    dbt_run_intermediate = BashOperator(
        task_id="dbt_run_intermediate",
        bash_command=(
            f"{DBT_BIN} run "
            f"--project-dir {DBT_PROJECT_DIR} "
            f"--profiles-dir {DBT_PROFILES_DIR} "
            f"--target dev "
            f"--select intermediate "
        ),
    )

    # --- Marts layer (tables) ---
    dbt_run_marts = BashOperator(
        task_id="dbt_run_marts",
        bash_command=(
            f"{DBT_BIN} run "
            f"--project-dir {DBT_PROJECT_DIR} "
            f"--profiles-dir {DBT_PROFILES_DIR} "
            f"--target dev "
            f"--select marts "
        ),
    )

    # --- Great Expectations checkpoint ---
    # Runs after marts are built. Validates each mart table against its
    # expectation suite, writes results to s3://<raw-bucket>/great_expectations/results/
    # which Snowpipe loads into WHITEGOODS_RAW.GX.VALIDATIONS for trend dashboarding.
    gx_checkpoint = BashOperator(
        task_id="gx_checkpoint",
        bash_command=(
            f"python {GX_DIR}/run_gx_checkpoint.py "
            f"--profiles-dir {DBT_PROFILES_DIR} "
            f"--gx-dir {GX_DIR} "
            f"--region ap-southeast-2 "
        ),
    )

    # --- dbt tests ---
    dbt_test = BashOperator(
        task_id="dbt_test",
        bash_command=(
            f"{DBT_BIN} test "
            f"--project-dir {DBT_PROJECT_DIR} "
            f"--profiles-dir {DBT_PROFILES_DIR} "
            f"--target dev "
        ),
    )

    # --- Generate docs (produces manifest.json + catalog.json) ---
    # trigger_rule=all_done: runs even if gx_checkpoint or dbt_test fail,
    # so DataHub lineage stays fresh and docs are always regenerated.
    # GX/test failures are still visible as failed tasks in the DAG run.
    dbt_docs_generate = BashOperator(
        task_id="dbt_docs_generate",
        trigger_rule=TriggerRule.ALL_DONE,
        bash_command=(
            f"{DBT_BIN} docs generate "
            f"--project-dir {DBT_PROJECT_DIR} "
            f"--profiles-dir {DBT_PROFILES_DIR} "
            f"--target dev "
        ),
    )

    # --- Upload dbt artifacts to S3 for DataHub ingestion ---
    # DataHub EC2 syncs from s3://<airflow-bucket>/datahub/dbt/ on a cron
    # (30 min after this DAG runs) to keep lineage metadata fresh.
    upload_dbt_artifacts = BashOperator(
        task_id="upload_dbt_artifacts",
        bash_command=(
            "BUCKET=$(aws ssm get-parameter "
            "  --name /mdp/platform/airflow_s3_bucket "
            "  --query Parameter.Value --output text "
            "  --region ap-southeast-2) && "
            f"aws s3 cp {DBT_PROJECT_DIR}/target/manifest.json "
            "  s3://$BUCKET/datahub/dbt/manifest.json --region ap-southeast-2 && "
            f"aws s3 cp {DBT_PROJECT_DIR}/target/catalog.json "
            "  s3://$BUCKET/datahub/dbt/catalog.json --region ap-southeast-2"
        ),
    )

    end = EmptyOperator(task_id="end")

    # --- DAG dependency chain ---
    # gx_checkpoint and dbt_test run in parallel after marts are built,
    # then both must complete before docs are generated.
    (
        start
        >> dbt_source_freshness
        >> dbt_run_staging
        >> dbt_run_intermediate
        >> dbt_run_marts
        >> [gx_checkpoint, dbt_test]
        >> dbt_docs_generate
        >> upload_dbt_artifacts
        >> end
    )
