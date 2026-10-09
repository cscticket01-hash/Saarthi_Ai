"""Force-kill a synthetic child before/after commit; independently inspect WAL recovery."""
import json,os,pathlib,sqlite3,subprocess,sys,tempfile,queue,threading
exe=sys.argv[1];results=[]
for mode in ['uncommitted','committed']:
    root=pathlib.Path(tempfile.mkdtemp(prefix='vs-sqlite-crash-'));db=root/'local_database_v2.sqlite'
    child=subprocess.Popen([exe,str(db),mode],stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
    ready=queue.Queue()
    threading.Thread(target=lambda:ready.put(child.stdout.readline().strip()),daemon=True).start()
    try: line=ready.get(timeout=60)
    except queue.Empty: line='TIMEOUT'
    if line!='READY_TO_KILL':
        child.kill();child.wait(timeout=15)
        raise RuntimeError('Synthetic crash child did not reach requested stage: '+child.stderr.read()[:4000])
    child.kill();child.wait(timeout=15)
    with sqlite3.connect(db) as connection:
        assert connection.execute('PRAGMA integrity_check').fetchone()[0]=='ok'
        rows=connection.execute('SELECT collection,content FROM records').fetchall()
        if mode=='uncommitted':assert rows==[],rows
        else:
            assert len(rows)==2
            values={name:json.loads(content) for name,content in rows}
            assert values['students_directory']['capturedAt']==123456789
            assert values['_windows_firebase_outbox']['operationId']=='unchanged-crash-operation'
            assert values['_windows_firebase_outbox']['syncState']=='pending'
    results.append({'stage':mode,'status':'PASS','rows':len(rows),'scope':'real OS process force-kill; synthetic local SQLite only'})
out=pathlib.Path('build/sqlite-evidence');out.mkdir(parents=True,exist_ok=True)
(out/'process-crash.json').write_text(json.dumps(results));print(json.dumps(results))
