#!/bin/zsh
# Smoke tests for sleepwatcher that don't put the Mac to sleep.
# Usage: tests/smoke.sh path/to/sleepwatcher

set -u
SW=${1:A}
T=$(mktemp -d)
trap 'kill $(jobs -p) 2>/dev/null; rm -rf "$T"' EXIT
pass=0 fail=0

ok()   { print "ok   - $1"; (( pass++ )) }
fail() { print "FAIL - $1"; (( fail++ )) }
check() { if eval "$2"; then ok "$1"; else fail "$1"; fi }

# Waits up to $2 seconds for file $1 to exist.
wait_for() { for _ in {1..$(( $2 * 10 ))}; do [[ -e $1 ]] && return 0; sleep 0.1; done; return 1 }

# --- options ------------------------------------------------------------
$SW >/dev/null 2>&1; check "no arguments prints usage, exit 2" "[[ $? == 2 ]]"
$SW -v | grep -q "sleepwatcher 3"; check "-v prints version" "[[ $? == 0 ]]"
$SW --bogus >/dev/null 2>&1; check "unknown long option exits 2" "[[ $? == 2 ]]"
$SW -x >/dev/null 2>&1; check "unknown short option exits 2" "[[ $? == 2 ]]"
[[ $($SW -g) == <-> ]]; check "-g prints idle tenths" "[[ $? == 0 ]]"
$SW -s >/dev/null 2>&1; check "missing argument exits 2" "[[ $? == 2 ]]"

# --- idle hook, event variable, clean signal state in hooks ---------------
# 0.1 s idle threshold: fires almost immediately whether or not someone is typing.
$SW -V -t 1 -i "echo \$SLEEPWATCHER_EVENT > $T/idle; trap > $T/traps" > $T/log1 2>&1 &
pid=$!
wait_for $T/idle 5; check "idle hook runs" "[[ -e $T/idle ]]"
check "SLEEPWATCHER_EVENT=idle" "[[ \$(cat $T/idle 2>/dev/null) == idle ]]"
check "hooks don't inherit ignored signals" "[[ ! -s $T/traps ]]"
kill -TERM $pid; wait $pid 2>/dev/null
check "SIGTERM exits cleanly" "grep -q 'got SIGTERM' $T/log1"

# --- time suffixes and hook timeout -------------------------------------
$SW -V --hooktimeout 1 -t 1 -i "sleep 30" > $T/log2 2>&1 &
pid=$!
for _ in {1..40}; do grep -q "timed out" $T/log2 && break; sleep 0.1; done
check "--hooktimeout kills a hung hook" "grep -q 'idle: sleep 30: timed out' $T/log2"
kill -TERM $pid; wait $pid 2>/dev/null
check "no orphaned hook after timeout" "! pgrep -f '^sleep 30$' >/dev/null"

# --- config file, pidfile, SIGHUP reload --------------------------------
cat > $T/conf <<EOF
# comment
; also a comment
verbose
timeout = 1
idle = touch $T/first
pidfile=$T/pid
EOF
$SW -f $T/conf > $T/log3 2>&1 &
pid=$!
wait_for $T/first 5; check "config file options applied" "[[ -e $T/first ]]"
check "pidfile written" "[[ \$(cat $T/pid 2>/dev/null) == $pid ]]"
sed -i '' "s|idle = touch $T/first|idle = touch $T/second|" $T/conf
kill -HUP $pid
wait_for $T/second 5; check "SIGHUP re-reads config" "[[ -e $T/second ]]"
kill -TERM $pid; wait $pid 2>/dev/null
check "pidfile removed on exit" "[[ ! -e $T/pid ]]"

print "bogus = 1" > $T/badconf
$SW -f $T/badconf -s true > $T/log4 2>&1 &
pid=$!; sleep 0.5; kill -TERM $pid; wait $pid 2>/dev/null
check "unknown config parameter reported" "grep -q \"unknown parameter 'bogus = 1'\" $T/log4"

$SW -t 5 > $T/log5 2>&1 &
pid=$!; sleep 0.5; kill -TERM $pid; wait $pid 2>/dev/null
check "timeout without idle command reported" "grep -q 'timeout without idlecommand ignored' $T/log5"

# --- daemon mode --------------------------------------------------------
$SW -d -p $T/dpid -s true; rc=$?
check "-d returns immediately with 0" "[[ $rc == 0 ]]"
wait_for $T/dpid 5
dpid=$(cat $T/dpid 2>/dev/null)
check "-d child running and wrote pidfile" "[[ -n \"$dpid\" ]] && kill -0 $dpid 2>/dev/null"
[[ -n $dpid ]] && kill -TERM $dpid
sleep 0.3
check "-d child stops on SIGTERM" "[[ -z \"$dpid\" ]] || ! kill -0 $dpid 2>/dev/null"

print "\n$pass passed, $fail failed"
(( fail == 0 ))
