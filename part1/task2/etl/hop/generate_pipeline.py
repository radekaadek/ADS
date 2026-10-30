#!/usr/bin/env python3
"""Generuje potok Apache Hop (pg_to_staging.hpl): dla kazdej tabeli schematu noir transformacje
Table input (PostgreSQL) -> Table output (SQL Server, schemat stg). Kolumny pobierane z katalogu PostgreSQL."""
import subprocess, sys, pathlib
from xml.sax.saxutils import escape
root = pathlib.Path(__file__).resolve().parents[2]
tables = (root / "etl/tables.txt").read_text().split()
def cols(t):
    # BOOLEAN -> 0/1: Hop zapisuje wartosc logiczna do SQL Server jako tekst 'Y'/'N', ktorego kolumna BIT nie przyjmuje
    q = ("SELECT CASE WHEN data_type = 'boolean' THEN format('CASE WHEN %I THEN 1 ELSE 0 END AS %I', column_name, column_name) "
         f"ELSE column_name END FROM information_schema.columns WHERE table_schema='noir' AND table_name='{t}' ORDER BY ordinal_position")
    out = subprocess.run(["docker", "compose", "exec", "-T", "pg", "psql", "-U", "noir_admin", "-d", "noir", "-qAt", "-c", q],
                         cwd=root, capture_output=True, text=True, check=True).stdout.strip().split("\n")
    return out
xml = ['<?xml version="1.0" encoding="UTF-8"?>', '<pipeline>', '  <info>', '    <name>pg_to_staging</name>',
       '    <name_sync_with_filename>Y</name_sync_with_filename>',
       '    <description>Kopiowanie tabel noir z PostgreSQL do schematu stg w SQL Server</description>',
       '    <pipeline_version/>', '    <pipeline_type>Normal</pipeline_type>', '    <parameters/>', '    <capture_transform_performance>N</capture_transform_performance>',
       '  </info>', '  <notepads/>', '  <order>']
for t in tables:
    xml += ['    <hop>', f'      <from>read {t}</from>', f'      <to>write {t}</to>', '      <enabled>Y</enabled>', '    </hop>']
xml.append('  </order>')
for i, t in enumerate(tables):
    c = cols(t)
    sql = "SELECT " + ", ".join(c) + f" FROM noir.{t}"
    y = 64 + i * 56
    xml += ['  <transform>', f'    <name>read {t}</name>', '    <type>TableInput</type>', '    <description/>', '    <distribute>Y</distribute>',
            '    <custom_distribution/>', '    <copies>1</copies>', '    <partitioning><method>none</method><schema_name/></partitioning>',
            '    <connection>pg_noir</connection>', '    <execute_each_row>N</execute_each_row>', '    <limit>0</limit>',
            f'    <sql>{escape(sql)}</sql>', '    <variables_active>N</variables_active>', '    <lazy_conversion_active>N</lazy_conversion_active>',
            '    <attributes/>', f'    <GUI><xloc>96</xloc><yloc>{y}</yloc></GUI>', '  </transform>',
            '  <transform>', f'    <name>write {t}</name>', '    <type>TableOutput</type>', '    <description/>', '    <distribute>Y</distribute>',
            '    <custom_distribution/>', '    <copies>1</copies>', '    <partitioning><method>none</method><schema_name/></partitioning>',
            '    <connection>mssql_noir</connection>', '    <schema>stg</schema>', f'    <table>{t}</table>', '    <commit>1000</commit>',
            '    <truncate>Y</truncate>', '    <ignore_errors>N</ignore_errors>', '    <use_batch>Y</use_batch>', '    <specify_fields>N</specify_fields>',
            '    <partitioning_enabled>N</partitioning_enabled>', '    <partitioning_field/>', '    <partitioning_daily>N</partitioning_daily>',
            '    <partitioning_monthly>Y</partitioning_monthly>', '    <tablename_in_field>N</tablename_in_field>', '    <tablename_field/>',
            '    <tablename_in_table>Y</tablename_in_table>', '    <return_keys>N</return_keys>', '    <return_field/>', '    <fields/>',
            '    <attributes/>', f'    <GUI><xloc>480</xloc><yloc>{y}</yloc></GUI>', '  </transform>']
xml += ['  <transform_error_handling/>', '  <attributes/>', '</pipeline>']
(root / "etl/hop/pg_to_staging.hpl").write_text("\n".join(xml) + "\n")
print("zapisano etl/hop/pg_to_staging.hpl:", len(tables), "tabel")
