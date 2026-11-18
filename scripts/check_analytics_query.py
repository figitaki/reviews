"""Offline synthetic query-cost check; requires local initdb, pg_ctl and psql.
Creates and removes an isolated Unix-socket PostgreSQL cluster. No application
credentials or existing DB are used. Simplified tables model row width and
primary/author indexes, not production data distribution or every index.
"""
import os, json, subprocess, tempfile
from pathlib import Path
repo=Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix='rv-analytics-perf-') as tmp:
 db=tmp+'/db'
 subprocess.run(['initdb','-D',db,'-A','trust','--no-locale','--encoding=UTF8'],check=True,capture_output=True)
 subprocess.run(['pg_ctl','-D',db,'-l',tmp+'/server.log','-o',f"-k {tmp} -h '' -p 5432",'-w','start'],check=True,capture_output=True)
 try:
  setup="SET work_mem='4MB'; CREATE TABLE identities(id bigint PRIMARY KEY, owner_user_id bigint NOT NULL); INSERT INTO identities SELECT n, (n+2)/3 FROM generate_series(1,60000) n;"
  for table,n in [('reviews',100000),('patchsets',200000),('comments',300000),('packet_section_decisions',100000)]:
   setup+=f"CREATE TABLE {table}(id bigint PRIMARY KEY, inserted_at timestamp NOT NULL, author_id bigint, payload text); CREATE INDEX ON {table}(author_id); INSERT INTO {table} SELECT n, date_trunc('second',transaction_timestamp()) AT TIME ZONE 'UTC' - (n%90)*interval '1 day' - interval '1 second', (n%60000)+1, repeat(md5(n::text),32) FROM generate_series(1,{n}) n;"
  setup+='ANALYZE;'
  # Drop inherited libpq settings (PGHOSTADDR overrides PGHOST, PGSERVICE adds a target).
  base={k:v for k,v in os.environ.items() if not k.startswith('PG')}
  env={**base,'PGHOST':tmp,'PGPORT':'5432','PGUSER':os.environ['USER'],'PGDATABASE':'postgres'}
  subprocess.run(['psql','-X','-q','-v','ON_ERROR_STOP=1'],input=setup,text=True,env=env,check=True,capture_output=True)
  query=(repo/'priv/analytics/snapshot.sql').read_text()
  results=[]
  for i in range(2):
   out=subprocess.check_output(['psql','-X','-At','-v','ON_ERROR_STOP=1','-c',"SET statement_timeout='5s'; EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON) "+query],env=env,text=True)
   plan=json.loads(out[out.index('['):])[0];results.append(plan)
  for i,p in enumerate(results):
   print(json.dumps({'run':i+1,'execution_ms':p['Execution Time'],'planning_ms':p['Planning Time'],'shared_hit_blocks':p['Plan']['Shared Hit Blocks'],'shared_read_blocks':p['Plan']['Shared Read Blocks'],'temp_read_blocks':p['Plan']['Temp Read Blocks'],'temp_written_blocks':p['Plan']['Temp Written Blocks']}))
 except subprocess.CalledProcessError as e:
  print(e.stderr);raise
 finally:subprocess.run(['pg_ctl','-D',db,'-m','fast','-w','stop'],check=True,capture_output=True)
