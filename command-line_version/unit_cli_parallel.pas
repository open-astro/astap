unit unit_cli_parallel;
{Row-range parallel helper for the ASTAP command line solver.
 A persistent pool of worker threads (created on first use) splits a row range
 over the available cores. Workers block on RTL events, so a call costs
 microseconds, unlike TThread.Create/WaitFor which polls at 100 ms steps on Unix.
 Thread count follows the ASTAP_THREADS environment variable
 (default: processor count, max 16).

 This Source Code Form is subject to the terms of the Mozilla Public
 License, v. 2.0. If a copy of the MPL was not distributed with this
 file, You can obtain one at https://mozilla.org/MPL/2.0/.   }

{$mode objfpc}{$H+}
interface
uses
  Classes, SysUtils, math;

type
  TRowProc = procedure(startRow, endRow: integer; data: pointer);

procedure parallel_rows(nrows: integer; proc: TRowProc; data: pointer); {run proc over [0..nrows-1] split in chunks on all threads; returns when all chunks are done}
function cli_thread_count: integer;

implementation

type
  Tworker = record
    go, done  : PRTLEvent;
    s, e      : integer;
    proc      : TRowProc;
    data      : pointer;
    quit      : boolean;
    handle    : TThreadID;
  end;
  Pworker = ^Tworker;

var
  thread_count : integer = 0;
  workers      : array of Tworker;
  pool_ready   : boolean = false;

function cli_thread_count: integer;
var
  s : string;
  n : integer;
begin
  if thread_count=0 then
  begin
    thread_count:=TThread.ProcessorCount;
    s:=GetEnvironmentVariable('ASTAP_THREADS');
    if s<>'' then
    begin
      n:=StrToIntDef(s,0);
      if n>0 then thread_count:=n;
    end;
    if thread_count<1 then thread_count:=1;
    if thread_count>16 then thread_count:=16;
  end;
  result:=thread_count;
end;

function worker_main(p: pointer): ptrint;
var
  w : Pworker;
begin
  w:=Pworker(p);
  repeat
    RTLEventWaitFor(w^.go);
    RTLEventResetEvent(w^.go);
    if w^.quit then break;
    w^.proc(w^.s, w^.e, w^.data);
    RTLEventSetEvent(w^.done);
  until false;
  result:=0;
end;

procedure start_pool(n: integer);
var
  i : integer;
begin
  setlength(workers, n-1); {the calling thread does chunk 0 itself}
  for i:=0 to n-2 do
  begin
    workers[i].go:=RTLEventCreate;
    workers[i].done:=RTLEventCreate;
    workers[i].quit:=false;
    workers[i].handle:=BeginThread(@worker_main, @workers[i]);
  end;
  pool_ready:=true;
end;

procedure parallel_rows(nrows: integer; proc: TRowProc; data: pointer);
var
  n, i, chunk, s, e : integer;
begin
  if nrows<=0 then exit;
  n:=cli_thread_count;
  if ((n<=1) or (nrows<n*16)) then
  begin
    proc(0, nrows-1, data);
    exit;
  end;
  if not pool_ready then start_pool(n);
  chunk:=(nrows+n-1) div n;
  for i:=1 to n-1 do {hand out chunks 1..n-1 to the workers}
  begin
    s:=i*chunk;
    e:=min(nrows-1, s+chunk-1);
    workers[i-1].s:=s;
    workers[i-1].e:=e;
    workers[i-1].proc:=proc;
    workers[i-1].data:=data;
    if s<=e then RTLEventSetEvent(workers[i-1].go)
    else RTLEventSetEvent(workers[i-1].done); {nothing to do for this worker}
  end;
  proc(0, min(nrows-1, chunk-1), data); {chunk 0 on the calling thread}
  for i:=0 to n-2 do
  begin
    RTLEventWaitFor(workers[i].done);
    RTLEventResetEvent(workers[i].done);
  end;
end;

end.
