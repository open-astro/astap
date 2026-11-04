unit unit_cli_parallel;
{Row-range parallel helper for the ASTAP command line solver (OpenAstro addition).
 Used for the work before the spiral search: the 16 bit FITS conversion, the
 mono/bin/crop step and star detection. On a 4 core Raspberry Pi these take about
 1 s of a 1.6 s hinted solve when run on one core. The spiral search has its own
 threads, see search_spiral in unit_command_line_solving.

 A persistent pool of worker threads (created on first use) splits a row range
 over the available cores. Workers block on RTL events, so a call costs
 microseconds, unlike TThread.Create/WaitFor which polls at 100 ms steps on Unix.

 Thread count: the same rule as the spiral search. The -threads option, else the
 ASTAP_THREADS environment variable, else the physical cores this process may use
 (GetSystemCoreCount). One thread without a thread manager (no cthreads).
 -threads 1 runs everything on the calling thread.

 Errors: an exception inside a worker is caught, the worker still signals
 completion, and the first exception object is re-raised unchanged on the calling
 thread after all chunks are done. So callers see the same exception class and
 message they would see in serial code.

 The pool is not reentrant: parallel_rows called from inside a running chunk
 runs the range serially on the calling thread.

 This Source Code Form is subject to the terms of the Mozilla Public
 License, v. 2.0. If a copy of the MPL was not distributed with this
 file, You can obtain one at https://mozilla.org/MPL/2.0/.   }

{$mode objfpc}{$H+}
interface
uses
  Classes, SysUtils, math, unit_mtpcpu;

type
  TRowProc = procedure(startRow, endRow: integer; data: pointer);

procedure parallel_rows(nrows: integer; proc: TRowProc; data: pointer); {run proc over [0..nrows-1] split in chunks on all threads; returns when all chunks are done}
function cli_thread_count: integer;
procedure set_thread_count(n: integer); {from the -threads option; 0 = automatic}
procedure cli_log_lock;   {serialise console/log output from worker threads}
procedure cli_log_unlock;

implementation

type
  Tworker = record
    go, done  : PRTLEvent;
    s, e      : integer;
    proc      : TRowProc;
    data      : pointer;
    exc       : TObject; {exception object of the last chunk, nil if none. Owned until re-raised or freed by parallel_rows}
    handle    : TThreadID;
  end;
  Pworker = ^Tworker;

var
  thread_count : integer = 0;
  workers      : array of Tworker;
  pool_ready   : boolean = false;
  log_lock     : TRTLCriticalSection;

threadvar
  in_parallel  : boolean; {true while this thread executes a chunk, see the reentrancy guard}

procedure cli_log_lock;
begin
  EnterCriticalSection(log_lock);
end;

procedure cli_log_unlock;
begin
  LeaveCriticalSection(log_lock);
end;

procedure set_thread_count(n: integer);
begin
  if pool_ready then exit; {pool already running}
  if n<=0 then thread_count:=0 {automatic}
  else thread_count:=min(64,n);
end;

function threads_available: boolean; {false without a thread manager. On Unix the program has to use unit cthreads, else BeginThread stops the program with runtime error 232}
{$IFDEF UNIX}
var
  tm : TThreadManager;
{$ENDIF}
begin
  {$IFDEF UNIX}
  GetThreadManager(tm);
  result:=assigned(tm.InitManager);
  {$ELSE}
  result:=true;
  {$ENDIF}
end;

function cli_thread_count: integer;
var
  s : string;
  n : integer;
begin
  if thread_count=0 then
  begin
    if not threads_available then thread_count:=1
    else
    begin
      thread_count:=GetSystemCoreCount; {physical cores this process may use, as the spiral search}
      s:=GetEnvironmentVariable('ASTAP_THREADS');
      if s<>'' then
      begin
        n:=StrToIntDef(s,0);
        if n>0 then thread_count:=n;
      end;
    end;
    if thread_count<1 then thread_count:=1;
    if thread_count>64 then thread_count:=64;
  end;
  result:=thread_count;
end;

function worker_main(p: pointer): ptrint;
var
  w : Pworker;
begin
  w:=Pworker(p);
  in_parallel:=true;
  repeat
    RTLEventWaitFor(w^.go);
    RTLEventResetEvent(w^.go);
    w^.exc:=nil;
    try
      w^.proc(w^.s, w^.e, w^.data);
    except
      w^.exc:=TObject(AcquireExceptionObject); {keep the object alive past this handler, parallel_rows re-raises it on the calling thread}
    end;
    RTLEventSetEvent(w^.done); {always signal, else the caller waits forever}
  until false;
  result:=0;
end;

procedure start_pool(n: integer);
{start n-1 workers. If the OS refuses a thread (low memory, thread limit) the pool is simply smaller; with no worker at all the calls run serially}
var
  i, started : integer;
begin
  setlength(workers, n-1); {the calling thread does chunk 0 itself}
  started:=0;
  for i:=0 to n-2 do
  begin
    workers[started].go:=RTLEventCreate;
    workers[started].done:=RTLEventCreate;
    workers[started].exc:=nil;
    workers[started].handle:=BeginThread(@worker_main, @workers[started]);
    if workers[started].handle<>TThreadID(0) then inc(started)
    else
    begin
      RTLEventDestroy(workers[started].go);
      RTLEventDestroy(workers[started].done);
    end;
  end;
  {the array is not shrunk when a thread could not be started: the running workers hold @workers[i] pointers and a
   memory manager may move a dynamic array on setlength. The unused tail slots are never signalled}
  thread_count:=started+1;
  pool_ready:=true;
end;

procedure run_chunks(nrows, chunk: integer; proc: TRowProc; data: pointer);
{rows [i*chunk, min(nrows-1,(i+1)*chunk-1)] on thread i: chunk 0 on the calling thread, chunk i on worker i-1. The pool must be running}
var
  n, i, s, e : integer;
  exc        : TObject;
begin
  n:=cli_thread_count;
  for i:=1 to n-1 do {hand out chunks 1..n-1 to the workers}
  begin
    s:=i*chunk;
    e:=min(nrows-1, s+chunk-1);
    workers[i-1].s:=s;
    workers[i-1].e:=e;
    workers[i-1].proc:=proc;
    workers[i-1].data:=data;
    workers[i-1].exc:=nil;
    if s<=e then RTLEventSetEvent(workers[i-1].go)
    else RTLEventSetEvent(workers[i-1].done); {nothing to do for this worker}
  end;
  exc:=nil;
  in_parallel:=true;
  try
    proc(0, min(nrows-1, chunk-1), data); {chunk 0 on the calling thread}
  except
    exc:=TObject(AcquireExceptionObject);
  end;
  in_parallel:=false;
  for i:=0 to n-2 do {wait for all workers, also after an error, so the pool is consistent for the next call}
  begin
    RTLEventWaitFor(workers[i].done);
    RTLEventResetEvent(workers[i].done);
    if workers[i].exc<>nil then
    begin
      if exc=nil then exc:=workers[i].exc {the first exception wins, as the serial code would have stopped there}
      else workers[i].exc.Free;
      workers[i].exc:=nil;
    end;
  end;
  if exc<>nil then
    raise exc; {the original object, so class and message are the same as in serial code. The RTL frees it when handled}
end;

function pool_available: boolean; {start the pool on first use. False when the work has to run on the calling thread}
var
  n : integer;
begin
  n:=cli_thread_count;
  if ((n<=1) or in_parallel) then exit(false); {no cores, or called from inside a chunk: the pool is not reentrant}
  if not pool_ready then
  begin
    start_pool(n);
    if cli_thread_count<=1 then exit(false); {no worker could be started}
  end;
  result:=true;
end;

procedure parallel_rows(nrows: integer; proc: TRowProc; data: pointer);
var
  n : integer;
begin
  if nrows<=0 then exit;
  n:=cli_thread_count;
  if ((nrows<n*16) or (not pool_available)) then
  begin
    proc(0, nrows-1, data); {serial}
    exit;
  end;
  n:=cli_thread_count; {may be smaller after start_pool when threads could not be started}
  run_chunks(nrows, (nrows+n-1) div n, proc, data);
end;

initialization
  InitCriticalSection(log_lock);
finalization
  DoneCriticalSection(log_lock);
end.
